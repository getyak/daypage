import Foundation

public enum SpeechRequest {
  public static let maximumCharacters = 4096
  public static func validateText(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechError.emptyInput }
    guard text.count <= maximumCharacters, text.utf8.count <= 32 * 1024 else { throw SpeechError.inputTooLong }
  }
  public static func make(channel: SpeechChannel, text: String, apiKey: String) throws -> URLRequest {
    _ = try channel.validated()
    try validateText(text)
    var request = URLRequest(url: try channel.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    // CRLF is a single Swift Character, so searching for standalone Character newlines misses it.
    guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      key.utf8.count <= 10000 else { throw SpeechError.configuration }
    guard !(channel.provider.requiresAPIKey || channel.usesAPIKey) || !key.isEmpty else { throw SpeechError.unauthorized }
    var body: [String: Any]
    if channel.provider == .elevenLabs {
      request.setValue(key, forHTTPHeaderField: "xi-api-key")
      body = ["text": text, "model_id": channel.model, "voice_settings": ["speed": channel.speed]]
    } else {
      if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
      body = ["model": channel.model, "input": text, "voice": channel.voice, "response_format": "mp3", "speed": channel.speed]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }
}
