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

#if DAYPAGE_ISOLATED_TEST_HOST
#if !DEBUG
#error("The isolated unit test host requires Debug configuration")
#endif
#endif

/// Select the unit host before any production App property or initializer runs.
/// A missing QA identity must stop here rather than launch personal services.
@main
private enum DayPageEntryPoint {
    @MainActor
    static func main() {
        #if DAYPAGE_ISOLATED_TEST_HOST
        guard Bundle.main.bundleIdentifier == "com.daypage.app.qa-unit" else {
            fatalError("Isolated unit host requires its dedicated bundle identity")
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil
                || environment["XCTestBundlePath"] != nil
                || NSClassFromString("XCTestCase") != nil else {
            fatalError("Isolated unit host requires XCTest injection")
        }
        print("[DayPage QA] isolated unit host; production startup disabled")
        DayPageUnitTestHostApp.main()
        #else
        guard Bundle.main.bundleIdentifier != "com.daypage.app.qa-unit" else {
            fatalError("QA unit identity requires the isolated unit host build marker")
        }
        DayPageApp.main()
        #endif
    }
}

#if DAYPAGE_ISOLATED_TEST_HOST
private struct DayPageUnitTestHostApp: App {
    var body: some Scene {
        WindowGroup { Color.clear }
    }
}
#endif
struct DayPageApp: App {

    /// A dedicated Debug UI identity avoids ambiguous system routing when the
    /// production app and isolated unit host share the normal public scheme.
    static func acceptsDeepLinkScheme(_ scheme: String?, bundleIdentifier: String) -> Bool {
        if scheme?.lowercased() == "daypage" { return true }
        #if DEBUG
        if bundleIdentifier == "com.daypage.app.qa-ui",
           scheme?.lowercased() == "daypage-qa-ui" { return true }
        #endif
        return false
    }

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
        AppSettings.Keys.hasRequestedNotifications,
        // The Today coach marks are useful for a real first run but obscure
        // every screenshot route because Today remains mounted behind Archive,
        // Graph, and Settings. Keep this explicit instead of teaching QA to
        // mutate the simulator's preference domain out of band.
        InputBarTutorialOverlay.completionKey
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
                i += 1
                continue
            }
            // Form 3: bare "key" "value" pairs — Maestro's `launchApp:
            // arguments:` reach iOS without dashes or equals signs, so
            // neither form above fires and CI flows launched into the
            // Welcome sheet + notification prompt. The allow-list makes
            // this safe: a stray positional argument can't flip app state.
            if bridgeableBoolKeys.contains(arg), i + 1 < args.count {
                applyBridged(key: arg, value: args[i + 1])
                i += 2
                continue
            }
            i += 1
        }
    }

    private static func applyBridged(key: String, value: String) {
        guard bridgeableBoolKeys.contains(key) else { return }
        let truthy = ["1", "true", "yes", "YES", "True", "TRUE"].contains(value)
        UserDefaults.standard.set(truthy, forKey: key)
    }

    #if DEBUG
    /// Visual-audit-only theme override. Existing Maestro baselines already
    /// launch with `forceTheme`, but the app previously ignored it and quietly
    /// captured light mode under dark filenames.
    static func qaThemeMode(arguments: [String]) -> ThemeMode? {
        guard let raw = qaValue(for: "forceTheme", arguments: arguments) else { return nil }
        return ThemeMode(rawValue: raw.lowercased())
    }

    private static func qaValue(for key: String, arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "-\(key)"),
           arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if let pair = arguments.first(where: { $0.hasPrefix("\(key)=") }),
           let equals = pair.firstIndex(of: "=") {
            return String(pair[pair.index(after: equals)...])
        }
        if let index = arguments.firstIndex(of: key),
           arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return nil
    }

    private static func applyQAOverrides() {
        if let theme = qaThemeMode(arguments: ProcessInfo.processInfo.arguments) {
            UserDefaults.standard.set(theme.rawValue, forKey: AppSettings.Keys.themeMode)
        }
    }
    #endif


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
        #if DEBUG
        DayPageApp.applyQAOverrides()
        #endif
        // US-002: silently migrate any API keys stored in UserDefaults to Keychain
        KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded()
        // US-006: auto-clear stale draft (>30 days old) before any view reads SceneStorage
        DraftStorage.clearIfExpired()

        // Issue #922 — 崩溃诊断为 opt-in（默认关闭）。Sentry SDK 只有在
        // 用户持久化同意（DiagnosticsConsent）且 DSN 已配置时才会启动；
        // 撤销同意会关闭 SDK，且 Kit 侧事件门在事件生成时拒绝一切新事件。
        SentryReporter.setEventsGate { DiagnosticsConsent.isOptedIn }
        DiagnosticsConsent.changeHandler = { optedIn in
            // Cut off HTTP synchronously, before Sentry.close's cached flush.
            if !optedIn { DiagnosticsTransportGate.shared.revoke() }
            Task { @MainActor in SentryLive.applyCurrentConsent() }
        }
        SentryLive.startIfConsented()
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
            await TimelineIndex.shared.warmUpAndWait()
            // SearchIndex warms when Search is actually presented. Starting a
            // second full-vault parser here made an invisible feature compete
            // with Today's first interactive frame.

            // Voice + photo orphan reconciliation rereads raw Markdown. Treat
            // the visible timeline snapshot as an I/O priority barrier, then
            // run both maintenance passes serially at background priority.
            Task.detached(priority: .background) {
                OrphanedVoiceScanner.runStartupScan()
                guard !Task.isCancelled else { return }
                OrphanedPhotoScanner.runStartupScan()
            }
        }
        #if DEBUG
        let qaForcesLocalVault = ProcessInfo.processInfo.arguments.contains("-qaForceLocalVault")
        #else
        let qaForcesLocalVault = false
        #endif
        if !qaForcesLocalVault {
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
                    guard Self.acceptsDeepLinkScheme(
                        url.scheme, bundleIdentifier: Bundle.main.bundleIdentifier ?? ""
                    ) else { return }
                    #if DEBUG
                    if url.scheme?.lowercased() == "daypage-qa-ui" {
                        DayPageLogger.shared.info("[QA owned URL] accepted by dedicated UI bundle")
                    }
                    #endif

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

                    // Read-only AppEntity navigation. The system surface holds
                    // only UUID/date metadata; the memo body is resolved by
                    // the app after launch from the account-bound local Vault.
                    if url.host?.lowercased() == "memo",
                       url.pathComponents.dropFirst().first?.lowercased() == "open",
                       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
                       let id = UUID(uuidString: idString),
                       let dateString = components.queryItems?.first(where: { $0.name == "date" })?.value,
                       // Validate and PRESERVE the incoming day key. Never run
                       // it through a static cached parser whose time zone can
                       // go stale after a preferred-time-zone change.
                       let ref = MemoDetailRef(id: id, dayString: dateString, source: .daily) {
                        navModel.navigate(to: .archive)
                        navModel.push(ref, in: .archive)
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

                    // Place AppEntity links carry only a keyed opaque identifier.
                    // The raw slug is resolved from app-private defaults and
                    // never enters the App Group snapshot or URL.
                    if url.host?.lowercased() == "place",
                       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let identifier = components.queryItems?.first(where: { $0.name == "id" })?.value,
                       let slug = DayPageReadOnlyEntitySnapshotStore.resolvePlaceSlug(identifier) {
                        navModel.navigate(to: .archive)
                        navModel.push(EntityRef(type: "places", slug: slug), in: .archive)
                        return
                    }

                    // daypage://actions and daypage://actions/new are the only
                    // App Intents handoff for Apple System Actions. They open a
                    // review surface; they never execute an effect from a URL.
                    if url.host?.lowercased() == "actions" {
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        if url.pathComponents.dropFirst().first?.lowercased() == "new" {
                            let kind = components?.queryItems?.first(where: { $0.name == "kind" })?.value ?? "reminder"
                            let title = components?.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
                            let notes = components?.queryItems?.first(where: { $0.name == "notes" })?.value
                            navModel.systemActionPresentation = .draft(
                                SystemActionDraftSeed(kind: kind, title: title, notes: notes)
                            )
                        } else {
                            let proposalID = components?.queryItems?
                                .first(where: { $0.name == "proposal" })?.value
                                .flatMap(UUID.init(uuidString:))
                            navModel.systemActionPresentation = .center(selectedProposalID: proposalID)
                        }
                        return
                    }

                    // daypage://focus/new opens a bounded focus draft. Clamp
                    // external values before the review UI receives them.
                    if url.host?.lowercased() == "focus",
                       url.pathComponents.dropFirst().first?.lowercased() == "new" {
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let title = components?.queryItems?.first(where: { $0.name == "title" })?.value ?? "专注"
                        let minutes = Int(components?.queryItems?.first(where: { $0.name == "minutes" })?.value ?? "25") ?? 25
                        navModel.systemActionPresentation = .focus(
                            SystemActionFocusSeed(
                                title: String(title.prefix(160)),
                                durationSeconds: min(max(minutes, 1), 1_440) * 60
                            )
                        )
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

                    // Redeem only the exact native auth callback. Other unknown
                    // DayPage URLs must not be forwarded into Supabase.
                    if NativeAuthFlow.isCallback(url, for: .iOS) {
                        Task { await authService.handleAuthCallback(url) }
                        return
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
                    //
                    // 先同步 AlarmKit 授权态再重排:alarmKitAuthorized 默认 false,
                    // 不同步的话 useAlarmKit 恒 false,真灵动岛路径永远不可达
                    // (提醒会静默退化成普通 UN 通知)。这一步不弹权限框。
                    if #available(iOS 26.0, *) {
                        CaptureReminderService.shared.refreshAlarmKitAuthorizationState()
                        // 冷启动清掉上一会话遗留的 alerting alarm(灵动岛悬挂占位),
                        // 并常驻观察前台触发(前台 iOS 不显示自家灵动岛,须转投横幅)。
                        CaptureReminderService.shared.stopAlertingAlarms()
                        CaptureReminderService.shared.startAlarmAlertObservation()
                    }
                    CaptureReminderService.shared.refreshSchedule()
                    #if DEBUG
                    // QA bridge (simulator only): `-qaAlarmInSeconds 90` schedules a
                    // one-shot capture reminder N seconds out so the AlarmKit Dynamic
                    // Island path can be exercised deterministically. Requests
                    // AlarmKit authorization first (the system prompt is tapped by
                    // the UI driver). Same launch-arg pattern as -dockVoiceDemo.
                    if #available(iOS 26.0, *) {
                        let args = ProcessInfo.processInfo.arguments
                        if let idx = args.firstIndex(of: "-qaAlarmInSeconds"),
                           args.indices.contains(idx + 1),
                           let seconds = TimeInterval(args[idx + 1]), seconds > 0 {
                            Task {
                                await CaptureReminderService.shared.requestAlarmKitAuthorization()
                                // 必须 .loud 才走 AlarmKit 路径(.quiet 走 UN,测不到岛)。
                                // seconds 应 > islandPreheatSeconds(60),否则一进 App
                                // 就已过预热窗口起点,岛在剩余不足 60s 内即时上屏。
                                let r = Reminder(
                                    trigger: .once(Date().addingTimeInterval(seconds)),
                                    label: "QA 灵动岛测试",
                                    level: .loud
                                )
                                CaptureReminderService.shared.addReminder(r)
                            }
                        }
                        // `-qaAlarmTimerSeconds 120`:起 countdown 计时器。
                        // countdown 是唯一由自家 widget 渲染岛 compact/expanded
                        // 的状态,QA 用它实测自定义岛 UI(.alert 由系统钉横幅)。
                        if let idx = args.firstIndex(of: "-qaAlarmTimerSeconds"),
                           args.indices.contains(idx + 1),
                           let seconds = TimeInterval(args[idx + 1]), seconds > 0 {
                            Task {
                                await CaptureReminderService.shared.qaStartCountdownTimer(seconds: seconds)
                            }
                        }
                    }
                    #endif
                    // Notification permission is requested only when the user
                    // chooses reminders/notifications in onboarding or Settings.
                    // Launching into a local journal must never trigger a prompt.
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
                    // Sample journal content is written only when the user
                    // explicitly chooses it, never as a launch side effect.
                }
                .onChange(of: scenePhase) { phase in
                    // Returning to the foreground may follow an external vault
                    // change (iCloud sync, Obsidian, another device). Cheaply
                    // re-check the raw/ mtime and rebuild the index only if it
                    // actually changed (issue #345).
                    if phase == .active {
                        // AlarmKit 授权真源在系统,前台回填(启动路径注释所承诺的
                        // 「每次前台读」此前只在 .task 做了一次,这里补齐);同时
                        // 停掉 alerting 中的 alarm —— 用户已回到 App,提醒完成
                        // 使命,不再让灵动岛挂着黑胶囊(实测会无限期占位)。
                        if #available(iOS 26.0, *) {
                            CaptureReminderService.shared.refreshAlarmKitAuthorizationState()
                            CaptureReminderService.shared.stopAlertingAlarms()
                        }
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

// MARK: - SentryLive (issue #922)

/// Owns live Sentry SDK initialization for the iOS app target, extracted from
/// `DayPageApp.init` so the Privacy & data screen can start/stop the SDK on
/// consent changes without duplicating the options block. Stays in this app
/// file deliberately: Kit must not import Sentry (see
/// `DayPageStorage/SentryReporter.swift` for the adapter boundary).
///
/// Fail-closed contract:
///   - Startup verifies current consent epoch and DSN. SDK calls run outside
///     the consent lock so startup-crash recovery can finish background flushes.
///   - Revocation synchronously cuts off transport before scheduling SDK close.
///     A revoke racing SDK initialization is checked again after start and
///     closes the SDK; its HTTP requests are already refused by the final gate.
///     Events already uploaded cannot be recalled from the device.
@MainActor
enum SentryLive {
    private static var activeEpoch: UUID?

    /// Starts the SDK iff consent + DSN are both present. Idempotent.
    static func startIfConsented() {
        if activeEpoch != nil {
            if DiagnosticsConsent.withCurrentEpoch({ $0 == activeEpoch }) == true { return }
            // SDK.close can wait for background transport callbacks. Revoke
            // first, then close outside the consent permit to avoid deadlock.
            close()
        }
        let prepared = DiagnosticsConsent.withCurrentEpoch { epoch -> (UUID, URLSession, URL)? in
            guard !Secrets.sentryDSN.isEmpty,
                  var parts = URLComponents(string: Secrets.sentryDSN), parts.scheme == "https",
                  let publicKey = parts.user, !publicKey.isEmpty else { return nil }
            let components = parts.path.split(separator: "/")
            guard let project = components.last else { return nil }
            let prefix = components.dropLast().map(String.init).joined(separator: "/")
            parts.path = "/" + (prefix.isEmpty ? "" : prefix + "/") + "api/\(project)/envelope/"
            parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
            guard let endpoint = parts.url,
                  let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
            let cache = cacheRoot.appendingPathComponent("DayPageDiagnostics", isDirectory: true)
                .appendingPathComponent(epoch.uuidString, isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)) != nil else { return nil }
            let session = DiagnosticsTransportGate.shared.makeSession(
                endpoint: endpoint,
                authHeader: "Sentry sentry_version=7,sentry_client=sentry.cocoa/8.58.4,sentry_key=\(publicKey)",
                consent: { DiagnosticsConsent.isOptedIn && DiagnosticsConsent.epoch() == epoch }
            )
            return (epoch, session, cache)
        }
        guard let prepared, let (epoch, session, cache) = prepared else { return }
        guard DiagnosticsConsent.epoch() == epoch else {
            DiagnosticsTransportGate.shared.revoke()
            return
        }
        activeEpoch = epoch

        // Never hold the consent permit across start: SDK startup-crash recovery
        // may flush for five seconds and wait for the background protocol gate.
        // A concurrent revoke cuts HTTP off synchronously; then we close below.
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.urlSession = session
            options.cacheDirectoryPath = cache.path
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableAutoSessionTracking = false
            options.maxBreadcrumbs = 0
            options.enableCrashHandler = true
            options.sendDefaultPii = false
            // Issue #26: do NOT auto-capture screenshots or view
            // hierarchy. DayPage screens often display the user's
            // memo text, API-key entry fields, and named locations
            // — none of which should be uploaded with a crash event.
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            // Remove unstructured event fields before caching. The final
            // transport allowlist also protects pre-existing cached envelopes.
            options.beforeSend = { event in
                guard DiagnosticsConsent.isOptedIn, DiagnosticsConsent.epoch() == epoch else { return nil }
                event.message = nil
                event.error = nil
                event.user = nil
                event.request = nil
                event.context = nil
                event.extra = nil
                event.breadcrumbs = nil
                event.transaction = nil
                event.logger = nil
                event.serverName = nil
                event.fingerprint = nil
                event.modules = nil
                // The final envelope allowlist also removes dynamic exception,
                // frame, image, and tag text, including from pre-existing cache.
                return event
            }
            options.beforeBreadcrumb = { _ in nil }
            options.beforeSendSpan = { _ in nil }
        }
        if DiagnosticsConsent.epoch() != epoch { close() }
    }

    /// Applies a consent change: enable → start (if DSN present);
    /// disable → close the SDK and its transport.
    static func applyCurrentConsent() {
        if DiagnosticsConsent.isOptedIn {
            startIfConsented()
        } else {
            close()
        }
    }

    /// Closes the live SDK so no queued or future event can leave the device.
    static func close() {
        DiagnosticsTransportGate.shared.revoke()
        guard activeEpoch != nil else { return }
        activeEpoch = nil
        SentrySDK.close()
    }
}
