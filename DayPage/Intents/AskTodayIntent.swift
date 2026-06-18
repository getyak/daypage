import AppIntents
import Foundation
#if canImport(UIKit) && !EXTENSION
import UIKit
#endif

// MARK: - AskTodayIntent
//
// AppIntent for ad-hoc questions answered against the user's vault.
//
// Routing: opens `daypage://ask?q=<URL-encoded query>`, which RootView turns
// into the "和过去对话" memory-chat agent (D1, research doc §3) — graph-augmented
// retrieval (D2) over the vault + an LLM answer with cited sources. This is the
// pipeline the intent's "ask" framing always pointed at; it previously routed to
// keyword SearchView as a placeholder until the chat agent existed.
//
// `DayPageApp.onOpenURL` stashes the query in
// `AppNavigationModel.pendingAskQuery`. RootView observes the property, presents
// the AskPastView chat sheet seeded with the question, and clears the pending
// value (one-shot, so re-firing the shortcut re-opens the sheet).

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
        components.host = "ask"
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
