import XCTest
@testable import DayPageCore

private actor AgentEvents {
  private var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
  func values() -> [AgentEvent] { events }
}

final class AgentLoopTests: XCTestCase {
  private var config: AIConfiguration { .init(baseURL: "https://example.com/v1", model: "fixture-model") }
  private var context: NoteContext { .build(entries: [], question: "") }
  private var messages: [ChatMessage] { [.init(role: .user, content: "Find the trip")] }
  private func call(_ id: String = "call-1", name: String = "notes_search", arguments: String = #"{"query":"trip"}"#) -> [String: Any] {
    ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
  }
  private func response(_ calls: [[String: Any]], reason: String = "tool_calls") -> [String: Any] {
    ["choices": [["finish_reason": reason, "message": ["role": "assistant", "content": NSNull(), "tool_calls": calls]]]]
  }
  private var final: [String: Any] {
    ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Found your trip."]]]]
  }
  private func client(_ fixture: AIFixture) -> AIClient {
    AIClient(transport: AITransport(load: { request, _ in try await fixture.load(request) }))
  }
  func testOpenAIToolRoundReturnsResultsAndStructuredSourcesToSameProvider() async throws {
    let note = NotebookEntry(memo: Memo(body: "A trip to the hills"), day: "2026-11-03", namespace: "import")
    let fixture = try AIFixture([response([call()]), final])
    let events = AgentEvents()
    try await client(fixture).runWithTools(configuration: config, apiKey: "fixture-key", messages: messages,
      context: context, toolContext: NoteToolContext(entries: [note]), character: .companion,
      onEvent: { await events.append($0) })
    let requests = await fixture.recorded()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "example.com" })
    let first = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
    XCTAssertEqual((first["tools"] as? [[String: Any]])?.count, 6)
    let second = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
    let payload = try XCTUnwrap(second["messages"] as? [[String: Any]])
    let result = try XCTUnwrap(payload.last)
    XCTAssertEqual(result["role"] as? String, "tool")
    XCTAssertEqual(result["tool_call_id"] as? String, "call-1")
    XCTAssertTrue((result["content"] as? String)?.contains(note.id) == true)
    let recorded = await events.values()
    XCTAssertTrue(recorded.contains(.toolStarted("notes_search")))
    XCTAssertTrue(recorded.contains { if case .sources(let sources) = $0 { return sources.map(\.cardRef) == [note.id] }; return false })
    XCTAssertEqual(recorded.suffix(2), [.stream(.text("Found your trip.")), .stream(.finished)])
  }
  func testAnthropicUsesNativeBlocksAndReturnsAllResultsInOneUserTurn() async throws {
    var configuration = AIProvider.anthropic.configuration; configuration.model = "claude-fixture"
    let fixture = try AIFixture([
      ["stop_reason": "tool_use", "content": [
        ["type": "tool_use", "id": "a", "name": "notes_stats", "input": [:]],
        ["type": "tool_use", "id": "b", "name": "notes_tags", "input": [:]]]],
      ["stop_reason": "end_turn", "content": [["type": "text", "text": "No notes."]]]])
    try await client(fixture).runWithTools(configuration: configuration, apiKey: "fixture-key", messages: messages,
      context: context, toolContext: NoteToolContext(entries: []), character: .companion, onEvent: { _ in })
    let requests = await fixture.recorded()
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
    XCTAssertNotNil(body["system"])
    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
    XCTAssertNotNil(tools.first?["input_schema"])
    let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(turns.last?["role"] as? String, "user")
    let results = try XCTUnwrap(turns.last?["content"] as? [[String: Any]])
    XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["a", "b"])
    XCTAssertTrue(results.allSatisfy { $0["type"] as? String == "tool_result" })
  }
  func testUnknownAndMalformedToolsReturnErrorsWithoutInventingSources() async throws {
    let fixture = try AIFixture([response([call("a", name: "write_file", arguments: "{}"), call("b", arguments: "broken")]), final])
    let events = AgentEvents()
    try await client(fixture).runWithTools(configuration: config, apiKey: "", messages: messages,
      context: context, toolContext: NoteToolContext(entries: []), character: .companion, onEvent: { await events.append($0) })
    let requests = await fixture.recorded()
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
    let results = try XCTUnwrap(body["messages"] as? [[String: Any]]).suffix(2)
    XCTAssertTrue(results.allSatisfy { ($0["content"] as? String)?.contains("error") == true })
    let recorded = await events.values()
    XCTAssertFalse(recorded.contains { if case .sources(let values) = $0 { return !values.isEmpty }; return false })
    XCTAssertFalse(recorded.contains(.toolStarted("write_file")))
  }
  func testDuplicateIDsAndTruncatedResponsesNeverExecuteAnAssetRead() async throws {
    let note = NotebookEntry(memo: Memo(attachments: [.init(file: "raw/assets/test.pdf", kind: "file")], body: "trip"), day: "2026-11-03")
    let args = String(data: try JSONSerialization.data(withJSONObject: ["card_ref": note.id, "attachment_index": 0]), encoding: .utf8)!
    for reply in [response([call("duplicate", name: "assets_read", arguments: args), call("duplicate")]),
                  response([call(name: "assets_read", arguments: args)], reason: "length")] {
      let fixture = try AIFixture([reply])
      do {
        try await client(fixture).runWithTools(configuration: config, apiKey: "", messages: messages,
          context: context, toolContext: NoteToolContext(entries: [note], attachmentReader: { _, _ in
            XCTFail("Invalid response must never execute an asset read"); return "private"
          }), character: .companion, onEvent: { _ in })
        XCTFail("Invalid tool response accepted")
      } catch { }
    }
  }
  func testRoundLimitAndRepeatedIDsAcrossRoundsStopWithoutFalseCompletion() async throws {
    for replies in [(0..<7).map { response([call("round-\($0)")]) }, [response([call()]), response([call()])]] {
      let fixture = try AIFixture(replies)
      let events = AgentEvents()
      do {
        try await client(fixture).runWithTools(configuration: config, apiKey: "", messages: messages,
          context: context, toolContext: NoteToolContext(entries: []), character: .companion,
          onEvent: { await events.append($0) })
        XCTFail("Unbounded or repeated loop accepted")
      } catch { }
      let requests = await fixture.recorded()
      XCTAssertLessThanOrEqual(requests.count, 6)
      let recorded = await events.values()
      XCTAssertFalse(recorded.contains(.stream(.finished)))
    }
  }
  func testBatchCallLimitRejectsWholeBatchBeforeExecutingAnyTool() async throws {
    let fixture = try AIFixture([response((0..<13).map { call("id-\($0)") })])
    let events = AgentEvents()
    do {
      try await client(fixture).runWithTools(configuration: config, apiKey: "", messages: messages,
        context: context, toolContext: NoteToolContext(entries: []), character: .companion,
        onEvent: { await events.append($0) })
      XCTFail("Oversized batch accepted")
    } catch { }
    let recorded = await events.values()
    XCTAssertTrue(recorded.isEmpty)
  }
  func testToolRoundsPreserveProviderReasoningWithoutMixingItIntoVisibleText() async throws {
    var configuration = AIProvider.kimi.configuration; configuration.model = "kimi-k3.1-pro"
    var reply = response([call()])
    var choices = try XCTUnwrap(reply["choices"] as? [[String: Any]])
    var assistant = try XCTUnwrap(choices[0]["message"] as? [String: Any])
    assistant["reasoning_content"] = "Provider-required private context"
    choices[0]["message"] = assistant; reply["choices"] = choices
    let fixture = try AIFixture([reply, final])
    let events = AgentEvents()
    try await client(fixture).runWithTools(configuration: configuration, apiKey: "fixture-key", messages: messages,
      context: context, toolContext: NoteToolContext(entries: []), character: .companion,
      onEvent: { await events.append($0) })
    let requests = await fixture.recorded()
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
    let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(turns.dropLast().last?["reasoning_content"] as? String, "Provider-required private context")
    let recorded = await events.values()
    XCTAssertFalse(recorded.contains(.stream(.text("Provider-required private context"))))
  }
  func testDirectOpenAICurrentModelUsesStatelessResponsesAndPreservesReasoningItems() async throws {
    var configuration = AIProvider.openAI.configuration; configuration.model = "gpt-6-astra"
    let fixture = try AIFixture([
      ["status": "completed", "output": [
        ["type": "reasoning", "id": "rs_1", "encrypted_content": "opaque-state", "summary": []],
        ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "notes_stats", "arguments": "{}"]]],
      ["status": "completed", "output": [
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "No notes."]]]]]])
    let events = AgentEvents()
    try await client(fixture).runWithTools(configuration: configuration, apiKey: "fixture-key", messages: messages,
      context: context, toolContext: NoteToolContext(entries: []), character: .companion,
      onEvent: { await events.append($0) })
    let requests = await fixture.recorded()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.url?.absoluteString == "https://api.openai.com/v1/responses" })
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertNil(body["previous_response_id"])
    XCTAssertTrue((body["instructions"] as? String)?.contains("untrusted") == true)
    XCTAssertTrue((body["include"] as? [String])?.contains("reasoning.encrypted_content") == true)
    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.first?["type"] as? String, "function")
    XCTAssertNotNil(tools.first?["name"])
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertTrue(input.contains { $0["encrypted_content"] as? String == "opaque-state" })
    XCTAssertTrue(input.contains { $0["type"] as? String == "function_call" && $0["call_id"] as? String == "call_1" })
    XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
    XCTAssertEqual(input.last?["call_id"] as? String, "call_1")
    let recorded = await events.values()
    XCTAssertEqual(recorded.suffix(2), [.stream(.text("No notes.")), .stream(.finished)])
    XCTAssertFalse(recorded.contains(.stream(.text("opaque-state"))))
  }
  func testIncompleteResponsesNeverExecuteToolsOrReportFinished() async throws {
    var configuration = AIProvider.openAI.configuration; configuration.model = "gpt-6.1-sol"
    let fixture = try AIFixture([["status": "incomplete", "output": [
      ["type": "function_call", "call_id": "a", "name": "notes_stats", "arguments": "{}"]]]])
    let events = AgentEvents()
    do {
      try await client(fixture).runWithTools(configuration: configuration, apiKey: "fixture-key", messages: messages,
        context: context, toolContext: NoteToolContext(entries: []), character: .companion,
        onEvent: { await events.append($0) })
      XCTFail("Incomplete response accepted")
    } catch { }
    let recorded = await events.values()
    XCTAssertTrue(recorded.isEmpty)
  }
  func testCancellationAfterResponseStopsBeforeToolExecution() async throws {
    let note = NotebookEntry(memo: Memo(attachments: [.init(file: "raw/assets/test.pdf", kind: "file")], body: "trip"), day: "2026-11-03")
    let args = String(data: try JSONSerialization.data(withJSONObject: ["card_ref": note.id, "attachment_index": 0]), encoding: .utf8)!
    let reply = try JSONSerialization.data(withJSONObject: response([call(name: "assets_read", arguments: args)]))
    let client = AIClient(transport: AITransport(load: { _, _ in
      withUnsafeCurrentTask { $0?.cancel() }; return reply
    }))
    do {
      try await client.runWithTools(configuration: config, apiKey: "", messages: messages,
        context: context, toolContext: NoteToolContext(entries: [note], attachmentReader: { _, _ in
          XCTFail("Cancelled calls cannot execute"); return "private"
        }), character: .companion, onEvent: { _ in })
      XCTFail("Cancellation ignored")
    } catch is CancellationError { }
  }
}
