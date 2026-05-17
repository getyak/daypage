import AppIntents
import Foundation
#if canImport(UIKit) && !EXTENSION
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
// Behaviour by call site:
//   • Inside the main app process — `UIApplication.shared.open` is available;
//     we open the deep link explicitly so the URL handler runs uniformly.
//   • Inside the Widget extension process — `UIApplication.shared` is banned
//     by the linker. We rely on `openAppWhenRun = true` plus WidgetKit's
//     built-in behaviour: tapping a `Button(intent:)` or `ControlWidgetButton`
//     foregrounds the app, and `DayPageApp.onAppear` / cold-launch flow can
//     pick up the pending trigger via the URL scheme set by the Widget's
//     `widgetURL(_:)` modifier (or, for the parameter-less control widget,
//     we just rely on the app being foregrounded plus a one-shot trigger
//     stored in shared UserDefaults — see WidgetBridge).
//
// Routing everything through the daypage://record URL keeps a single
// deep-link handler in DayPageApp.onOpenURL to maintain, and the same code
// path works when the user manually pastes the URL.

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
        // When invoked from inside the main app process (Siri / Shortcuts /
        // Spotlight) we can open the URL ourselves so the handler runs
        // immediately. In the extension process `UIApplication.shared` is
        // unavailable; `openAppWhenRun = true` plus the widget's `widgetURL`
        // (set on the Button surface) take care of foregrounding + deep link.
        #if !EXTENSION
        if let url = URL(string: "daypage://record") {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}
