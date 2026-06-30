import Testing
import Foundation
import DayPageServices
@testable import DayPage

// MARK: - LLMClient parsing

@Suite("LLMClient.parseContent")
struct LLMClientParseTests {

    @Test func parsesOpenAICompatibleResponse() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"  你好，世界  "}}]}
        """
        let data = try #require(json.data(using: .utf8))
        let content = try LLMClient.parseContent(from: data)
        #expect(content == "你好，世界")  // trimmed
    }

    @Test func throwsOnMissingContent() throws {
        let json = #"{"choices":[]}"#
        let data = try #require(json.data(using: .utf8))
        #expect(throws: LLMError.self) {
            _ = try LLMClient.parseContent(from: data)
        }
    }

    @Test func throwsOnEmptyContent() throws {
        let json = #"{"choices":[{"message":{"content":"   "}}]}"#
        let data = try #require(json.data(using: .utf8))
        #expect(throws: LLMError.self) {
            _ = try LLMClient.parseContent(from: data)
        }
    }
}

// MARK: - GraphRetriever entity-page parsing

@Suite("GraphRetriever entity parsing")
struct GraphRetrieverParseTests {

    /// 合成实体页（与 EntityPageService.buildNewEntityPage 同构）。
    private static let entityPage = """
    ---
    type: place
    name: "清迈"
    slug: chiang-mai
    first_seen: 2026-03-01
    last_updated: 2026-06-10T12:00:00Z
    occurrence_count: 7
    ---

    # 清迈

    **Type**: Place
    **First seen**: 2026-03-01

    ## Visits
    - 2026-03-01: 在 Joma Coffee 工作了一下午
    - 2026-06-10: 又回到这里，熟悉的咖啡香
    """

    @Test func parsesNameAndOccurrenceCount() {
        let hit = GraphRetriever.parseEntityPage(Self.entityPage, slug: "chiang-mai", type: "places")
        #expect(hit?.displayName == "清迈")
        #expect(hit?.occurrenceCount == 7)
        #expect(hit?.type == "places")
    }

    @Test func bodySummarySkipsHeadingAndMetadata() {
        let summary = GraphRetriever.bodySummary(from: Self.entityPage)
        // 标题 "# 清迈"、**Type**、**First seen** 行应被跳过。
        #expect(!summary.contains("# 清迈"))
        #expect(!summary.contains("**Type**"))
        // 实质内容应保留。
        #expect(summary.contains("Joma Coffee"))
    }

    @Test func fallsBackToSlugWhenNameMissing() {
        let page = """
        ---
        type: theme
        occurrence_count: 2
        ---
        # whatever
        some body
        """
        let hit = GraphRetriever.parseEntityPage(page, slug: "deep-work", type: "themes")
        #expect(hit?.displayName == "deep-work")  // name 缺失 → 回退 slug
        #expect(hit?.occurrenceCount == 2)
    }
}

// MARK: - RetrievedContext prompt assembly

@Suite("RetrievedContext.toPromptContext")
struct RetrievedContextTests {

    @Test func emptyContextRendersPlaceholder() {
        let ctx = RetrievedContext(query: "x", memoHits: [], entityHits: [])
        #expect(ctx.isEmpty)
        #expect(ctx.toPromptContext() == "(未检索到相关内容)")
    }

    @Test func rendersMemoAndEntityBlocks() {
        let ctx = RetrievedContext(
            query: "清迈",
            memoHits: [.init(dateString: "2026-06-10", snippet: "回到清迈", mood: "愉快", entityMentions: ["chiang-mai"])],
            entityHits: [.init(slug: "chiang-mai", displayName: "清迈", type: "places", occurrenceCount: 7, summary: "常去的城市")]
        )
        let prompt = ctx.toPromptContext()
        #expect(prompt.contains("2026-06-10"))
        #expect(prompt.contains("愉快"))
        #expect(prompt.contains("清迈"))
        #expect(prompt.contains("地点"))  // entity type label
        #expect(prompt.contains("出现 7 次"))
    }
}

// MARK: - MemoryChatService

@Suite("MemoryChatService")
@MainActor
struct MemoryChatServiceTests {

    // static + nonisolated so we can pass it into the @Sendable `retrieve`
    // closure that MemoryChatService now requires. The suite as a whole is
    // @MainActor, so without nonisolated the static method inherits the
    // actor and the compiler rejects synchronous use from a Sendable closure.
    nonisolated static func fixedContext(_ q: String) -> RetrievedContext {
        RetrievedContext(
            query: q,
            memoHits: [.init(dateString: "2026-05-01", snippet: "测试记录", mood: nil, entityMentions: [])],
            entityHits: []
        )
    }

    @Test func askAppendsUserThenAssistantTurns() async {
        let service = MemoryChatService(
            send: { _ in "这是回答" },
            retrieve: { Self.fixedContext($0) }
        )
        await service.ask("我做了什么？")
        #expect(service.turns.count == 2)
        #expect(service.turns[0].role == .user)
        #expect(service.turns[0].text == "我做了什么？")
        #expect(service.turns[1].role == .assistant)
        #expect(service.turns[1].text == "这是回答")
        // assistant 回合应带上检索上下文，供 UI 展示来源。
        #expect(service.turns[1].context?.memoHits.first?.dateString == "2026-05-01")
        #expect(service.errorMessage == nil)
    }

    @Test func askSurfacesErrorWithoutAssistantTurn() async {
        let service = MemoryChatService(
            send: { _ in throw LLMError.rateLimited },
            retrieve: { Self.fixedContext($0) }
        )
        await service.ask("会失败")
        // 只有 user 回合；assistant 回合不入队，错误走 errorMessage。
        #expect(service.turns.count == 1)
        #expect(service.turns[0].role == .user)
        #expect(service.errorMessage != nil)
    }

    @Test func emptyQuestionIsIgnored() async {
        let service = MemoryChatService(send: { _ in "x" }, retrieve: { Self.fixedContext($0) })
        await service.ask("   ")
        #expect(service.turns.isEmpty)
    }

    @Test func buildMessagesIncludesSystemAndRetrievedContext() {
        let service = MemoryChatService(send: { _ in "" }, retrieve: { Self.fixedContext($0) })
        let ctx = Self.fixedContext("问题")
        let messages = service.buildMessages(question: "我去过哪里？", context: ctx)
        #expect(messages.first?.role == .system)
        #expect(messages.last?.role == .user)
        #expect(messages.last?.content.contains("我去过哪里？") == true)
        #expect(messages.last?.content.contains("测试记录") == true)  // 检索上下文已注入
    }

    @Test func resetClearsConversation() async {
        let service = MemoryChatService(send: { _ in "答" }, retrieve: { Self.fixedContext($0) })
        await service.ask("Q")
        service.reset()
        #expect(service.turns.isEmpty)
        #expect(service.errorMessage == nil)
    }
}
