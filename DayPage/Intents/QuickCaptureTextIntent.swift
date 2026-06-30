import AppIntents
import Foundation
#if canImport(UIKit) && !EXTENSION
import UIKit
import DayPageServices
#endif

// MARK: - QuickCaptureTextIntent
//
// AppIntent that pre-fills Today's draft input with a piece of text from any
// system-level entry point that can pass a string parameter:
//
//   • Siri / Shortcuts.app (with a "Text" parameter)
//   • Share Sheet → Shortcuts → "记一条文本"
//   • Action Button assigned to a parameterised shortcut
//
// Routing: `perform()` opens `daypage://memo/new?text=<URL-encoded text>`.
// `DayPageApp.onOpenURL` already handles this URL — it switches to the
// Today tab and stores the text in `AppNavigationModel.pendingDraftText`,
// which TodayView consumes to pre-fill the input bar.
//
// Funnelling through the URL keeps a single deep-link handler in DayPageApp
// and matches the pattern used by `StartRecordingIntent`.

@available(iOS 16.0, *)
struct QuickCaptureTextIntent: AppIntent {

    static var title: LocalizedStringResource = "记一条文本"

    static var description = IntentDescription(
        "把一段文字发送到 DayPage,预填到今天的输入框。",
        categoryName: "Capture",
        searchKeywords: [
            "text", "note", "memo", "capture", "draft",
            "记一条", "记一笔", "文本", "草稿", "daypage"
        ]
    )

    /// We need the app foregrounded so TodayView can consume the pending draft.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "文本") var text: String

    /// Builds the deep-link URL. Exposed as a static helper so unit tests can
    /// verify URL construction without needing a live `UIApplication`.
    ///
    /// Uses URLComponents so reserved query characters (`&`, `=`, `+`, `#`)
    /// inside the text payload are percent-encoded — otherwise a body like
    /// "今天 & 明天 = 好" gets clipped at the `&` by the receiving parser.
    static func buildURL(text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "daypage"
        components.host = "memo"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EXTENSION
        if let url = Self.buildURL(text: text) {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}
