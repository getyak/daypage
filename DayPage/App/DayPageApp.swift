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

    private let notificationDelegate = AppNotificationDelegate()
    @StateObject private var authService = AuthService.shared
    @StateObject private var navModel = AppNavigationModel()

    init() {
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
        DSFonts.registerAll()
        VaultInitializer.initializeIfNeeded()
        // 在 SwiftUI 渲染之前注册后台任务处理器
        BackgroundCompilationService.shared.registerTask()
        // 设置通知代理以处理点击
        UNUserNotificationCenter.current().delegate = notificationDelegate
        // 在 vault 初始化后启动 iCloud 同步监控和冲突自动合并
        Task { @MainActor in
            iCloudSyncMonitor.shared.startMonitoring(vaultURL: VaultInitializer.vaultURL)
            iCloudConflictMonitor.shared.startMonitoring(vaultURL: VaultInitializer.vaultURL)
        }
        // Eagerly initialize WatchReceiveService so WCSession activates on launch.
        // Without this the lazy singleton never starts and Watch audio transfers are lost.
        _ = WatchReceiveService.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(navModel)
                .onOpenURL { url in
                    // 处理 Magic Link 回调 (daypage://...) 和 OTP 深度链接。
                    // 会话更新由 authStateChanges 监听器处理 — 无需手动赋值。
                    Task {
                        try? await authService.supabase.auth.session(from: url)
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
                    if UserDefaults.standard.bool(forKey: "hasOnboarded") {
                        SampleDataSeeder.seedIfNeeded()
                    }
                }
        }
    }

}
