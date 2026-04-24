import Foundation
import BackgroundTasks
import UserNotifications
import Sentry

// MARK: - BackgroundCompilationService

/// Manages iOS BGAppRefreshTask registration and execution for nightly auto-compilation.
///
/// Responsibilities:
///   1. Register the BGAppRefreshTask on app launch (call `registerTask()` from DayPageApp.init)
///   2. Schedule the next background fetch (call `scheduleIfNeeded()` from app launch / foreground)
///   3. Handle the background task: check if yesterday's raw file exists and daily page is absent
///   4. Send a local notification when compilation completes (or fails after retries)
///   5. On app foreground: check and backfill any missed compilations
///
/// Background task identifier:  "com.daypage.daily-compilation"
///
@MainActor
final class BackgroundCompilationService {

    // MARK: - Constants

    nonisolated static let taskIdentifier = "com.daypage.daily-compilation"
    nonisolated static let failureNotificationCategory = "com.daypage.compilation-failed"
    nonisolated static let failureNotificationAction = "com.daypage.retry-compilation"

    // MARK: - Singleton

    static let shared = BackgroundCompilationService()
    private init() {}

    // MARK: - Registration (call once from DayPageApp.init, before SwiftUI renders)

    /// Registers the BGAppRefreshTask handler with the system.
    /// Must be called before the end of `applicationDidFinishLaunching`.
    nonisolated func registerTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundCompilationService.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                await self?.handleBackgroundTask(refreshTask)
            }
        }
    }

    // MARK: - Schedule

    /// Schedules the next background app refresh for ~2:00 AM local time.
    /// Safe to call repeatedly; the system ignores duplicate requests.
    func scheduleIfNeeded() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundCompilationService.taskIdentifier)
        // Request earliest execution at today's 2:00 AM, or tomorrow's if already past
        request.earliestBeginDate = nextTwoAM()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .notPermitted:
                // Background refresh disabled by user — silently ignore
                break
            case .tooManyPendingTaskRequests:
                // Already scheduled — fine
                break
            default:
                print("[BGCompile] Schedule error: \(error.localizedDescription)")
            }
        } catch {
            print("[BGCompile] Schedule error: \(error.localizedDescription)")
        }
    }

    // MARK: - Backfill Check (call from app foreground / scenePhase .active)

    /// Checks whether yesterday's memo file exists without a compiled Daily Page.
    /// If so, triggers compilation immediately (backfill for missed background run).
    func backfillIfNeeded() {
        let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        guard shouldCompile(for: yesterday) else { return }

        Task {
            NotificationCenter.default.post(name: .compilationDidStart, object: nil)
            defer { NotificationCenter.default.post(name: .compilationDidEnd, object: nil) }
            do {
                try await compileWithRetry(for: yesterday, trigger: "backfill")
                sendSuccessNotification(for: yesterday)
            } catch {
                print("[BGCompile] Backfill failed after retries: \(error.localizedDescription)")
                sendFailureNotification()
            }
        }
    }

    // MARK: - Private: Background Task Handler

    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        // Re-schedule for the next night
        scheduleIfNeeded()

        // Set expiration handler — system is reclaiming the task
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()

        guard shouldCompile(for: yesterday) else {
            task.setTaskCompleted(success: true)
            return
        }

        Task {
            let transaction = Secrets.sentryDSN.isEmpty ? nil
                : SentrySDK.startTransaction(name: "background.compilation", operation: "task")
            NotificationCenter.default.post(name: .compilationDidStart, object: nil)
            defer { NotificationCenter.default.post(name: .compilationDidEnd, object: nil) }
            do {
                try await compileWithRetry(for: yesterday, trigger: "auto")
                transaction?.finish()
                if !Secrets.sentryDSN.isEmpty { SentrySDK.flush(timeout: 5) }
                sendSuccessNotification(for: yesterday)
                task.setTaskCompleted(success: true)
            } catch {
                print("[BGCompile] Background compile failed after retries: \(error.localizedDescription)")
                transaction?.finish(status: .internalError)
                if !Secrets.sentryDSN.isEmpty { SentrySDK.flush(timeout: 5) }
                sendFailureNotification()
                task.setTaskCompleted(success: false)
            }
        }
    }

    // MARK: - Private: Retry Logic

    /// Retries compilation with exponential backoff: 30s → 2min → 10min.
    /// Throws if all 3 attempts fail.
    private func compileWithRetry(for date: Date, trigger: String) async throws {
        let delays: [UInt64] = [0, 30, 120, 600]
        var lastError: Error?
        for (attempt, delaySecs) in delays.enumerated() {
            if delaySecs > 0 {
                try await Task.sleep(nanoseconds: delaySecs * 1_000_000_000)
            }
            do {
                try await CompilationService.shared.compile(for: date, trigger: trigger)
                return
            } catch {
                lastError = error
                print("[BGCompile] Attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }
        throw lastError!
    }

    // MARK: - Private: Compile Eligibility Check

    /// Returns true if a raw memo file exists for `date` and no Daily Page has been compiled yet.
    private func shouldCompile(for date: Date) -> Bool {
        let rawURL = RawStorage.fileURL(for: date)
        guard FileManager.default.fileExists(atPath: rawURL.path) else { return false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppSettings.currentTimeZone()
        let dateString = formatter.string(from: date)

        let dailyURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        return !FileManager.default.fileExists(atPath: dailyURL.path)
    }

    // MARK: - Private: Local Notifications

    private func sendSuccessNotification(for date: Date) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "DayPage"
        content.body = "昨天的 Daily Page 已编译完成"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.daypage.compiled-\(date.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                print("[BGCompile] Notification error: \(error.localizedDescription)")
            }
        }
    }

    /// Sends a failure notification after all retry attempts are exhausted.
    private func sendFailureNotification() {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "DayPage"
        content.body = "今日编译失败，点击查看"
        content.sound = .default
        content.userInfo = ["compilationFailed": true]

        let request = UNNotificationRequest(
            identifier: "com.daypage.compilation-failed-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                print("[BGCompile] Failure notification error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Calendar

    /// Returns a calendar locked to the user's preferred time zone.
    /// Always constructed fresh so a Settings change takes effect immediately.
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AppSettings.currentTimeZone()
        return cal
    }

    // MARK: - Private: Next 2:00 AM

    /// Computes the next 2:00 AM in the device's current time zone.
    /// If it's before 2:00 AM today, returns today's 2:00 AM; otherwise tomorrow's.
    private func nextTwoAM() -> Date {
        let calendar = Self.calendar
        let now = Date()

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 2
        components.minute = 0
        components.second = 0

        guard let todayTwoAM = calendar.date(from: components) else { return now }

        if todayTwoAM > now {
            return todayTwoAM
        }

        return calendar.date(byAdding: .day, value: 1, to: todayTwoAM) ?? now
    }
}
