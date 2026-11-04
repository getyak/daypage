import XCTest
@testable import DayPageCore

private actor ProposalEvents {
  var values: [AgentEvent] = []
  func append(_ event: AgentEvent) { values.append(event) }
}

final class AgentProposalTests: XCTestCase {
  func testModelCanOnlyProposeAndTheExactProposalSurvivesConversationReopening() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let user = ChatMessage(role: .user, content: "Create a note")
    let fixture = try AIFixture([
      ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": [
        ["id": "create", "type": "function", "function": ["name": "notes_create",
          "arguments": #"{"body":"Keep this idea"}"#]]]]]]],
      ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Review the proposed note."]]]]
    ])
    let events = ProposalEvents()
    let client = AIClient(transport: AITransport(load: { request, _ in try await fixture.load(request) }))
    try await client.runWithTools(configuration: .init(baseURL: "https://example.com/v1", model: "fixture-model"),
      apiKey: "fixture", messages: [user], context: .build(entries: [], question: ""),
      toolContext: .init(entries: [], proposalWriter: { try await store.saveProposal($0) },
        proposalNamespace: user.id), character: .companion,
      onEvent: { await events.append($0) })
    let captured = await events.values
    let proposals = captured.compactMap { event -> [NoteActionProposal]? in
      if case .proposals(let values) = event { return values }; return nil
    }.last ?? []
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals.first?.body, "Keep this idea")
    let entries = try await store.entries()
    XCTAssertTrue(entries.isEmpty, "A model tool call must never commit a note")
    let pending = try await store.pendingProposals()
    XCTAssertEqual(pending, proposals)
    var reply = ChatMessage(role: .assistant, content: "Review it", delivery: .complete)
    reply.proposals = proposals
    let conversation = Conversation(messages: [user, reply])
    let history = ConversationStore(root: root)
    try await history.save(conversation)
    let reopened = try await ConversationStore(root: root).load(id: conversation.id)
    XCTAssertEqual(reopened.messages.last?.proposals, proposals)
    let recorded = await fixture.recorded()
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorded.last?.httpBody)) as? [String: Any])
    let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let result = try XCTUnwrap(turns.last?["content"] as? String)
    XCTAssertTrue(result.contains("pending_confirmation"))
  }

  func testLegacyConversationWithoutActionsStillDecodes() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","scope":"all-notes","messages":[{"id":"00000000-0000-0000-0000-000000000002","role":"assistant","content":"Old answer"}],"draft":""}"#.utf8)
    let old = try JSONDecoder().decode(Conversation.self, from: data)
    XCTAssertNil(old.messages.first?.proposals)
    XCTAssertNil(old.messages.first?.receipts)
    XCTAssertNil(old.messages.first?.dismissedProposalIDs)
  }
}
