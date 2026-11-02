import XCTest
@testable import DayPageCore

final class AIStreamingTests: XCTestCase {
  func testJSONFallbackRejectsPartialAndFilteredReplies() throws {
    let partial = Data(#"{"type":"message","stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#.utf8)
    XCTAssertThrowsError(try AIJSONReply.events(data: partial, provider: .anthropic))
    let filtered = Data(#"{"choices":[{"finish_reason":"content_filter","message":{"content":"partial"}}]}"#.utf8)
    XCTAssertThrowsError(try AIJSONReply.events(data: filtered, provider: .openAI))
    let full = Data(#"{"type":"message","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"Brief summary"},{"type":"text","text":"Complete"}]}"#.utf8)
    XCTAssertEqual(try AIJSONReply.events(data: full, provider: .anthropic), [.reasoning("Brief summary"), .text("Complete"), .finished])
  }
  func testOpenAITextAndReasoningRemainSeparateAndRequireTerminalEvent() throws {
    var parser = AIStreamDecoder()
    XCTAssertEqual(try parser.consume(line: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"A short summary\"}}]}"), [])
    XCTAssertEqual(try parser.consume(line: ""), [.reasoning("A short summary")])
    _ = try parser.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"你好 **world**\"}}]}")
    XCTAssertEqual(try parser.consume(line: ""), [.text("你好 **world**")])
    XCTAssertThrowsError(try parser.validateEnd())
    _ = try parser.consume(line: "data: [DONE]")
    XCTAssertEqual(try parser.consume(line: ""), [.finished])
    XCTAssertNoThrow(try parser.validateEnd())
  }
  func testAnthropicDeltaAndStreamError() throws {
    var parser = AIStreamDecoder()
    _ = try parser.consume(line: "event: content_block_delta")
    _ = try parser.consume(line: "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}")
    XCTAssertEqual(try parser.consume(line: ""), [.text("Hello")])
    _ = try parser.consume(line: "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}")
    XCTAssertThrowsError(try parser.consume(line: ""))
  }
  func testMalformedAndTokenLimitEventsDoNotBecomeSuccessfulReplies() throws {
    var malformed = AIStreamDecoder()
    _ = try malformed.consume(line: "data: {broken}")
    XCTAssertThrowsError(try malformed.consume(line: ""))
    var limited = AIStreamDecoder()
    _ = try limited.consume(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}")
    XCTAssertThrowsError(try limited.consume(line: ""))
  }
  func testStreamRequestKeepsCharacterAndProviderProtocol() throws {
    let character = ChatCharacter(name: "Moss", role: "Editor", soul: "Be concise")
    let config = AIConfiguration(baseURL: "https://example.com/v1", model: "model")
    let request = try AIClient().makeRequest(configuration: config, apiKey: "", messages: [.init(role: .user, content: "Hi")], context: .build(entries: [], question: ""), character: character, streaming: true)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    let system = try XCTUnwrap((body["messages"] as? [[String: String]])?.first?["content"])
    XCTAssertTrue(system.contains("Be concise"))
    XCTAssertTrue(system.contains("untrusted"))
    XCTAssertNil(body["tools"])
  }
}
