import SwiftUI
import UserNotifications
import Sentry

// MARK: - App Notification Names

extension Notification.Name {
    /// 后台编译在所有重试后失败时发布。
    /// TodayViewModel 监听此通知以显示错误横幅和重试按钮。
    static let compilationDidFail = Notification.Name("com.daypage.compilationDidFail")
    /// 后台编译开始时发布。
    static let compilationDidStart = Notification.Name("com.daypage.compilationDidStart")
    /// 后台编译结束时发布（无论成功或失败）。
    static let compilationDidEnd = Notification.Name("com.daypage.compilationDidEnd")
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
        AppSettings.Keys.authSkipped
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
                options.attachScreenshot = true
                options.attachViewHierarchy = true
            }
        }
        Task.detached(priority: .utility) { DSFonts.registerAll() }
        Task.detached(priority: .background) { RawStorage.pruneTrashOlderThan(days: 7) }
        VaultInitializer.initializeIfNeeded()
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
                            #if DEBUG
                            print("[DayPageApp] Deep-link auth session error: \(error)")
                            #endif
                        }
                    }
                }
                .onAppear {
                    // 安排每晚自动编译并回填任何遗漏的日期
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                    BackgroundCompilationService.shared.backfillIfNeeded()
                    // 如果已授权"始终"权限，启动被动访问监控
                    PassiveLocationService.shared.startMonitoringIfAuthorized()
                    // 加载"历史上的今天"索引
                    Task { await OnThisDayIndex.shared.loadIndex() }
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
                        // Re-warm generators after backgrounding so they're ready immediately.
                        HapticFeedback.warmUp()
                    }
                }
        }
    }

}
