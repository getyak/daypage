import Foundation
import BackgroundTasks
import UserNotifications
import Sentry
import DayPageStorage
import DayPageServices

// MARK: - Foreground Compile Notification

extension Notification.Name {
    /// Posted by: BackgroundCompilationService.compileForegroundIfDue — after a
    /// successful foreground auto-retry compile.
    /// Observed by: TodayView.body (.onReceive — shows ds-style toast
    /// "今日 Daily Page 已编译完成"). Mutex with the midnight (00:00) system
    /// notification (silent in foreground, no duplicate push).
    static let compileSucceededForeground = Notification.Name("com.daypage.compileSucceededForeground")

    /// Posted by: BackgroundCompilationService.tryAutoCompileWeekly (R7-R8) — after
    /// the midnight compile finishes if it's Monday AM and the prior week has >= 3 dailies.
    /// userInfo["referenceDate"]: Date = any date inside the prior week (yesterday = Sun).
    /// Observed by: TodayView.weeklyRecapPreview (.onReceive — refreshes the top
    /// preview section).
    static let weeklyRecapAvailable = Notification.Name("com.daypage.weeklyRecapAvailable")
}

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
final class BackgroundCompilationService: ObservableObject {

    // MARK: - Issue #5 · 编译进度反馈

    /// User-facing pipeline phase used by the Today progress banner.
    /// Intentionally does NOT expose the full BGTaskScheduler /
    /// CompilationService state machine — it names the five things a user
    /// can meaningfully wait for. Transitions are forward-only within a
    /// run; on failure the stage snaps back to `.idle` and the caller
    /// surfaces the error via the existing failure notification path.
    enum CompileStage: String, CaseIterable {
        case idle
        case collecting   // reading vault/raw/YYYY-MM-DD.md + hot cache
        case cleaning     // in-app polish/pre-checks before sending to LLM
        case clustering   // LLM has the payload, waiting on structured output
        case generating   // parsing / writing daily.md
        case linking      // entity + hot_cache follow-up writes
    }

    /// Currently visible pipeline stage. Toggling this publishes a change
    /// that TodayView.compileProgressBanner observes.
    @Published private(set) var stage: CompileStage = .idle

    /// Chinese label for the current stage; empty when idle.
    var stageLabel: String {
        switch stage {
        case .idle:       return ""
        case .collecting: return "收集今天的记录"
        case .cleaning:   return "整理与预检"
        case .clustering: return "让 AI 找到主题"
        case .generating: return "写成今日日记"
        case .linking:    return "更新实体与记忆"
        }
    }

    /// Fraction 0.0-1.0 for the progress bar; idle returns 0.
    var stageFraction: Double {
        switch stage {
        case .idle:       return 0.0
        case .collecting: return 0.15
        case .cleaning:   return 0.30
        case .clustering: return 0.65
        case .generating: return 0.85
        case .linking:    return 0.95
        }
    }

    // MARK: - Constants

    nonisolated static let taskIdentifier = "com.daypage.daily-compilation"

    /// Maximum number of missed days to compile per backfill session.
    /// Prevents API flooding when the app hasn't been opened in a long time.
    private let maxBackfillDays = 7

    /// 上次前台自动重试的时间戳。foregroundRetryIfNeeded 内部 60s 防抖，
    /// 避免 scenePhase 在短时间内多次切换（锁屏/解锁、Notification Center
    /// 滑动）触发重复 API 调用。
    private var lastForegroundRetry: Date?

    /// Issue #814: dates (yyyy-MM-dd) with a compile currently in flight.
    /// Since foregroundRetryIfNeeded retargeted yesterday it can race the
    /// launch-time backfill for the SAME day — both fire before either
    /// writes the daily (and its source_hash), so the hash guard can't
    /// help. Live demo evidence: two success rows 0.5s apart, i.e. one
    /// duplicated LLM call. All mutations happen on the MainActor.
    private var inFlightDates: Set<String> = []

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
            // Capture self strongly: it is already confirmed non-nil by the guard above.
            // A weak re-capture here would silently drop handleBackgroundTask if self is
            // deallocated between the guard and the Task body, leaving task unsignaled.
            let strongSelf = self
            Task { @MainActor in
                await strongSelf.handleBackgroundTask(refreshTask)
            }
        }
    }

    // MARK: - Schedule

    /// 调度下一次后台应用刷新，最早在用户当地时间午夜 00:00。
    /// 可重复调用；系统会忽略重复请求。
    func scheduleIfNeeded() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundCompilationService.taskIdentifier)
        // 请求最早在下一个 0 点执行（iOS 只保证不早于此时刻）
        request.earliestBeginDate = nextMidnight()

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

    /// Scans all raw memo files and compiles any that have no corresponding Daily Page.
    /// Caps at `maxBackfillDays` per session to avoid API flooding.
    /// Today's file is always excluded (not yet ready for compilation).
    func backfillIfNeeded() {
        let vaultURL = VaultInitializer.vaultURL
        let rawDir = vaultURL.appendingPathComponent("raw", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: rawDir.path) else { return }

        let formatter = Self.dateFormatter
        formatter.timeZone = AppSettings.currentTimeZone()
        let todayString = formatter.string(from: Date())

        let missedDates: [Date] = files
            .filter { $0.hasSuffix(".md") && $0 != "\(todayString).md" }
            .compactMap { filename -> Date? in
                let dateString = String(filename.dropLast(3)) // remove ".md"
                guard let date = formatter.date(from: dateString) else { return nil }
                return shouldCompile(for: date) ? date : nil
            }
            .sorted() // oldest first

        guard !missedDates.isEmpty else { return }

        Task {
            // F6 fix: post compilationDidStart/End ONCE around the whole batch
            // instead of per-date. Previously a 7-day backfill emitted 7 pairs,
            // causing TodayView + SidebarViewModel to refresh 14 times.
            NotificationCenter.default.post(name: .compilationDidStart, object: nil)
            defer { NotificationCenter.default.post(name: .compilationDidEnd, object: nil) }
            for date in missedDates.prefix(maxBackfillDays) {
                do {
                    // Foreground backfill: full exponential backoff (no iOS BGTask budget).
                    try await compileWithRetry(for: date, trigger: "backfill", delays: Self.foregroundRetryDelays)
                    sendSuccessNotification(for: date)
                } catch {
                    DayPageLogger.shared.error("[BGCompile] Backfill failed for \(formatter.string(from: date)): \(error.localizedDescription)")
                    // Continue to next date, don't abort the whole batch
                }
            }
        }
    }

    // MARK: - Foreground Retry (B3)

    /// 0 点 后台编译失败后，应用回到前台时自动补编**昨天**。
    ///
    /// Issue #814：目标日期从「今天」改为「昨天」。今天是 raw 捕获面 ——
    /// 半天数据编译出的 daily 既浪费 LLM 调用又立刻过时；一天只在结束后
    /// （0 点 BGTask / 本方法兜底 / backfill）编译一次成型，与 karpathy
    /// LLM-wiki 的「知识一次编译成持久工件」模型对齐。
    ///
    /// 触发条件：昨天需要编译（`shouldCompile` 缺页或 hash stale）。
    /// 60 秒防抖避免 scenePhase 快速切换重复触发。
    ///
    /// 成功路径：发布 `compileSucceededForeground` 通知（Today 在 banner 上
    /// 显示 ds-style toast）。**不发系统通知**，避免与 0 点 的
    /// `sendSuccessNotification` 重复。
    ///
    /// 失败路径：静默 + Sentry breadcrumb（用户不需要看到第二条失败通知）。
    func foregroundRetryIfNeeded() async {
        guard let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: Date()) else { return }

        // shouldCompile covers both "daily missing" and "raw edited after
        // compile" (source_hash mismatch); nothing to do otherwise.
        guard shouldCompile(for: yesterday) else { return }

        // 60s debounce — protects against rapid scenePhase flapping
        // (notification center pull, lock/unlock without backgrounding).
        let now = Date()
        if let last = lastForegroundRetry, now.timeIntervalSince(last) < 60 { return }
        lastForegroundRetry = now

        // Issue #814: single-flight — the launch-time backfill may already
        // be compiling yesterday; don't fire a duplicate LLM call.
        Self.dateFormatter.timeZone = AppSettings.currentTimeZone()
        let dateKey = Self.dateFormatter.string(from: yesterday)
        guard !inFlightDates.contains(dateKey) else { return }
        inFlightDates.insert(dateKey)
        defer { inFlightDates.remove(dateKey) }

        do {
            try await CompilationService.shared.compile(for: yesterday, trigger: "foreground-retry")
            // 成功路径：广播给 Today，由 banner 体现，避免与 0 点 系统通知重复。
            NotificationCenter.default.post(name: .compileSucceededForeground, object: nil)
        } catch {
            // 失败静默 — Today 已有失败 banner 链路；这里仅留 breadcrumb。
            SentryReporter.breadcrumb(
                category: "compilation",
                level: .warning,
                message: "foreground retry failed: \(error.localizedDescription)"
            )
            // R5: 失败时清掉 debounce 时间戳，让用户下次回前台立即可重试，
            // 而不是被 60s debounce 锁住。成功路径保留 lastForegroundRetry
            // 以阻止 60s 内无意义的二次编译。
            lastForegroundRetry = nil
        }
    }

    // MARK: - Auto Weekly Recap (R8-HIGH)

    /// 周一上午 0 点 daily 编译成功后调用：尝试编译上周的周回顾。
    ///
    /// 触发条件（同时满足）：
    ///   1. 当前 weekday 是周一（Calendar weekday=2，firstWeekday=2）；
    ///   2. 上周（昨天=周日所在的 ISO 周）已编译的 daily ≥ 3 篇。
    /// 任一条件不满足 → 直接 return，无副作用。
    ///
    /// 不抛错 — 周回顾失败不应该让 0 点 daily 编译路径看起来"失败"。
    /// 用 Sentry breadcrumb 记录跳过/失败原因，并在成功路径发布
    /// `.weeklyRecapAvailable`，让 TodayView 的顶部 preview section 刷新。
    // internal for testability (R9-MEDIUM): WeeklyRecapAutoTriggerTests
    // drives this through the real Calendar / VaultInitializer path so
    // the "skip when non-Monday" and "skip when <3 dailies" guards are
    // covered by integration-shape tests, not just the pure helper.
    @MainActor
    internal func tryAutoCompileWeekly() async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AppSettings.currentTimeZone()
        cal.firstWeekday = 2 // Monday
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        // Calendar weekday: 1=Sunday, 2=Monday — 仅周一触发
        guard weekday == 2 else { return }
        // 昨天=周日，归属上周；用昨天作为 referenceDate
        guard let lastWeekRef = cal.date(byAdding: .day, value: -1, to: now) else { return }
        do {
            let metadata = try WeeklyCompilationService.shared.collectWeekMetadata(for: lastWeekRef)
            guard metadata.days.count >= 3 else {
                SentryReporter.breadcrumb(
                    category: "weekly-auto",
                    level: .info,
                    message: "auto weekly skipped: only \(metadata.days.count) daily pages last week"
                )
                return
            }
            _ = try await WeeklyCompilationService.shared.compileWeekly(for: lastWeekRef)
            NotificationCenter.default.post(
                name: .weeklyRecapAvailable,
                object: nil,
                userInfo: ["referenceDate": lastWeekRef]
            )
        } catch {
            SentryReporter.breadcrumb(
                category: "weekly-auto",
                level: .warning,
                message: "auto weekly skipped: \(error)"
            )
        }
    }

    // MARK: - Private: Background Task Handler

    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        // 为下一夜重新调度
        scheduleIfNeeded()

        let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()

        guard shouldCompile(for: yesterday) else {
            // No expirationHandler needed — we complete synchronously here.
            task.setTaskCompleted(success: true)
            return
        }

        // iOS gives BGAppRefreshTask roughly a 30-second runtime budget. We must:
        //   1. Run compilation as a child Task so we can hold a cancellable handle.
        //   2. Wire expirationHandler to cancel that Task (Task.sleep responds to
        //      cancellation, and CompilationService's URLSession calls observe it too).
        //   3. Report completion exactly once based on the child Task's outcome.
        //
        // Previously: expirationHandler only called setTaskCompleted, leaving the
        // outer Task running with up to 750s of sleep — guaranteed to be killed by
        // iOS mid-compile. Now we use a single-attempt retry policy (no sleep) for
        // background runs; the full backoff lives in the foreground backfill path.
        let bgTask: Task<Bool, Never> = Task { @MainActor [weak self] in
            guard let self else { return false }
            let transaction = Secrets.sentryDSN.isEmpty ? nil
                : SentrySDK.startTransaction(name: "background.compilation", operation: "task")
            NotificationCenter.default.post(name: .compilationDidStart, object: nil)
            defer { NotificationCenter.default.post(name: .compilationDidEnd, object: nil) }
            do {
                // Background: single attempt only — must fit in iOS ~30s budget.
                try await self.compileWithRetry(for: yesterday, trigger: "auto", delays: Self.backgroundRetryDelays)
                transaction?.finish()
                if !Secrets.sentryDSN.isEmpty { SentrySDK.flush(timeout: 5) }
                self.sendSuccessNotification(for: yesterday)
                // R8-HIGH: 0 点 compile 成功后顺手尝试编译上周回顾。
                // 仅周一早上触发；内部已做 ≥3 daily / referenceDate 守卫。
                // 失败静默 — 周回顾是次要产物，不应阻塞 daily 编译完成回执。
                await self.tryAutoCompileWeekly()
                return true
            } catch is CancellationError {
                DayPageLogger.shared.warn("[BGCompile] Background compile cancelled by iOS expiration")
                transaction?.finish(status: .cancelled)
                if !Secrets.sentryDSN.isEmpty { SentrySDK.flush(timeout: 5) }
                return false
            } catch {
                DayPageLogger.shared.error("[BGCompile] Background compile failed after retries: \(error.localizedDescription)")
                transaction?.finish(status: .internalError)
                if !Secrets.sentryDSN.isEmpty { SentrySDK.flush(timeout: 5) }
                self.sendFailureNotification()
                return false
            }
        }

        // expirationHandler runs on a system thread when iOS reclaims the budget.
        // Cancel the outer Task so any in-flight sleep / network awaits unwind
        // promptly; the bgTask body returns false and we report completion below.
        task.expirationHandler = {
            bgTask.cancel()
        }

        let success = await bgTask.value
        task.setTaskCompleted(success: success)
    }

    // MARK: - Private: Retry Logic

    /// Foreground (backfill) retry schedule: immediate, then 30s → 2min → 10min.
    /// Total wall time up to ~12.5 min — only safe when the app is in the foreground.
    nonisolated static let foregroundRetryDelays: [UInt64] = [0, 30, 120, 600]

    /// Background (BGAppRefreshTask) retry schedule: single immediate attempt.
    /// iOS grants only ~30s for BGAppRefreshTask; any sleep would consume the
    /// budget before retrying anyway. Failed background runs fall back to the
    /// foreground backfill path the next time the user opens the app.
    nonisolated static let backgroundRetryDelays: [UInt64] = [0]

    /// 按提供的 `delays`（秒）序列重试编译。`delays[i] > 0` 表示该次尝试前 sleep 多少秒。
    /// 每次 sleep 前会检查 Task cancellation，使 iOS expirationHandler 触发的取消能立即生效。
    /// 如果所有尝试都失败则抛出最后一个错误；如被取消则抛出 `CancellationError`。
    private func compileWithRetry(for date: Date, trigger: String, delays: [UInt64]) async throws {
        // Issue #814: single-flight per date. If another entry point
        // (backfill vs foreground retry) is already compiling this day,
        // silently yield — the winner writes the daily + source_hash.
        Self.dateFormatter.timeZone = AppSettings.currentTimeZone()
        let dateKey = Self.dateFormatter.string(from: date)
        guard !inFlightDates.contains(dateKey) else { return }
        inFlightDates.insert(dateKey)
        defer { inFlightDates.remove(dateKey) }

        // Issue #5 (2026-07-03): user-facing stage updates around the LLM
        // call. Reset to `.idle` in the trailing `defer` so a caught
        // throw always releases the banner.
        stage = .collecting
        // Issue #18: fire the same trigger tag the log carries so the
        // debug board can filter "自动 / 前台重试 / 补编译" apart.
        AnalyticsService.shared.record(
            AnalyticsService.Name.compileStarted,
            props: ["trigger": trigger]
        )
        var succeeded = false
        defer {
            stage = .idle
            AnalyticsService.shared.record(
                succeeded
                    ? AnalyticsService.Name.compileCompleted
                    : AnalyticsService.Name.compileFailed,
                props: ["trigger": trigger]
            )
        }

        var lastError: Error?
        for (attempt, delaySecs) in delays.enumerated() {
            try Task.checkCancellation()
            if delaySecs > 0 {
                stage = .cleaning
                try await Task.sleep(nanoseconds: delaySecs * 1_000_000_000)
            }
            try Task.checkCancellation()
            do {
                stage = .clustering
                try await CompilationService.shared.compile(for: date, trigger: trigger)
                stage = .generating
                stage = .linking
                succeeded = true
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                DayPageLogger.shared.warn("[BGCompile] Attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }
        throw lastError ?? CompilationError.networkError("All retry attempts exhausted")
    }

    // MARK: - Private: Compile Eligibility Check

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 如果 `date` 需要编译则返回 true（issue #814 升级为 stale 检测）：
    ///   1. raw 存在且 daily 缺失 → true（经典缺页路径）；
    ///   2. daily 存在且 frontmatter 带 source_hash，但与当前 raw 内容的
    ///      hash 不一致 → true（用户事后编辑/追加了 memo，daily 已过时）；
    ///   3. daily 存在但没有 source_hash（#814 之前编译的历史页）→ false，
    ///      视为最新 — 避免 backfill 把全部历史重新编译一遍。
    /// `internal` so unit tests (issue #32) can exercise the state-machine
    /// boundary directly without spinning up a real BGAppRefreshTask.
    func shouldCompile(for date: Date) -> Bool {
        let rawURL = RawStorage.fileURL(for: date)
        guard FileManager.default.fileExists(atPath: rawURL.path) else { return false }

        Self.dateFormatter.timeZone = AppSettings.currentTimeZone()
        let dateString = Self.dateFormatter.string(from: date)

        let dailyURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        guard let dailyContent = try? String(contentsOf: dailyURL, encoding: .utf8) else {
            return true // daily missing — classic compile-needed path
        }
        guard let storedHash = CompilationService.extractSourceHash(from: dailyContent) else {
            return false // legacy page without hash — treat as fresh
        }
        guard let memos = try? RawStorage.read(for: date), !memos.isEmpty else {
            return false
        }
        return CompilationService.sourceHash(of: memos) != storedHash
    }

    // MARK: - Private: Local Notifications

    private func sendSuccessNotification(for date: Date) {
        // R5: feature-flag kill switch. If `.compileNotification` is off
        // in Settings → Experiments, suppress the local notification
        // entirely — even when the user-facing notifyCompile toggle is
        // still on. This is a separate, lower-level escape hatch in
        // case the iOS notification surface itself misbehaves.
        guard FeatureFlagStore.shared.isEnabled(.compileNotification) else { return }

        // Issue #20: respect the user toggle. UserDefaults.bool returns false
        // when the key is absent, so we treat "key missing" as on-by-default
        // — only an explicit `false` suppresses notifications.
        let store = UserDefaults.standard
        if store.object(forKey: AppSettings.Keys.notifyCompile) != nil,
           store.bool(forKey: AppSettings.Keys.notifyCompile) == false {
            return
        }

        // Issue #20: surface partial-failure context so the user knows that
        // N memo writes failed even though the Daily Page itself landed.
        // `lastMemoUpdateFailures` is reset to 0 at the start of every
        // CompilationService.compile() call (see CompilationService.swift:74),
        // so this value is scoped to the just-completed run.
        let failures = CompilationService.shared.lastMemoUpdateFailures

        let dateString = Self.dateFormatter.string(from: date)

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString(
            "notif.compile.success.title",
            value: "今日 Daily Page 已生成",
            comment: "Local notification title fired after a successful nightly compilation"
        )
        if failures > 0 {
            let fmt = NSLocalizedString(
                "notif.compile.success.body.partial",
                value: "AI 已编译完成 (%d 条更新失败)，点击查看今日的故事",
                comment: "Notification body when compile succeeded but some memo writes failed"
            )
            content.body = String(format: fmt, failures)
        } else {
            content.body = NSLocalizedString(
                "notif.compile.success.body",
                value: "AI 已编译完成，点击查看今日的故事",
                comment: "Notification body for a fully successful nightly compilation"
            )
        }
        content.sound = .default
        content.userInfo = [
            "type": "compile_success",
            "date": dateString
        ]

        // Stable per-day identifier collapses duplicate notifications when the
        // same date is compiled twice (e.g. backfill after a failed bg run).
        let request = UNNotificationRequest(
            identifier: "daypage.compile.\(dateString)",
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
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

    // MARK: - Private: Next Midnight (00:00)

    /// 计算用户当前时区中的下一个午夜 00:00。
    /// 午夜是一天的起点，`now >= 今天 00:00` 几乎总成立，所以这里基本总是
    /// 返回明天午夜，即"下一个 0 点"。BGTask 的 earliestBeginDate 只是
    /// "最早可执行时间"，iOS 会在该时刻之后择机运行；真正"确保编译成功"
    /// 靠前台 backfill / 前台重试兜底（见 backfillIfNeeded /
    /// foregroundRetryIfNeeded）。
    private func nextMidnight() -> Date {
        let calendar = Self.calendar
        let now = Date()

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let todayMidnight = calendar.date(from: components) else { return now }

        if todayMidnight > now {
            return todayMidnight
        }

        return calendar.date(byAdding: .day, value: 1, to: todayMidnight) ?? now
    }
}
