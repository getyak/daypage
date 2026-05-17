import AppIntents
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - StartRecordingIntent
//
// Single AppIntent shared across every system-level Quick Capture entry point:
//
//   • Siri ("Hey Siri, DayPage 记一条")
//   • Spotlight search
//   • Shortcuts.app & Automations
//   • Action Button (iPhone 15 Pro+)
//   • Home Screen / Lock Screen Widget tap (WidgetKit)
//   • Control Center / Lock Screen Control button (iOS 18+ ControlWidget)
//
// Microphone access requires the app to be foregrounded, so this intent
// always opens the app (`openAppWhenRun = true`). The actual recording is
// kicked off by TodayView observing `AppNavigationModel.pendingRecordingTrigger`
// after the URL is handled in DayPageApp.onOpenURL.
//
// We deliberately route through the existing daypage://record URL scheme
// rather than calling the recorder directly so:
//   1. The Widget extension never has to link the full app target.
//   2. There is a single deep-link handler in DayPageApp to maintain.
//   3. The same code path works when the user manually pastes the URL.

@available(iOS 16.0, *)
struct StartRecordingIntent: AppIntent {

    static var title: LocalizedStringResource = "记一条 DayPage"

    static var description = IntentDescription(
        "打开 DayPage 并立即开始语音录音。",
        categoryName: "Capture",
        searchKeywords: ["record", "voice", "memo", "录音", "记一条", "快速记录", "daypage"]
    )

    /// Opens the main app, bringing it to the foreground. Required for
    /// microphone access.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Route through the deep-link handler. URL scheme is registered in
        // the main app's Info.plist (CFBundleURLSchemes = ["daypage"]).
        if let url = URL(string: "daypage://record") {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        return .result()
    }
}
