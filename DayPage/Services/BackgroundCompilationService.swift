import Foundation
import BackgroundTasks
import UserNotifications
import Sentry

// MARK: - BackgroundCompilationService

/// 管理 iOS BGAppRefreshTask 注册和执行，用于夜间自动编译。
///
/// 职责：
///   1. 在应用启动时注册 BGAppRefreshTask（从 DayPageApp.init 调用 `registerTask()`）
///   2. 调度下一次后台获取（从应用启动/前台调用 `scheduleIfNeeded()`）
///   3. 处理后台任务：检查昨天的 raw 文件是否存在且 daily page 不存在
///   4. 编译完成（或重试失败后）发送本地通知
///   5. 应用进入前台时：检查并补充任何遗漏的编译
///
/// 后台任务标识符："com.daypage.daily-compilation"
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

    /// 向系统注册 BGAppRefreshTask 处理器。
    /// 必须在 `applicationDidFinishLaunching` 结束之前调用。
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

    /// 调度下一次后台应用刷新，大约在当地时间凌晨 2:00。
    /// 可重复调用；系统会忽略重复请求。
    func scheduleIfNeeded() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundCompilationService.taskIdentifier)
        // 请求最早在今天凌晨 2:00 执行，如果已经过了，则请求明天
        request.earliestBeginDate = nextTwoAM()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .notPermitted:
                // 用户禁用了后台刷新 — 静默忽略
                break
            case .tooManyPendingTaskRequests:
                // 已经调度 — 没问题
                break
            default:
                DayPageLogger.shared.error("[BGCompile] Schedule error: \(error.localizedDescription)")
            }
        } catch {
            DayPageLogger.shared.error("[BGCompile] Schedule error: \(error.localizedDescription)")
        }
    }

    // MARK: - Backfill Check (call from app foreground / scenePhase .active)

    /// 检查昨天的 memo 文件是否存在但没有已编译的 Daily Page。
    /// 如果有，立即触发编译（补充遗漏的后台运行）。
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
                DayPageLogger.shared.error("[BGCompile] Backfill failed after retries: \(error.localizedDescription)")
                sendFailureNotification()
            }
        }
    }

    // MARK: - Private: Background Task Handler

    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        // 为下一夜重新调度
        scheduleIfNeeded()

        // 设置过期处理器 — 系统正在回收任务
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
                DayPageLogger.shared.error("[BGCompile] Background compile failed after retries: \(error.localizedDescription)")
                transaction?.finish(status: .internalError)
                if !Secrets.sentryDSN.isEmpty { SentrySDK.flush(timeout: 5) }
                sendFailureNotification()
                task.setTaskCompleted(success: false)
            }
        }
    }

    // MARK: - Private: Retry Logic

    /// 使用指数退避重试编译：30s → 2min → 10min。
    /// 如果所有 3 次尝试都失败则抛出错误。
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
                DayPageLogger.shared.warn("[BGCompile] Attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }
        throw lastError!
    }

    // MARK: - Private: Compile Eligibility Check

    /// 如果 `date` 存在 raw memo 文件且尚未编译 Daily Page，则返回 true。
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
                DayPageLogger.shared.error("[BGCompile] Notification error: \(error.localizedDescription)")
            }
        }
    }

    /// 在所有重试尝试耗尽后发送失败通知。
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
                DayPageLogger.shared.error("[BGCompile] Failure notification error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Calendar

    /// 返回一个锁定到用户首选时区的日历。
    /// 始终重新构建，以便设置更改立即生效。
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AppSettings.currentTimeZone()
        return cal
    }

    // MARK: - Private: Next 2:00 AM

    /// 计算设备当前时区中的下一个凌晨 2:00。
    /// 如果现在还没到今天凌晨 2:00，返回今天的凌晨 2:00；否则返回明天的。
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
