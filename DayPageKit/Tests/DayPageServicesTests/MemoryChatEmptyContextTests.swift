import XCTest
@testable import DayPageServices

/// Issue #804 — 验证 MemoryChatService 的空 context 处理路径：prompt 应指导
/// 模型区分「真的问历史」vs「其实是想 dump 当下」两种情况。
final class MemoryChatEmptyContextTests: XCTestCase {

    // MARK: - System prompt regression guard

    func test_systemPrompt_contains_dump_intent_guidance() {
        let p = MemoryChatService.systemPrompt
        XCTAssertTrue(p.contains("不知道写什么"), "prompt must acknowledge dump intent")
        XCTAssertTrue(p.contains("陪你写今天") || p.contains("陪你继续写"),
                      "prompt must redirect to Coach for present-tense inputs")
        XCTAssertTrue(p.contains("此刻记录"), "prompt must offer present-tense reframe")
    }

    // MARK: - Empty-context message assembly

    @MainActor
    func test_buildMessages_empty_context_still_includes_promptContext_header() async {
        let svc = MemoryChatService(send: { _ in "unused" }, retrieve: { _ in
            RetrievedContext(query: "", memoHits: [], entityHits: [])
        })
        let empty = RetrievedContext(query: "", memoHits: [], entityHits: [])
        let msgs = svc.buildMessages(question: "我不知道想做什么", context: empty)
        XCTAssertGreaterThanOrEqual(msgs.count, 2)
        let lastUser = msgs.last
        XCTAssertEqual(lastUser?.role, .user)
        XCTAssertTrue(lastUser?.content.contains("我的问题") ?? false)
    }

    // MARK: - Pin to diary formatting

    @MainActor
    func test_pinTurnToDiary_rejects_empty_and_user_role() {
        let svc = MemoryChatService(send: { _ in "" }, retrieve: { _ in
            RetrievedContext(query: "", memoHits: [], entityHits: [])
        })
        let empty = ChatTurn(role: .assistant, text: "")
        XCTAssertFalse(svc.pinTurnToDiary(empty))
        let userTurn = ChatTurn(role: .user, text: "问过什么")
        XCTAssertFalse(svc.pinTurnToDiary(userTurn))
    }
}
