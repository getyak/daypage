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
    let key: String
    if channel.requiresAuthentication {
      key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      // CRLF is one Swift Character; inspect scalars to reject every header control character.
      guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        key.utf8.count <= 10000 else { throw SpeechError.configuration }
      guard !key.isEmpty else { throw SpeechError.unauthorized }
    } else {
      // A previously saved key is inert while authentication is off, even if it is malformed.
      key = ""
    }
    if channel.requiresAuthentication {
      if channel.provider == .elevenLabs { request.setValue(key, forHTTPHeaderField: "xi-api-key") }
      else { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
    }
    var body: [String: Any]
    if channel.provider == .elevenLabs {
      body = ["text": text, "model_id": channel.model, "voice_settings": ["speed": channel.speed]]
    } else {
      body = ["model": channel.model, "input": text, "voice": channel.voice, "response_format": "mp3", "speed": channel.speed]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }
}
