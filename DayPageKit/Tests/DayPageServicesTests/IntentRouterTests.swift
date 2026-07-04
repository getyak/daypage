import XCTest
@testable import DayPageServices

/// Issue #804 — 保证 Today sparkle 输入的意图分类正确，防止「我不知道
/// 想做什么」被路由到历史检索的回归。
final class IntentRouterTests: XCTestCase {

    // MARK: - recordToday（核心兜底）

    func test_unknown_dump_goes_to_recordToday_not_askPast() {
        // 用户视频里出现的原句——必须走 Coach，不能走 RAG。
        XCTAssertEqual(IntentRouter.classify("我不知道想做什么"), .recordToday)
        XCTAssertEqual(IntentRouter.classify("脑子乱"), .recordToday)
        XCTAssertEqual(IntentRouter.classify("随便写点"), .recordToday)
        XCTAssertEqual(IntentRouter.classify("dump 一下"), .recordToday)
    }

    // MARK: - askPast

    func test_history_time_plus_question_goes_to_askPast() {
        XCTAssertEqual(IntentRouter.classify("去年这个时候我在做什么？"), .askPast)
        XCTAssertEqual(IntentRouter.classify("上个月我去哪了？"), .askPast)
        XCTAssertEqual(IntentRouter.classify("last year what was i doing?"), .askPast)
    }

    func test_history_pattern_words_goes_to_askPast() {
        XCTAssertEqual(IntentRouter.classify("我提到最多的地方是哪里？"), .askPast)
        XCTAssertEqual(IntentRouter.classify("最近几个月的情绪趋势？"), .askPast)
    }

    func test_history_hint_context_upgrades_ambiguous_to_askPast() {
        // 在 AskPastView 已经打开的上下文里，模糊输入优先按 askPast 处理，
        // 除非用户明确说了「现在/此刻」。
        XCTAssertEqual(
            IntentRouter.classify("最近怎么样", hasHistoryHints: true),
            .askPast
        )
        XCTAssertEqual(
            IntentRouter.classify("现在有点累", hasHistoryHints: true),
            .clarifyMood
        )
    }

    // MARK: - clarifyMood

    func test_mood_words_without_history_goes_to_clarifyMood() {
        XCTAssertEqual(IntentRouter.classify("有点累"), .clarifyMood)
        XCTAssertEqual(IntentRouter.classify("今天心情很低落"), .clarifyMood)
        XCTAssertEqual(IntentRouter.classify("feeling stuck today"), .clarifyMood)
    }

    // MARK: - actionSeed

    func test_action_words_goes_to_actionSeed() {
        XCTAssertEqual(IntentRouter.classify("明天该做什么？"), .actionSeed)
        XCTAssertEqual(IntentRouter.classify("接下来我想放松一下"), .actionSeed)
        XCTAssertEqual(IntentRouter.classify("what should i do tomorrow"), .actionSeed)
    }

    // MARK: - compile

    func test_explicit_compile_command() {
        XCTAssertEqual(IntentRouter.classify("帮我编译今天"), .compile)
        XCTAssertEqual(IntentRouter.classify("生成日报"), .compile)
        XCTAssertEqual(IntentRouter.classify("compile today"), .compile)
    }

    // MARK: - backend mapping

    func test_backend_mapping() {
        XCTAssertEqual(ChatIntent.recordToday.backend, .todayCoach)
        XCTAssertEqual(ChatIntent.clarifyMood.backend, .todayCoach)
        XCTAssertEqual(ChatIntent.actionSeed.backend, .todayCoach)
        XCTAssertEqual(ChatIntent.unknown.backend, .todayCoach)
        XCTAssertEqual(ChatIntent.askPast.backend, .memoryChat)
        XCTAssertEqual(ChatIntent.compile.backend, .compiler)
    }

    // MARK: - edge cases

    func test_empty_or_whitespace_returns_unknown_and_routes_to_coach() {
        XCTAssertEqual(IntentRouter.classify(""), .unknown)
        XCTAssertEqual(IntentRouter.classify("   \n  "), .unknown)
        // 兜底仍是 todayCoach——不能把空字符串扔进 RAG。
        XCTAssertEqual(ChatIntent.unknown.backend, .todayCoach)
    }
}
