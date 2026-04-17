import SwiftUI
import UserNotifications

// MARK: - App Notification Names

extension Notification.Name {
    /// Posted when background compilation fails after all retries.
    /// TodayViewModel listens to show the error banner + retry button.
    static let compilationDidFail = Notification.Name("com.daypage.compilationDidFail")
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
                .onAppear {
                    // Schedule nightly auto-compile and backfill any missed day
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                    BackgroundCompilationService.shared.backfillIfNeeded()
                }
        }
    }
}
