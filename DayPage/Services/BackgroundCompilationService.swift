import Foundation
import BackgroundTasks
import UserNotifications

// MARK: - BackgroundCompilationService

/// Manages iOS BGAppRefreshTask registration and execution for nightly auto-compilation.
///
/// Responsibilities:
///   1. Register the BGAppRefreshTask on app launch (call `registerTask()` from DayPageApp.init)
///   2. Schedule the next background fetch (call `scheduleIfNeeded()` from app launch / foreground)
///   3. Handle the background task: check if yesterday's raw file exists and daily page is absent
///   4. Send a local notification when compilation completes
///   5. On app foreground: check and backfill any missed compilations
///
/// Background task identifier:  "com.daypage.daily-compilation"
///
@MainActor
final class BackgroundCompilationService {

    // MARK: - Constants

    nonisolated static let taskIdentifier = "com.daypage.daily-compilation"

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
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        guard shouldCompile(for: yesterday) else { return }

        Task {
            do {
                try await CompilationService.shared.compile(for: yesterday, trigger: "backfill")
                sendNotification(for: yesterday)
            } catch {
                print("[BGCompile] Backfill failed: \(error.localizedDescription)")
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

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()

        guard shouldCompile(for: yesterday) else {
            task.setTaskCompleted(success: true)
            return
        }

        Task {
            do {
                try await CompilationService.shared.compile(for: yesterday, trigger: "auto")
                sendNotification(for: yesterday)
                task.setTaskCompleted(success: true)
            } catch {
                print("[BGCompile] Background compile failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }
    }

    // MARK: - Private: Compile Eligibility Check

    /// Returns true if a raw memo file exists for `date` and no Daily Page has been compiled yet.
    private func shouldCompile(for date: Date) -> Bool {
        let rawURL = RawStorage.fileURL(for: date)
        guard FileManager.default.fileExists(atPath: rawURL.path) else { return false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: date)

        let dailyURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        return !FileManager.default.fileExists(atPath: dailyURL.path)
    }

    // MARK: - Private: Local Notification

    private func sendNotification(for date: Date) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "DayPage"
        content.body = "昨天的 Daily Page 已编译完成"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.daypage.compiled-\(date.timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        center.add(request) { error in
            if let error {
                print("[BGCompile] Notification error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Next 2:00 AM

    /// Computes the next 2:00 AM local time.
    /// If it's before 2:00 AM today, returns today's 2:00 AM; otherwise tomorrow's.
    private func nextTwoAM() -> Date {
        let calendar = Calendar.current
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
