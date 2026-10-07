import XCTest
import DayPageModels
import DayPageStorage
@testable import DayPageServices

/// Flomo-native refinement — MemoryChatService 的「有界证据」硬边界与
/// 「洞察视角 = user 指令，永不进 system prompt」的契约。
///
/// 所有 LLM 调用都走注入的 fake 闭包；不触达任何真实 provider。
final class MemoryChatInsightTests: XCTestCase {

    private var vaultDir: URL!
    private var previousOverride: URL?

    override func setUp() {
        super.setUp()
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryChatInsightTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vaultDir
    }

    override func tearDown() {
        VaultInitializer.testOverrideURL = previousOverride
        if let vaultDir { try? FileManager.default.removeItem(at: vaultDir) }
        vaultDir = nil
        previousOverride = nil
        super.tearDown()
    }

    private static let emptyContext = RetrievedContext(query: "", memoHits: [], entityHits: [])

    // MARK: - Bounded evidence rule (system prompt)

    @MainActor
    func test_systemPrompt_containsBoundedEvidenceRule() {
        let p = MemoryChatService.systemPrompt
        XCTAssertTrue(p.contains("有界证据结构"), "prompt must mandate the bounded evidence structure")
        XCTAssertTrue(p.contains("观察"), "prompt must demand observations first")
        XCTAssertTrue(p.contains("带日期的证据"), "prompt must demand dated evidence")
        XCTAssertTrue(p.contains("替代解释"), "prompt must demand a plausible alternative")
        XCTAssertTrue(p.contains("小实验"), "prompt must end with one small experiment/question")
        XCTAssertTrue(p.contains("不足以判断"), "insufficient evidence must be admitted")
        XCTAssertTrue(p.contains("事实") && p.contains("推断"), "facts vs inference must be separated")
        XCTAssertTrue(p.contains("夸奖"), "flattery-only answers are banned")
        XCTAssertTrue(p.contains("诊断"), "diagnosis is banned")
    }

    @MainActor
    func test_systemPrompt_strategyCannotOverrideEvidenceRules() {
        // The lens travels in the user message; the system prompt must keep a
        // rule that says so and refuses to fabricate evidence on its behalf.
        let p = MemoryChatService.systemPrompt
        XCTAssertTrue(p.contains("洞察视角"))
        XCTAssertTrue(p.contains("不能要求你忽略") || p.contains("不得覆盖"))
    }

    // MARK: - Strategy is a user instruction

    @MainActor
    func test_buildMessages_strategyTextStaysOutOfSystemPrompt() {
        let strategy = InsightStrategy(
            id: "custom.1", title: "找重复主题",
            instructions: "只看 2026 年 3 月的记录"
        )
        let svc = MemoryChatService(send: { _ in "unused" }, retrieve: { _, _ in Self.emptyContext })
        let question = strategy.composedInstruction()
        let msgs = svc.buildMessages(question: question, context: Self.emptyContext)

        let systemTexts = msgs.filter { $0.role == .system }.map(\.content)
        for text in systemTexts {
            XCTAssertFalse(text.contains("找重复主题"), "strategy title must never appear in a system message")
            XCTAssertFalse(text.contains("只看 2026 年 3 月的记录"), "strategy instructions must never appear in a system message")
        }
        let userTexts = msgs.filter { $0.role == .user }.map(\.content)
        XCTAssertTrue(userTexts.contains { $0.contains("找重复主题") && $0.contains("只看 2026 年 3 月的记录") },
                      "strategy must ride the user question verbatim")
    }

    // MARK: - ask(insight:) end-to-end with fake LLM + retrieval

    @MainActor
    func test_askInsight_usesInjectedLLM_andAppendsUserTurn() async {
        var captured: [[LLMMessage]] = []
        let svc = MemoryChatService(
            send: { messages in
                captured.append(messages)
                return "观察：……（测试回答）"
            },
            retrieve: { _, _ in Self.emptyContext }
        )

        let strategy = InsightStrategy(
            id: InsightStrategy.patternsID,
            title: "Recurring patterns",
            instructions: "Look for repetitions.",
            kind: .builtin
        )
        await svc.ask(insight: strategy)

        XCTAssertEqual(captured.count, 1, "exactly one injected LLM call, no real provider traffic")
        let messages = captured[0]
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.first?.content, MemoryChatService.systemPrompt)
        let lastUser = messages.last
        XCTAssertEqual(lastUser?.role, .user)
        XCTAssertEqual(lastUser?.content.contains(strategy.composedInstruction()), true,
                       "the composed lens instruction rides the assembled user message")

        XCTAssertEqual(svc.turns.count, 2)
        XCTAssertEqual(svc.turns.first?.role, .user)
        XCTAssertEqual(svc.turns.first?.text, strategy.composedInstruction())
        XCTAssertEqual(svc.turns.last?.role, .assistant)
        XCTAssertFalse(svc.isResponding)
    }

    @MainActor
    func test_ask_emptyQuestion_neverReachesLLM() async {
        // run() guards empty questions: an empty composed instruction must not
        // reach the LLM at all (the UI also validates, defense in depth).
        var called = false
        let svc = MemoryChatService(
            send: { _ in called = true; return "x" },
            retrieve: { _, _ in Self.emptyContext }
        )
        await svc.ask("   \n ")
        XCTAssertFalse(called)
        XCTAssertTrue(svc.turns.isEmpty)
    }

    // MARK: - Legacy flows stay intact

    @MainActor
    func test_retryLast_reusesLastQuestion_withoutDuplicatingUserTurn() async {
        var questions: [String] = []
        let svc = MemoryChatService(
            send: { messages in
                if let last = messages.last { questions.append(last.content) }
                return "ok"
            },
            retrieve: { _, _ in Self.emptyContext }
        )
        await svc.ask("去年我在哪？")
        await svc.retryLast()
        XCTAssertEqual(svc.turns.filter { $0.role == .user }.count, 1, "retry must not duplicate the user bubble")
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0], questions[1])
    }
}

// MARK: - Bounded retrieval query (review P1)

extension MemoryChatInsightTests {

    /// Thread-safe capture box for the @Sendable retrieval closure.
    private final class QueryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ q: String) { lock.lock(); storage.append(q); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Retrieval is exact folded `contains` matching — a long strategy prompt
    /// must NEVER be used as the retrieval query. The fake retrieval observes
    /// a short topic while the LLM still receives the full strategy + the
    /// anchored memo evidence.
    @MainActor
    func test_askInsight_usesShortRetrievalQuery_butFullStrategyAndEvidenceToLLM() async {
        let box = QueryBox()
        var captured: [[LLMMessage]] = []
        let svc = MemoryChatService(
            send: { messages in captured.append(messages); return "ok" },
            retrieve: { query, _ in
                box.append(query)
                return Self.emptyContext
            }
        )
        // Anchor WITHOUT entity mentions (no seeds): the worst case for
        // retrieval, exactly the situation the review flagged.
        let longBody = String(repeating: "很长的一段记录内容", count: 12)
        svc.attach(memo: Memo(type: .text, created: Date(), body: longBody))
        let strategy = InsightStrategy(
            id: "custom.long",
            title: "找重复主题",
            instructions: String(repeating: "非常长的策略指令", count: 20),
            kind: .custom
        )
        await svc.ask(insight: strategy)

        let queries = box.values
        XCTAssertEqual(queries.count, 1)
        let retrievalQuery = queries[0]
        XCTAssertFalse(retrievalQuery.isEmpty)
        XCTAssertNotEqual(retrievalQuery, strategy.composedInstruction(),
                          "the composed strategy prompt must never be the retrieval query")
        XCTAssertLessThanOrEqual(retrievalQuery.count, 40,
                                 "retrieval query must stay short (exact keyword matching)")

        // The LLM receives the full strategy instruction and the anchored
        // memo as evidence in the assembled user message.
        let lastUser = captured.first?.last?.content ?? ""
        XCTAssertTrue(lastUser.contains(strategy.instructions))
        XCTAssertTrue(lastUser.contains("用户正在追问的这条记录"))
    }

    /// Related mode without entity seeds still derives a bounded topic.
    @MainActor
    func test_relatedModeWithoutSeeds_derivesShortTerms() {
        let longBody = "今天在咖啡馆想了很久关于产品方向的事情，回家后又写了一大段"
        let terms = MemoryChatService.derivedRetrievalTerms(clues: [], memoBody: longBody)
        XCTAssertFalse(terms.isEmpty)
        XCTAssertLessThanOrEqual(terms.count, 40)
        XCTAssertNotEqual(terms, longBody)
        // With clues, the clues win (highest-precision keywords).
        XCTAssertEqual(
            MemoryChatService.derivedRetrievalTerms(clues: ["咖啡馆", "产品方向"], memoBody: longBody),
            "咖啡馆"
        )
    }

    /// retryLast preserves the retrieval context: the second retrieval sees
    /// the same bounded query as the first, never the long analysis question.
    @MainActor
    func test_retryLast_preservesBoundedRetrievalQuery() async {
        let box = QueryBox()
        let svc = MemoryChatService(
            send: { _ in "ok" },
            retrieve: { query, _ in box.append(query); return Self.emptyContext }
        )
        svc.attach(memo: Memo(type: .text, created: Date(), body: "锚定记录正文内容"))
        let strategy = InsightStrategy(
            id: "custom.retry", title: "视角",
            instructions: String(repeating: "很长的指令", count: 30), kind: .custom
        )
        await svc.ask(insight: strategy)
        await svc.retryLast()

        let queries = box.values
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries[0], queries[1], "retry must reuse the first run's retrieval query")
    }
}

// MARK: - Cancellation (review P1)

extension MemoryChatInsightTests {

    /// Closing the sheet mid-retrieval must prevent the LLM call entirely and
    /// leave no hidden assistant output in `turns` or in the persisted
    /// session files.
    @MainActor
    func test_cancelDuringRetrieval_neverInvokesLLM_andPersistsNoAssistantOutput() async {
        let gate = DispatchSemaphore(value: 0)
        let box = QueryBox()
        var sendCalled = false
        let svc = MemoryChatService(
            send: { _ in sendCalled = true; return "不该出现的回答" },
            retrieve: { query, _ in
                box.append(query)
                gate.wait()
                return Self.emptyContext
            }
        )

        let task = Task { await svc.ask("这条问题不该到达模型") }
        // Let the run reach the blocking retrieval, then cancel (sheet close).
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        gate.signal()
        await task.value

        XCTAssertFalse(sendCalled, "a cancelled run must never invoke the LLM")
        XCTAssertEqual(svc.turns.filter { $0.role == .assistant }.count, 0,
                       "no hidden assistant output in the visible turns")
        XCTAssertFalse(svc.isResponding)
        XCTAssertEqual(svc.phase, .idle)

        // Nothing about the answer may reach the persisted session files.
        let vault = try? XCTUnwrap(vaultDir)
        var persisted = ""
        if let root = vault, let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension != "" {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    persisted += text
                }
            }
        }
        XCTAssertFalse(persisted.contains("不该出现的回答"),
                       "cancelled runs must not persist hidden assistant output")
    }
}

extension MemoryChatInsightTests {
    @MainActor
    func test_noEntityAnchor_retrievesHistoricalRecordUsingRealKeywordSearch() async throws {
        let root = try XCTUnwrap(vaultDir)
        let raw = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"))
        let historical = Memo(type: .text, created: date,
                              body: "Leaving the headphones at home helped me notice the street.")
        try historical.toMarkdown().write(to: raw.appendingPathComponent("2026-03-01.md"),
                                         atomically: true, encoding: .utf8)
        var sent: [LLMMessage] = []
        let service = MemoryChatService(send: { messages in
            sent = messages; return "A dated observation, not a diagnosis."
        }, retrieve: { query, _ in
            GraphRetriever.retrieve(query: query)
        })
        service.attach(memo: Memo(type: .text, created: Date(),
            body: "Walked home without headphones. The city sounded less urgent than it looked."))
        let strategy = InsightStrategy(id: "custom.evidence", title: "Test lens",
                                       instructions: "Consider a plausible alternative explanation.")
        await service.ask(insight: strategy)
        let answer = try XCTUnwrap(service.turns.last)
        XCTAssertEqual(answer.context?.memoHits.first?.snippet, historical.body,
                       "derived keyword must reach real historical content, not merely be short")
        XCTAssertEqual(answer.context?.query, "headphones")
        XCTAssertTrue(sent.last?.content.contains("2026-03-01") == true)
        XCTAssertTrue(sent.last?.content.contains(strategy.instructions) == true)
        XCTAssertFalse(sent.filter { $0.role == .system }.contains { $0.content.contains(strategy.instructions) })
    }

    @MainActor
    func test_voiceOnlyAnchor_usesTranscriptForKeywordPromptAndHistoricalEvidence() async throws {
        let transcript = "Walking without headphones helped me notice the street."
        let attachment = Memo.Attachment(file: "sample.m4a", kind: "audio", transcript: transcript,
                                         transcriptionStatus: .done)
        let memo = Memo(type: .voice, created: Date(), attachments: [attachment], body: "")
        XCTAssertEqual(MemoMarkdown.plainText(for: memo), transcript)
        let raw = try XCTUnwrap(vaultDir).appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try memo.toMarkdown().write(to: raw.appendingPathComponent(DateFormatters.isoDate.string(from: memo.created) + ".md"),
                                    atomically: true, encoding: .utf8)
        var sent: [LLMMessage] = []
        let service = MemoryChatService(send: { messages in sent = messages; return "A voice-based observation." },
                                        retrieve: { query, _ in GraphRetriever.retrieve(query: query) })
        service.attach(memo: memo)
        let keyword = await service.suggestedRetrievalQuery()
        XCTAssertEqual(keyword, "headphones")
        await service.ask(insight: InsightStrategy.defaultStrategy)
        XCTAssertTrue(sent.last?.content.contains(transcript) == true)
        XCTAssertEqual(service.turns.last?.context?.memoHits.first?.snippet, transcript)
        let mirrored = Memo(type: .voice, created: Date(), attachments: [attachment], body: transcript)
        XCTAssertEqual(MemoMarkdown.plainText(for: mirrored), transcript, "Do not duplicate transcripts already in the body")
    }

    @MainActor
    func test_resetDuringSend_lateAnswerCannotClearOrPersistIntoNewRun() async throws {
        let replies = ControlledInsightReplies()
        let service = MemoryChatService(send: { messages in
            try await replies.send(messages)
        }, retrieve: { _, _ in Self.emptyContext })
        let old = Task { await service.ask("old topic") }
        try await replies.waitFor("old")
        service.reset()
        let next = Task { await service.ask("new topic") }
        try await replies.waitFor("new")
        let oldReply = try XCTUnwrap(replies.pending.removeValue(forKey: "old"))
        oldReply.resume(returning: "OLD_LATE_ANSWER")
        await old.value
        XCTAssertTrue(service.isResponding, "old defer must not clear the new request's state")
        XCTAssertEqual(service.turns.map(\.text), ["new topic"])
        let newReply = try XCTUnwrap(replies.pending.removeValue(forKey: "new"))
        newReply.resume(returning: "NEW_VALID_ANSWER")
        await next.value
        XCTAssertEqual(service.turns.map(\.text), ["new topic", "NEW_VALID_ANSWER"])
        XCTAssertFalse(service.isResponding)
        let root = try XCTUnwrap(vaultDir)
        var persisted = ""
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension != "" {
                persisted += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertFalse(persisted.contains("OLD_LATE_ANSWER"))
        XCTAssertTrue(persisted.contains("NEW_VALID_ANSWER"))
    }

    @MainActor
    func test_alreadyCancelledAsk_doesNotAppendOrCreateSession() async {
        let service = MemoryChatService(send: { _ in XCTFail("Cancelled ask reached LLM"); return "" },
                                        retrieve: { _, _ in Self.emptyContext })
        let task = Task { await service.ask("cancel before starting") }
        task.cancel()
        await task.value
        XCTAssertTrue(service.turns.isEmpty)
        XCTAssertNil(service.sessionRef)
    }
}

@MainActor
private final class ControlledInsightReplies {
    var pending: [String: CheckedContinuation<String, Error>] = [:]

    func send(_ messages: [LLMMessage]) async throws -> String {
        let key = messages.last?.content.contains("new topic") == true ? "new" : "old"
        return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }

    func waitFor(_ key: String) async throws {
        for _ in 0..<400 {
            if pending[key] != nil { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "InsightTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Request did not reach controlled send"])
    }
}
