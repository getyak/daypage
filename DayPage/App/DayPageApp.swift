import SwiftUI
import UserNotifications

// MARK: - App Notification Names

extension Notification.Name {
    /// Posted when background compilation fails after all retries.
    /// TodayViewModel listens to show the error banner + retry button.
    static let compilationDidFail = Notification.Name("com.daypage.compilationDidFail")
    /// Posted when background compilation starts.
    static let compilationDidStart = Notification.Name("com.daypage.compilationDidStart")
    /// Posted when background compilation ends (success or failure).
    static let compilationDidEnd = Notification.Name("com.daypage.compilationDidEnd")
}

// MARK: - NotificationDelegate

/// Handles foreground notification display and notification tap actions.
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Show notification banners even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle notification tap — if it's a compilation failure, post to Today tab.
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

    init() {
        DSFonts.registerAll()
        VaultInitializer.initializeIfNeeded()
        // Register background task handler before SwiftUI renders
        BackgroundCompilationService.shared.registerTask()
        // Set notification delegate to handle taps
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .onAppear {
                    // Schedule nightly auto-compile and backfill any missed day
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                    BackgroundCompilationService.shared.backfillIfNeeded()
                    // Start passive visit monitoring if Always authorization is granted
                    PassiveLocationService.shared.startMonitoringIfAuthorized()
                    // API key health check
                    checkApiKeys()
                    // Load On This Day index
                    Task { await OnThisDayIndex.shared.loadIndex() }
                    // Seed sample data on first launch after onboarding
                    if UserDefaults.standard.bool(forKey: "hasOnboarded") {
                        SampleDataSeeder.seedIfNeeded()
                    }
                }
        }
    }

    private func checkApiKeys() {
        var missing: [String] = []
        if Secrets.dashScopeApiKey.isEmpty { missing.append("DashScope (AI 编译)") }
        if Secrets.openAIWhisperApiKey.isEmpty { missing.append("OpenAI Whisper (语音转写)") }
        if Secrets.openWeatherApiKey.isEmpty { missing.append("OpenWeather (天气)") }
        guard !missing.isEmpty else { return }
        let subtitle = missing.joined(separator: "、")
        BannerCenter.shared.show(AppBannerModel(
            kind: .info,
            title: "\(missing.count) 个功能未配置",
            subtitle: subtitle,
            primaryAction: BannerAction(label: "前往设置") { },
            autoDismiss: false
        ))
    }
}
