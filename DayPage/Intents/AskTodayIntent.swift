import AppIntents
import Foundation
#if canImport(UIKit) && !EXTENSION
import UIKit
#endif

// MARK: - AskTodayIntent
//
// AppIntent for ad-hoc questions answered against the user's vault. For now
// the routing target is SearchView, which already does full-text + entity
// search across memos. The intent is named with the "ask" framing so the
// shortcut is discoverable as an assistant entry point — once an on-device
// MCP/LLM pipeline is wired up we can re-route the URL without changing
// the Siri / Shortcuts surface.
//
// Routing: opens `daypage://search?q=<URL-encoded query>`.
// `DayPageApp.onOpenURL` switches to the Archive tab and stashes the
// query in `AppNavigationModel.pendingSearchQuery`. ArchiveView observes
// the property, presents SearchView pre-populated with the query, and
// clears the pending value (one-shot).

@available(iOS 16.0, *)
struct AskTodayIntent: AppIntent {

    static var title: LocalizedStringResource = "问问今天"

    static var description = IntentDescription(
        "针对你的 DayPage 内容提一个问题,跳转到搜索结果。",
        categoryName: "Search",
        searchKeywords: [
            "ask", "search", "query", "question", "find",
            "问问", "问一下", "搜索", "查找", "daypage"
        ]
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: "问题") var query: String

    /// Builds the deep-link URL. Exposed for unit tests.
    ///
    /// Uses URLComponents so reserved characters (`&`, `=`, `+`) inside the
    /// query payload are percent-encoded correctly; see QuickCaptureTextIntent
    /// for the cautionary tale.
    static func buildURL(query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "daypage"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EXTENSION
        if let url = Self.buildURL(query: query) {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}
