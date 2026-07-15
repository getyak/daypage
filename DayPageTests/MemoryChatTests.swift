import Testing
import Foundation
import DayPageServices
import DayPageStorage
import DayPageModels
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

/// Serialized because tests mutate global `VaultInitializer.testOverrideURL`
/// (session 化后 `ask` 会真实落盘 —— 不隔离会把测试会话泄漏进真机/模拟器
/// 的 vault/wiki/chats，正是 2026-07-15 验收时撞见的污染源)。
@Suite("MemoryChatService", .serialized)
@MainActor
struct MemoryChatServiceTests {

    private let tempVault: URL

    init() throws {
        tempVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryChatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempVault.appendingPathComponent("wiki/chats", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = tempVault
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempVault)
    }

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
        defer { cleanup() }
        let service = MemoryChatService(
            send: { _ in "这是回答" },
            retrieve: { q, _ in Self.fixedContext(q) }
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
        defer { cleanup() }
        let service = MemoryChatService(
            send: { _ in throw LLMError.rateLimited },
            retrieve: { q, _ in Self.fixedContext(q) }
        )
        await service.ask("会失败")
        // 只有 user 回合；assistant 回合不入队，错误走 errorMessage。
        #expect(service.turns.count == 1)
        #expect(service.turns[0].role == .user)
        #expect(service.errorMessage != nil)
    }

    @Test func emptyQuestionIsIgnored() async {
        defer { cleanup() }
        let service = MemoryChatService(send: { _ in "x" }, retrieve: { q, _ in Self.fixedContext(q) })
        await service.ask("   ")
        #expect(service.turns.isEmpty)
    }

    @Test func buildMessagesIncludesSystemAndRetrievedContext() {
        defer { cleanup() }
        let service = MemoryChatService(send: { _ in "" }, retrieve: { q, _ in Self.fixedContext(q) })
        let ctx = Self.fixedContext("问题")
        let messages = service.buildMessages(question: "我去过哪里？", context: ctx)
        #expect(messages.first?.role == .system)
        #expect(messages.last?.role == .user)
        #expect(messages.last?.content.contains("我去过哪里？") == true)
        #expect(messages.last?.content.contains("测试记录") == true)  // 检索上下文已注入
    }

    @Test func resetClearsConversation() async {
        defer { cleanup() }
        let service = MemoryChatService(send: { _ in "答" }, retrieve: { q, _ in Self.fixedContext(q) })
        await service.ask("Q")
        service.reset()
        #expect(service.turns.isEmpty)
        #expect(service.errorMessage == nil)
    }
}

// MARK: - LLMClient SSE line parsing (issue #837)

@Suite("LLMClient.parseSSELine")
struct LLMClientSSETests {

    @Test func parsesDeltaChunk() {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        #expect(LLMClient.parseSSELine(line) == .delta("你好"))
    }

    @Test func recognizesDoneSentinel() {
        #expect(LLMClient.parseSSELine("data: [DONE]") == .done)
    }

    @Test func ignoresNonDataLinesAndEmptyDeltas() {
        #expect(LLMClient.parseSSELine("") == .ignore)
        #expect(LLMClient.parseSSELine(": keep-alive") == .ignore)
        #expect(LLMClient.parseSSELine("event: message") == .ignore)
        // role-only first chunk（无 content）与空 content 都应忽略。
        #expect(LLMClient.parseSSELine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .ignore)
        #expect(LLMClient.parseSSELine(#"data: {"choices":[{"delta":{"content":""}}]}"#) == .ignore)
        #expect(LLMClient.parseSSELine("data: not-json") == .ignore)
    }
}

// MARK: - Memo-anchored chat (issue #837)

/// Serialized —— 同 MemoryChatServiceTests：ask() 落盘，须用临时 vault 隔离。
@Suite("MemoryChatService memo anchoring", .serialized)
@MainActor
struct MemoAnchoredChatTests {

    private let tempVault: URL

    init() throws {
        tempVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoAnchoredChatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempVault.appendingPathComponent("wiki/chats", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = tempVault
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempVault)
    }

    nonisolated static func fixedContext(_ q: String) -> RetrievedContext {
        RetrievedContext(
            query: q,
            memoHits: [.init(dateString: "2026-06-22", snippet: "旧的信息架构太吵了", mood: nil, entityMentions: ["xinxi-jiagou"])],
            entityHits: []
        )
    }

    private func makeMemo() -> Memo {
        Memo(
            type: .text,
            created: ISO8601DateFormatter.memo.date(from: "2026-07-12T02:00:00.000Z")!,
            mood: "平静",
            entityMentions: ["xinxi-jiagou", "daypage-dev"],
            body: "凌晨改完档案页的信息架构，出奇地安静。"
        )
    }

    @Test func buildMessagesIncludesAnchoredMemoBlockAndRule() {
        defer { cleanup() }
        let service = MemoryChatService(send: { _ in "" }, retrieve: { q, _ in Self.fixedContext(q) })
        service.attach(memo: makeMemo(), clues: ["信息架构"])
        let messages = service.buildMessages(question: "当时我为什么这么想？", context: Self.fixedContext("x"))

        // system prompt + 锚定规则两条 system 消息。
        let systems = messages.filter { $0.role == .system }
        #expect(systems.count == 2)
        #expect(systems[1].content.contains("针对它追问"))

        let user = messages.last
        #expect(user?.content.contains("用户正在追问的这条记录") == true)
        #expect(user?.content.contains("凌晨改完档案页的信息架构") == true)
        #expect(user?.content.contains("情绪：平静") == true)
        #expect(user?.content.contains("当时我为什么这么想？") == true)
    }

    @Test func detachRemovesMemoBlock() {
        defer { cleanup() }
        let service = MemoryChatService(send: { _ in "" }, retrieve: { q, _ in Self.fixedContext(q) })
        service.attach(memo: makeMemo())
        service.detachMemo()
        let messages = service.buildMessages(question: "Q", context: Self.fixedContext("x"))
        #expect(messages.filter { $0.role == .system }.count == 1)
        #expect(messages.last?.content.contains("用户正在追问的这条记录") == false)
    }

    @Test func askSeedsRetrievalWithAttachedMemoEntities() async {
        defer { cleanup() }
        // Capture the seed slugs the service hands to the retriever.
        let captured = CapturedSeeds()
        let service = MemoryChatService(
            send: { _ in "答" },
            retrieve: { q, seeds in
                captured.record(seeds)
                return Self.fixedContext(q)
            }
        )
        service.attach(memo: makeMemo(), clues: ["信息架构"])
        await service.ask("关于信息架构我说过什么？")
        #expect(captured.value == ["xinxi-jiagou", "daypage-dev"])
        #expect(service.turns.count == 2)
        // 回合结束后 agent 状态应复位。
        #expect(service.phase == .idle)
        #expect(service.streamingText.isEmpty)
    }

    @Test func attachFallsBackToDehyphenatedSlugsAsClues() {
        defer { cleanup() }
        let service = MemoryChatService(send: { _ in "" }, retrieve: { q, _ in Self.fixedContext(q) })
        service.attach(memo: makeMemo())
        #expect(service.attachedClues == ["xinxi jiagou", "daypage dev"])
    }

    @Test func streamSendPathAccumulatesStreamingTextInOrder() async {
        defer { cleanup() }
        let service = MemoryChatService(
            send: { _ in "unused" },
            streamSend: { _, onDelta in
                let chunks = ["你在", " 2026-06-22 ", "提到过它。"]
                for c in chunks { await onDelta(c) }
                return chunks.joined()
            },
            retrieve: { q, _ in Self.fixedContext(q) }
        )
        await service.ask("它是什么时候开始的？")
        #expect(service.turns.count == 2)
        #expect(service.turns[1].text == "你在 2026-06-22 提到过它。")
        // 完成后增量缓冲清空、状态复位。
        #expect(service.streamingText.isEmpty)
        #expect(service.phase == .idle)
    }

    @Test func retryLastDoesNotDuplicateUserTurn() async {
        defer { cleanup() }
        let flaky = FlipFlop()
        let service = MemoryChatService(
            send: { _ in
                if flaky.flip() { throw LLMError.networkTimeout }
                return "第二次成功"
            },
            retrieve: { q, _ in Self.fixedContext(q) }
        )
        await service.ask("会先失败的问题")
        #expect(service.turns.count == 1)
        #expect(service.errorMessage != nil)

        await service.retryLast()
        #expect(service.turns.count == 2)      // user + assistant，无重复 user
        #expect(service.turns[0].role == .user)
        #expect(service.turns[1].text == "第二次成功")
        #expect(service.errorMessage == nil)
    }
}

/// 跨 @Sendable 闭包捕获检索种子的小盒子（class 引用语义；测试里检索
/// 闭包只被调用一次，无并发写）。
private final class CapturedSeeds: @unchecked Sendable {
    private(set) var value: [String] = []
    func record(_ seeds: [String]) { value = seeds }
}

/// 第一次调用返回 true（触发失败），之后 false。
private final class FlipFlop: @unchecked Sendable {
    private var first = true
    func flip() -> Bool {
        defer { first = false }
        return first
    }
}
