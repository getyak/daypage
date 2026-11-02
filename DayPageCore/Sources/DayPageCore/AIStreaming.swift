import Foundation

public enum AIStreamEvent: Equatable, Sendable {
  case text(String), reasoning(String), finished
}

enum AIJSONReply {
  static func events(data: Data, provider: AIProvider) throws -> [AIStreamEvent] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil else {
      throw AIError.invalidResponse
    }
    var events: [AIStreamEvent] = []
    let text: String?
    if provider == .anthropic {
      guard let reason = object["stop_reason"] as? String, ["end_turn", "stop_sequence"].contains(reason) else {
        throw AIError.invalidResponse
      }
      let blocks = object["content"] as? [[String: Any]] ?? []
      for block in blocks where block["type"] as? String == "thinking" {
        if let summary = block["thinking"] as? String { events.append(.reasoning(summary)) }
      }
      text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    } else {
      let choice = (object["choices"] as? [[String: Any]])?.first
      // Older local servers omit finish_reason. An explicit unsuccessful reason is never success.
      if let reason = choice?["finish_reason"] as? String, reason != "stop" { throw AIError.invalidResponse }
      let message = choice?["message"] as? [String: Any]
      text = message?["content"] as? String
      if let reasoning = (message?["reasoning_content"] ?? message?["reasoning"]) as? String {
        events.append(.reasoning(reasoning))
      }
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
    return events + [.text(text), .finished]
  }
}

/// SSE events are delimited by blank lines, not TCP chunks or individual data lines.
struct AIStreamDecoder {
  private var data: [String] = []
  private var finished = false
  mutating func consume(line: String) throws -> [AIStreamEvent] {
    if line.hasPrefix("data:") {
      var value = String(line.dropFirst(5))
      if value.first == " " { value.removeFirst() }
      data.append(value)
      return []
    }
    guard line.isEmpty, !data.isEmpty else { return [] }
    let value = data.joined(separator: "\n")
    data = []
    if value == "[DONE]" { finished = true; return [.finished] }
    guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
    else { throw AIError.invalidResponse }
    if object["error"] != nil || object["type"] as? String == "error" { throw AIError.invalidResponse }
    var events: [AIStreamEvent] = []
    if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
      if let delta = choice["delta"] as? [String: Any] {
        if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
        if let text = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !text.isEmpty {
          events.append(.reasoning(text))
        }
      }
      if let reason = choice["finish_reason"] as? String {
        guard reason == "stop" else { throw AIError.invalidResponse }
        finished = true; events.append(.finished)
      }
    }
    // Anthropic native Messages events (including provider-supplied thinking).
    if let delta = object["delta"] as? [String: Any] {
      if let text = delta["text"] as? String { events.append(.text(text)) }
      if let text = delta["thinking"] as? String { events.append(.reasoning(text)) }
      if let reason = delta["stop_reason"] as? String, reason != "end_turn" && reason != "stop_sequence" {
        throw AIError.invalidResponse
      }
    }
    if object["type"] as? String == "message_stop" { finished = true; events.append(.finished) }
    return events
  }
  func validateEnd() throws {
    guard finished, data.isEmpty else { throw AIError.invalidResponse }
  }
}

extension AIClient {
  /// The consumer awaits each event, allowing UI updates and periodic durable checkpoints.
  public func stream(configuration: AIConfiguration, apiKey: String, messages: [ChatMessage],
    context: NoteContext, character: ChatCharacter,
    onEvent: @escaping @Sendable (AIStreamEvent) async throws -> Void) async throws {
    let resolved = try await AIModelCatalog().resolve(configuration: configuration, apiKey: apiKey)
    let request = try makeRequest(configuration: resolved, apiKey: apiKey, messages: messages,
      context: context, character: character, streaming: true)
    let settings = URLSessionConfiguration.ephemeral
    settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
    settings.httpShouldSetCookies = false; settings.urlCache = nil
    settings.timeoutIntervalForRequest = 60; settings.timeoutIntervalForResource = 90
    let session = URLSession(configuration: settings, delegate: RejectAIStreamRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
    switch http.statusCode {
    case 200...299: break
    case 401, 403: throw AIError.unauthorized
    case 429: throw AIError.rateLimited
    default: throw AIError.rejected(http.statusCode)
    }
    let limit = 2 * 1024 * 1024
    guard response.expectedContentLength <= Int64(limit) else { throw AIError.tooLarge }
    let isSSE = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
    var count = 0
    var buffer = Data()
    var decoder = AIStreamDecoder()
    if isSSE {
      for try await byte in bytes {
        try Task.checkCancellation()
        count += 1
        guard count <= limit, buffer.count < 128 * 1024 else { throw AIError.tooLarge }
        if byte == 10 {
          if buffer.last == 13 { buffer.removeLast() }
          guard let line = String(data: buffer, encoding: .utf8) else { throw AIError.invalidResponse }
          buffer.removeAll(keepingCapacity: true)
          for event in try decoder.consume(line: line) { try await onEvent(event) }
        } else { buffer.append(byte) }
      }
      // EOF may terminate the final event without a trailing blank line.
      if !buffer.isEmpty {
        if buffer.last == 13 { buffer.removeLast() }
        guard let line = String(data: buffer, encoding: .utf8) else { throw AIError.invalidResponse }
        _ = try decoder.consume(line: line)
      }
      for event in try decoder.consume(line: "") { try await onEvent(event) }
      try decoder.validateEnd()
    } else {
      // Some local OpenAI-compatible servers ignore stream=true and reply with JSON.
      for try await byte in bytes {
        try Task.checkCancellation()
        guard buffer.count < limit else { throw AIError.tooLarge }
        buffer.append(byte)
      }
      for event in try AIJSONReply.events(data: buffer, provider: AIProvider.matching(configuration: resolved)) {
        try await onEvent(event)
      }
    }
  }
}

private final class RejectAIStreamRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
