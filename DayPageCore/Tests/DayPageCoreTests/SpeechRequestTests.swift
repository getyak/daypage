import XCTest
@testable import DayPageCore

final class SpeechRequestTests: XCTestCase {
  func testOpenAIRequestUsesMP3AndOnlyExplicitText() throws {
    let channel = SpeechChannel(provider: .openAI, model: "gpt-4o-mini-tts", voice: "coral", speed: 1.25)
    let request = try SpeechRequest.make(channel: channel, text: "Read only this.", apiKey: " speech-key ")
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer speech-key")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["input"] as? String, "Read only this.")
    XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
    XCTAssertEqual(body["voice"] as? String, "coral")
    XCTAssertEqual(body["response_format"] as? String, "mp3")
    XCTAssertEqual(body["speed"] as? Double, 1.25)
    XCTAssertEqual(Set(body.keys), Set(["model", "voice", "input", "response_format", "speed"]))
  }

  func testElevenLabsHasItsOwnHeaderVoicePathAndSpeed() throws {
    let channel = SpeechChannel(provider: .elevenLabs, voice: "voice_123", speed: 0.9)
    let request = try SpeechRequest.make(channel: channel, text: "Sample.", apiKey: "eleven-key")
    XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/voice_123?output_format=mp3_44100_128")
    XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "eleven-key")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["text"] as? String, "Sample.")
    XCTAssertEqual(body["model_id"] as? String, "eleven_multilingual_v2")
    XCTAssertEqual((body["voice_settings"] as? [String: Double])?["speed"], 0.9)
    XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "enable_logging" }))
  }

  func testCustomCompatibleEndpointCanExplicitlyOmitKey() throws {
    let channel = SpeechChannel(provider: .openAICompatible, baseURL: "http://localhost:8880/v1", model: "kokoro", voice: "af_heart", allowsLocalHTTP: true)
    let request = try SpeechRequest.make(channel: channel, text: "Sample.", apiKey: "")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(request.url?.absoluteString, "http://localhost:8880/v1/audio/speech")
  }

  func testAnonymousRequestNeverSendsOrValidatesAnInertSavedKey() throws {
    let channel = SpeechChannel(provider: .openAICompatible, baseURL: "https://voice.example/v1", model: "tts", voice: "sample")
    for oldKey in ["stale-saved-key", "stale\r\nkey"] {
      let request = try SpeechRequest.make(channel: channel, text: "Sample.", apiKey: oldKey)
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(request.value(forHTTPHeaderField: "xi-api-key"))
    }
  }

  func testCompatibleChannelAuthenticatesOnlyAfterExplicitlyEnablingAPIKey() throws {
    let channel = SpeechChannel(provider: .openAICompatible, baseURL: "https://voice.example/v1", model: "tts", voice: "sample", usesAPIKey: true)
    XCTAssertThrowsError(try SpeechRequest.make(channel: channel, text: "Sample.", apiKey: ""))
    let request = try SpeechRequest.make(channel: channel, text: "Sample.", apiKey: "chosen-fixture-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer chosen-fixture-key")
  }

  func testRejectsAbsentKeyInjectedHeaderEmptyOrOversizedInputAndSystemRequests() {
    let channel = SpeechChannel(provider: .openAI)
    XCTAssertThrowsError(try SpeechRequest.make(channel: channel, text: "Sample", apiKey: ""))
    XCTAssertThrowsError(try SpeechRequest.make(channel: channel, text: "Sample", apiKey: "key\r\nInjected: yes"))
    XCTAssertThrowsError(try SpeechRequest.make(channel: channel, text: " \n", apiKey: "key"))
    XCTAssertThrowsError(try SpeechRequest.make(channel: channel, text: String(repeating: "a", count: 4097), apiKey: "key"))
    XCTAssertThrowsError(try SpeechRequest.make(channel: .system, text: "Sample", apiKey: ""))
    var eleven = SpeechChannel(provider: .elevenLabs, voice: "bad/voice")
    XCTAssertThrowsError(try eleven.endpoint)
    eleven.voice = "ok"; eleven.speed = 2
    XCTAssertThrowsError(try eleven.validated())
  }
}
