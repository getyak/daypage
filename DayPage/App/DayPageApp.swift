import SwiftUI
import UserNotifications
import Sentry
import DayPageStorage
import DayPageServices

// MARK: - App Notification Names

extension Notification.Name {
    /// Posted by: DayPageApp (BG task expiration handler) and BackgroundCompilationService
    /// retry path — when background compile fails after all retries.
    /// Observed by: TodayViewModel (.publisher — shows error banner + retry CTA).
    static let compilationDidFail = Notification.Name("com.daypage.compilationDidFail")
    /// Posted by: BackgroundCompilationService.compileForegroundIfDue /
    /// tryAutoCompileWeekly — when a compile pass starts.
    /// Observed by: TodayViewModel (.publisher — drives the in-progress shimmer/state).
    static let compilationDidStart = Notification.Name("com.daypage.compilationDidStart")
    /// Posted by: BackgroundCompilationService — `defer` block at end of every compile
    /// pass (success or failure).
    /// Observed by: TodayViewModel (.publisher — tears down the in-progress shimmer).
    static let compilationDidEnd = Notification.Name("com.daypage.compilationDidEnd")
    /// Posted by: EntityPageView backlink-row tap, TodayView (timeline date pivot).
    /// userInfo["date"]: String = "YYYY-MM-DD".
    /// Observed by: DayPageApp.body (.onReceive — forwards to navModel.openArchive(at:)).
    /// Used to decouple the view layer — EntityPageView is presented from multiple
    /// sheet entry points and can't reliably reach @EnvironmentObject navModel.
    static let openArchiveAt = Notification.Name("com.daypage.openArchiveAt")
    /// Posted by: TodayView SyncQueue sheet row tap (R8) — userInfo["memoID"]: String.
    /// Observed by: (unverified — no live listener; memo-detail router is pending).
    /// Declared at the App layer so the future router can subscribe centrally.
    static let openMemo = Notification.Name("com.daypage.openMemo")
    /// Posted by: EntityPageView (or future graph entry) on entity tap (R8) —
    /// userInfo["entityID"]: String.
    /// Observed by: (unverified — declared centrally so multi-entry EntityPage routing
    /// can wire up later).
    static let openEntityPage = Notification.Name("com.daypage.openEntityPage")
    /// Posted by: AppNotificationDelegate.didReceive — when the user taps a
    /// 「记录提醒」local notification (default tap, or the 语音/文字 long-press action).
    /// userInfo["mode"]: "voice" | "text".
    /// Observed by: DayPageApp.body (.onReceive — forwards to navModel:
    /// voice → pendingRecordingTrigger, text → navigate + focus composer).
    /// Bridged via NotificationCenter because the delegate (an NSObject) can't
    /// reach @EnvironmentObject navModel — same pattern as `.openArchiveAt`.
    static let captureReminderTapped = Notification.Name("com.daypage.captureReminderTapped")
}

// MARK: - NotificationDelegate

/// 处理前台通知显示和通知点击操作。
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// 即使应用在前台也显示通知横幅。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 处理通知点击 — 如果是编译失败，则发布到 Today 标签页。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo["compilationFailed"] as? Bool == true {
            NotificationCenter.default.post(name: .compilationDidFail, object: nil)
        }

        // 「记录提醒」通知:默认点击 → 语音;长按选「文字」→ 文字输入。
        // categoryIdentifier 认领这类通知,避免误吞其他类型。
        if response.notification.request.content.categoryIdentifier == CaptureReminderService.categoryID {
            let mode: String
            switch response.actionIdentifier {
            case CaptureReminderService.actionText:
                mode = "text"
            case CaptureReminderService.actionVoice, UNNotificationDefaultActionIdentifier:
                mode = "voice"
            default:
                // 「清除」等系统 action(UNNotificationDismissActionIdentifier)不落地。
                completionHandler()
                return
            }
            NotificationCenter.default.post(
                name: .captureReminderTapped,
                object: nil,
                userInfo: ["mode": mode]
            )
        }
        completionHandler()
    }
}

// MARK: - DayPageApp

@main
struct DayPageApp: App {

    // MARK: - UI Test Launch Bridge

    /// Allow-list of UserDefaults keys that can be set via launch arguments.
    /// Limiting which keys are bridgeable avoids unexpected runtime overrides
    /// from a stray Shortcut or Xcode "Edit Scheme" argument leaking into
    /// production code paths.
    private static let bridgeableBoolKeys: Set<String> = [
        AppSettings.Keys.hasOnboarded,
        AppSettings.Keys.authSkipped,
        // Issue #3 QA (2026-07-03): the 4-phase startup gate reads
        // `hasSeenWelcome` after onboarding to decide between the second
        // "开始 · Begin" hero and the app itself. Without bridging this,
        // QA/dogfood launches with `-hasOnboarded YES` still land on the
        // Welcome hero. Whitelisting keeps the standard `phase()` gate
        // authoritative for real users while letting screenshot runs skip
        // straight to `.ready`.
        "hasSeenWelcome",
        // Issue #3 QA: skip the local-notification permission prompt so
        // Today can be screenshotted cleanly.
        AppSettings.Keys.hasRequestedNotifications
    ]

    /// Parses `-key value` and `key=value` pairs from `ProcessInfo.arguments`
    /// and writes typed bools into `UserDefaults.standard`, but only for keys
    /// in `bridgeableBoolKeys`. Maestro / XCUITest pass values as raw strings
    /// ("true"/"false") which iOS would otherwise drop on the floor.
    private static func bridgeLaunchArgumentsToDefaults() {
        let args = ProcessInfo.processInfo.arguments
        var i = 0
        while i < args.count {
            let arg = args[i]
            // Form 1: "-key" "value"
            if arg.hasPrefix("-"), i + 1 < args.count {
                let key = String(arg.dropFirst())
                let value = args[i + 1]
                applyBridged(key: key, value: value)
                i += 2
                continue
            }
            // Form 2: "key=value"
            if let eq = arg.firstIndex(of: "="), !arg.hasPrefix("-") {
                let key = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                applyBridged(key: key, value: value)
            }
            i += 1
        }
    }

    private static func applyBridged(key: String, value: String) {
        guard bridgeableBoolKeys.contains(key) else { return }
        let truthy = ["1", "true", "yes", "YES", "True", "TRUE"].contains(value)
        UserDefaults.standard.set(truthy, forKey: key)
    }


    private let notificationDelegate = AppNotificationDelegate()
    @StateObject private var authService = AuthService.shared
    @StateObject private var navModel = AppNavigationModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // === DayPageKit hook registration (M0) ===
        // Must run BEFORE any Kit code that depends on these hooks. KeychainHelper
        // / RawStorage / SentryReporter / OrphanedScanners all sit downstream.
        SentryReporter.adapter = AppSentryAdapter()
        SentryReporter.configure(dsn: Secrets.sentryDSN)
        KitSecrets.register(AppKitSecretsProvider())
        VaultMigrationHook.register {
            Task { @MainActor in
                VaultMigrationService.shared.migrateIfNeeded()
            }
        }
        InflightDraftRefsHook.register {
            Set(InflightDraftStore.pending().flatMap { $0.attachmentPaths })
        }

        // UI-testing launch arguments → UserDefaults bridge.
        // Maestro flows (and any XCUITest) pass flags like `hasOnboarded=true`
        // via `xcrun simctl launch ... -hasOnboarded YES`. iOS auto-merges
        // `-key value` pairs into NSUserDefaults' "argument domain", but only
        // when values are typed (YES/NO, numbers, JSON). Maestro emits raw
        // strings ("true") which the argument domain rejects silently, so the
        // App keeps showing onboarding/auth and Maestro can't find the Today
        // accessibility IDs. We translate the strings explicitly here, before
        // RootView.initialPhase() reads them.
        DayPageApp.bridgeLaunchArgumentsToDefaults()
        // US-002: silently migrate any API keys stored in UserDefaults to Keychain
        KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded()
        // US-006: auto-clear stale draft (>30 days old) before any view reads SceneStorage
        DraftStorage.clearIfExpired()

        // 初始化 Sentry 崩溃报告（DSN 为空时无操作）
        if !Secrets.sentryDSN.isEmpty {
            SentrySDK.start { options in
                options.dsn = Secrets.sentryDSN
                options.tracesSampleRate = ProcessInfo.processInfo.environment["DEBUG"] != nil ? 1.0 : 0.2
                options.enableCrashHandler = true
                // Issue #26: do NOT auto-capture screenshots or view
                // hierarchy. DayPage screens often display the user's
                // memo text, API-key entry fields, and named locations
                // — none of which should be uploaded with a crash event.
                options.attachScreenshot = false
                options.attachViewHierarchy = false
                // Issue #26: redact secrets/PII from every payload before
                // it leaves the device. Applies to both event messages and
                // breadcrumb messages. Failure cases (nil event, no
                // message field) pass through unchanged.
                options.beforeSend = { event in
                    // SentryMessage.formatted is read-only; the writable
                    // field is `message`. Sentry's web UI falls back to
                    // `message` when `formatted` is absent, so scrubbing
                    // `message` is sufficient.
                    if let m = event.message?.message {
                        event.message?.message = SentryRedactor.redact(m) ?? m
                    }
                    if let crumbs = event.breadcrumbs {
                        for crumb in crumbs {
                            crumb.message = SentryRedactor.redact(crumb.message)
                        }
                    }
                    return event
                }
                options.beforeBreadcrumb = { crumb in
                    crumb.message = SentryRedactor.redact(crumb.message)
                    return crumb
                }
            }
        }
        // Issue #29: must run synchronously before the first SwiftUI body
        // — otherwise Font.custom(...) falls back to system fonts for the
        // first frame and "jumps" when registration finishes async.
        DSFonts.registerAll()
        Task.detached(priority: .background) { RawStorage.pruneTrashOlderThan(days: 7) }
        VaultInitializer.initializeIfNeeded()
        // Issue #18 (2026-07-03): fire an app-launch analytics event
        // right after vault init. Two purposes:
        //   1) Guarantees `_analytics/events.jsonl` is created on the
        //      first run so the Settings debug board always has state
        //      to render (instead of "今天还没有事件" that misleads
        //      dogfooders into thinking analytics is broken).
        //   2) Gives us an on-disk breadcrumb for launch cadence that
        //      complements Sentry breadcrumbs.
        // Direct main-actor call — DayPageApp.init is already isolated
        // to @MainActor via App conformance, so no Task wrapper needed.
        AnalyticsService.shared.record(
            "app_launched",
            props: ["version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"]
        )
        // Voice + photo orphan reconciliation. Vault initialization must run
        // first so VaultInitializer.vaultURL resolves to a real directory.
        Task.detached(priority: .background) { OrphanedVoiceScanner.runStartupScan() }
        Task.detached(priority: .background) { OrphanedPhotoScanner.runStartupScan() }
        // 在 SwiftUI 渲染之前注册后台任务处理器
        BackgroundCompilationService.shared.registerTask()
        // 设置通知代理以处理点击
        UNUserNotificationCenter.current().delegate = notificationDelegate
        // 在 vault 初始化后启动 iCloud 同步监控和冲突自动合并
        Task { @MainActor in
            iCloudSyncMonitor.shared.startMonitoring(vaultURL: VaultInitializer.vaultURL)
            iCloudConflictMonitor.shared.startMonitoring(vaultURL: VaultInitializer.vaultURL)
            // Build the timeline metadata index off the main thread so the
            // first Today load reads it instead of scanning the whole vault
            // (issue #345). Cheap no-op until the background scan completes.
            TimelineIndex.shared.warmUp()
            // Same treatment for full-text search (#827): pre-fold the vault
            // into SearchIndex so the first keystroke in Search never pays a
            // disk scan. Until this build lands, SearchView falls back to the
            // legacy scanning path.
            SearchIndex.shared.warmUp()
        }
        // url(forUbiquityContainerIdentifier:) may return nil on first call during
        // cold launch while the iCloud daemon finishes container setup. Re-probe
        // off the main thread and swap the locator if iCloud becomes available.
        Task.detached(priority: .utility) {
            let icloud = iCloudVaultLocator()
            guard icloud.isUsingiCloud else { return }
            await MainActor.run {
                guard !VaultInitializer.shared.isUsingiCloud else { return }
                VaultInitializer.shared = icloud
                VaultInitializer.initializeIfNeeded()
                iCloudSyncMonitor.shared.startMonitoring(vaultURL: VaultInitializer.vaultURL)
                iCloudConflictMonitor.shared.startMonitoring(vaultURL: VaultInitializer.vaultURL)
            }
        }
        // Eagerly initialize WatchReceiveService so WCSession activates on launch.
        // Without this the lazy singleton never starts and Watch audio transfers are lost.
        _ = WatchReceiveService.shared
        // Pre-warm Taptic Engine generators so first-tap haptics fire without latency.
        Task { @MainActor in HapticFeedback.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(navModel)
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "daypage" else { return }

                    // System-level Quick Capture entry points (Widget / Control
                    // Center / Siri / Shortcuts / AppIntent) open the App via
                    // daypage://record. Switch to Today and bump the trigger so
                    // TodayView opens the voice recorder.
                    if url.host?.lowercased() == "record" {
                        navModel.navigate(to: .today)
                        navModel.pendingRecordingTrigger = UUID()
                        DayPageLogger.shared.info("[deepLink] set pendingRecordingTrigger")
                        return
                    }

                    // daypage://memo/new?text=… — pre-fill Today's draft input.
                    if url.host?.lowercased() == "memo",
                       url.pathComponents.dropFirst().first?.lowercased() == "new" {
                        navModel.navigate(to: .today)
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
                           !text.isEmpty {
                            navModel.pendingDraftText = text
                        }
                        return
                    }

                    // daypage://daily?date=YYYY-MM-DD — open Archive at that date.
                    // (Driven by `OpenDailyPageIntent`.) Validate the format
                    // before consuming so a malformed shortcut payload is
                    // ignored rather than navigating to a bogus row.
                    if url.host?.lowercased() == "daily" {
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let dateString = components.queryItems?.first(where: { $0.name == "date" })?.value,
                           dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                            navModel.openArchive(at: dateString)
                        }
                        return
                    }

                    // Issue #7 QA (2026-07-03): `daypage://archive` — open
                    // Archive at the current month without pushing a
                    // specific day. Lets QA/dogfood land on the Vault
                    // Overview strip (Issue #7) without going through the
                    // sidebar tap flow. No-op for real user shortcuts
                    // (there is no user-facing UI that generates this URL).
                    if url.host?.lowercased() == "archive" {
                        navModel.openArchiveOverview()
                        return
                    }

                    // daypage://ask?q=… — open the "和过去对话" memory-chat agent
                    // (D1). RootView observes pendingAskQuery and presents
                    // AskPastView seeded with the question. Driven by AskTodayIntent.
                    if url.host?.lowercased() == "ask" {
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let q = components.queryItems?.first(where: { $0.name == "q" })?.value,
                           !q.isEmpty {
                            navModel.pendingAskQuery = q
                        }
                        return
                    }

                    // daypage://search?q=… — open SearchView pre-populated with
                    // the query. SearchView lives under Archive, so we switch
                    // to .archive and let ArchiveView observe pendingSearchQuery.
                    if url.host?.lowercased() == "search" {
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let q = components.queryItems?.first(where: { $0.name == "q" })?.value,
                           !q.isEmpty {
                            navModel.pendingSearchQuery = q
                        }
                        navModel.navigate(to: .archive)
                        return
                    }

                    // Handle Magic Link / OTP deep-link callbacks.
                    // Session updates are emitted by authStateChanges — no manual assignment needed.
                    Task {
                        do {
                            try await authService.supabase.auth.session(from: url)
                        } catch {
                            SentrySDK.capture(error: error)
                            DayPageLogger.shared.error("[DayPageApp] Deep-link auth session error: \(error)")
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openArchiveAt)) { note in
                    // EntityPageView 的 backlink 行点击后，通过通知转发到 navModel。
                    // 走通知是因为 EntityPageView 在多个 sheet 入口下展示（Graph、
                    // DailyPage、recursive Entity），@EnvironmentObject 链路不稳定。
                    // 校验 date 格式，避免脏 userInfo 导致跳到不存在的归档日期。
                    guard let dateStr = note.userInfo?["date"] as? String,
                          dateStr.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
                    else { return }
                    navModel.openArchive(at: dateStr)
                }
                .onReceive(NotificationCenter.default.publisher(for: .captureReminderTapped)) { note in
                    // 「记录提醒」通知点击 → 落进对应记录入口。走通知桥是因为
                    // AppNotificationDelegate 是 NSObject,够不到 @EnvironmentObject
                    // navModel(与 .openArchiveAt 同一模式)。复用既有的
                    // pendingRecordingTrigger / pendingDraftText 轨道,零改录音层。
                    navModel.navigate(to: .today)
                    let mode = note.userInfo?["mode"] as? String ?? "voice"
                    if mode == "text" {
                        // text 留空 = 只切到 Today 并聚焦草稿输入框(pendingDraftText
                        // 消费方会聚焦);不预填任何文字。
                        navModel.pendingDraftText = ""
                    } else {
                        navModel.pendingRecordingTrigger = UUID()
                    }
                }
                .task {
                    // B1: use `.task` instead of `.onAppear` so the SwiftUI view
                    // tree (including TodayView) is guaranteed to be mounted
                    // before we kick off background scheduling + Widget cold-
                    // launch recording triggers. `.onAppear` fires during the
                    // RootView lifecycle but before Today's `.onAppear` has
                    // registered its trigger observer, leading to the race
                    // where the Widget-initiated `pendingRecordingTrigger` was
                    // consumed before Today started listening.
                    // 安排每晚自动编译并回填任何遗漏的日期
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                    BackgroundCompilationService.shared.backfillIfNeeded()
                    // 「记录提醒」:每次启动幂等重排,让配置与已注册通知保持一致
                    // (处理 flag 切换 / 时区变化 / 系统清空 pending 等情况)。
                    // 仅当用户已授权时才会真正落地通知(refreshSchedule 内部安全)。
                    CaptureReminderService.shared.refreshSchedule()
                    // Issue #20 / Gate A fix (2026-07-03): 请求本地通知权限
                    // (用于 2am 编译完成回执)。原实现在 RootView.onAppear 无条件
                    // 触发，导致 onboarding 的 Welcome 页刚露头就弹系统授权框，
                    // 遮挡首屏价值主张 (Gate A 报告的 Medium 缺陷)。修复：
                    //   1) 只有 onboarding 完成 (hasOnboarded == true) 才触发，
                    //      让 PermissionsPage 保持通知权限请求的唯一权威入口。
                    //   2) 保留 hasRequestedNotifications guard，避免冷启动重复
                    //      弹 (RootView.onAppear 会在场景切换时重入)。
                    let defaults = UserDefaults.standard
                    if defaults.bool(forKey: AppSettings.Keys.hasOnboarded),
                       !defaults.bool(forKey: AppSettings.Keys.hasRequestedNotifications) {
                        defaults.set(true, forKey: AppSettings.Keys.hasRequestedNotifications)
                        UNUserNotificationCenter.current().requestAuthorization(
                            options: [.alert, .sound, .badge]
                        ) { _, _ in
                            // 用户拒绝时 BGCompile.sendSuccessNotification 的
                            // center.add() 会静默失败 (log 一行 error), 不影响
                            // 主流程；不需要在此处理 granted 状态。
                        }
                    }
                    // 如果已授权"始终"权限，启动被动访问监控
                    PassiveLocationService.shared.startMonitoringIfAuthorized()
                    // 加载"历史上的今天"索引。Detached so the first-launch vault
                    // scan never competes with UI work on the main actor — loadIndex
                    // itself hops back to @MainActor to mutate the index dictionary,
                    // and the heavy scan runs inside its own Task.detached(.utility)
                    // (see OnThisDayIndex.rebuildIndex).
                    //
                    // R8 — priority bumped .background → .userInitiated. The user
                    // *sees* the OnThisDayCard at the top of Today right after
                    // launch, so this load isn't really background work; .background
                    // could be deferred 10s+ on a busy device. .userInitiated lands
                    // ~1-2s earlier on cold launch, and OnThisDayIndex now broadcasts
                    // via `isReady` so TodayView wakes the top card immediately when
                    // the scan finishes.
                    Task.detached(priority: .userInitiated) {
                        await OnThisDayIndex.shared.loadIndex()
                    }
                    // 在首次启动且完成引导后填充示例数据
                    if UserDefaults.standard.bool(forKey: AppSettings.Keys.hasOnboarded) {
                        SampleDataSeeder.seedIfNeeded()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    // Returning to the foreground may follow an external vault
                    // change (iCloud sync, Obsidian, another device). Cheaply
                    // re-check the raw/ mtime and rebuild the index only if it
                    // actually changed (issue #345).
                    if phase == .active {
                        TimelineIndex.shared.refreshIfExternallyModified()
                        SearchIndex.shared.refreshIfExternallyModified()
                        // Re-warm generators after backgrounding so they're ready immediately.
                        HapticFeedback.warmUp()
                        // B3: 2am 后台编译失败时，前台回流再试一次。
                        // foregroundRetryIfNeeded 内部已 debounce 60s，
                        // 多次 scenePhase 切换不会重复打 API。
                        //
                        // R5: gated by `.foregroundCompileRetry` flag so a
                        // misbehaving retry loop can be killed from
                        // Settings → Experiments without a hot-fix build.
                        Task { @MainActor in
                            if FeatureFlagStore.shared.isEnabled(.foregroundCompileRetry) {
                                await BackgroundCompilationService.shared.foregroundRetryIfNeeded()
                            }
                        }
                    }
                }
        }
    }

}
