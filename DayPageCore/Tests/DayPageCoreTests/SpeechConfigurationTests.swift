import XCTest
@testable import DayPageCore

final class SpeechConfigurationTests: XCTestCase {
  func testNewPreferencesHaveUsableSystemChannelWithoutRemoteCredentials() throws {
    let preferences = SpeechPreferences()
    XCTAssertEqual(preferences.selectedChannel?.provider, .system)
    XCTAssertEqual(preferences.selectedChannel?.id, "system")
    XCTAssertNoThrow(try preferences.validated())
  }

  func testMultipleNamedChannelsAndSelectionRoundTripWithoutSecrets() throws {
    let name = "GET-369-speech-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SpeechPreferencesStore(defaults: defaults)
    let first = SpeechChannel(id: "a", name: "Reading", provider: .openAI)
    let second = SpeechChannel(id: "b", name: "My server", provider: .openAICompatible,
      baseURL: "https://voice.example/v1", model: "my-model", voice: "voice-b", speed: 1.2)
    let preferences = SpeechPreferences(channels: [.system, first, second], selectedChannelID: second.id)
    try store.save(preferences)
    XCTAssertEqual(store.load(), preferences)
    let encoded = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
    XCTAssertFalse(encoded.contains("apiKey"))
    XCTAssertFalse(encoded.contains("secret"))
    XCTAssertEqual(store.load().selectedChannel?.name, "My server")
  }

  func testInvalidSelectionsDuplicatesAndInvalidSpeedCannotBeSaved() throws {
    XCTAssertThrowsError(try SpeechPreferences(channels: [.system], selectedChannelID: "missing").validated())
    XCTAssertThrowsError(try SpeechPreferences(channels: [.system, .system], selectedChannelID: "system").validated())
    var channel = SpeechChannel(provider: .openAI)
    channel.speed = .nan
    XCTAssertThrowsError(try channel.validated())
    channel.speed = 5
    XCTAssertThrowsError(try channel.validated())
  }

  func testCorruptSavedPreferencesFailPlaybackValidationInsteadOfChoosingSystem() throws {
    let name = "GET-369-speech-corrupt-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = SpeechPreferencesStore(defaults: defaults)
    defaults.set(Data("not configuration".utf8), forKey: SpeechPreferencesStore.key)
    XCTAssertThrowsError(try store.loadValidated())
    let invalid = SpeechPreferences(channels: [.system], selectedChannelID: "deleted-remote")
    defaults.set(try JSONEncoder().encode(invalid), forKey: SpeechPreferencesStore.key)
    XCTAssertThrowsError(try store.loadValidated())
    defaults.removeObject(forKey: SpeechPreferencesStore.key)
    XCTAssertEqual(try store.loadValidated().selectedChannel?.provider, .system)
  }

  func testRemoteEndpointPolicyAndCanonicalOrigin() throws {
    var channel = SpeechChannel(provider: .openAICompatible, baseURL: "http://192.168.1.20:8000/v1", model: "tts", voice: "v")
    XCTAssertThrowsError(try channel.endpoint)
    channel.allowsLocalHTTP = true
    XCTAssertEqual(try channel.endpoint.absoluteString, "http://192.168.1.20:8000/v1/audio/speech")
    for address in ["http://example.com/v1", "http://10.0.0.1.attacker.example/v1", "https://user:key@example.com/v1", "https://example.com/v1?key=x", "https://example.com/v1#fragment"] {
      channel.baseURL = address
      XCTAssertThrowsError(try channel.endpoint, address)
    }
    channel.baseURL = "https://EXAMPLE.com:443/v1/"
    XCTAssertEqual(try channel.origin, "https://example.com")
  }

  func testCredentialScopeIsSeparateFromAIAndChangesForOriginChannelOrProvider() throws {
    var a = SpeechChannel(id: "channel-a", provider: .openAI)
    let original = try a.credentialAccount
    XCTAssertNotEqual(original, try AIConfiguration(baseURL: a.baseURL, model: "x").origin)
    a.model = "another-model"; a.voice = "another-voice"
    XCTAssertEqual(original, try a.credentialAccount)
    a.id = "channel-b"
    XCTAssertNotEqual(original, try a.credentialAccount)
    a.id = "channel-a"; a.provider = .openAICompatible
    XCTAssertNotEqual(original, try a.credentialAccount)
    a.provider = .openAI; a.baseURL = "https://other.example/v1"
    XCTAssertNotEqual(original, try a.credentialAccount)
  }

  func testAnonymousChannelDoesNotReadOrWriteAnUnavailableKeychain() throws {
    let channel = SpeechChannel(provider: .openAICompatible, baseURL: "https://voice.example/v1", model: "tts", voice: "sample")
    var readCalls = 0
    var writeCalls = 0
    let value = try SpeechSecretStore.read(channel: channel, loader: { _ in
      readCalls += 1
      throw SpeechError.keychain
    })
    try SpeechSecretStore.save("inert-old-key", channel: channel, writer: { _, _ in
      writeCalls += 1
      throw SpeechError.keychain
    })
    XCTAssertEqual(value, "")
    XCTAssertEqual(readCalls, 0)
    XCTAssertEqual(writeCalls, 0)
    XCTAssertFalse(channel.requiresAuthentication)
  }

  func testDisablingAuthenticationKeepsTheSavedKeyInertUntilReenabledOrExplicitlyRemoved() throws {
    var channel = SpeechChannel(provider: .openAICompatible, baseURL: "https://voice.example/v1", model: "tts", voice: "sample", usesAPIKey: true)
    var stored = ""
    try SpeechSecretStore.save("saved-fixture", channel: channel, writer: { value, _ in stored = value })
    channel.usesAPIKey = false
    try SpeechSecretStore.save("", channel: channel, writer: { value, _ in stored = value })
    XCTAssertEqual(try SpeechSecretStore.read(channel: channel, loader: { _ in stored }), "")
    XCTAssertEqual(stored, "saved-fixture", "Turning authentication off must not overwrite or delete the saved key")
    channel.usesAPIKey = true
    XCTAssertEqual(try SpeechSecretStore.read(channel: channel, loader: { _ in stored }), "saved-fixture")
    channel.usesAPIKey = false
    try SpeechSecretStore.remove(channel: channel, writer: { value, _ in stored = value })
    XCTAssertEqual(stored, "", "Explicit deletion can remove a stored key even while authentication is off")
  }

  func testRequiredAuthenticationUsesTheScopedKeychainAndReportsFailures() throws {
    for provider in [SpeechProvider.openAI, .elevenLabs] {
      let channel = SpeechChannel(provider: provider, voice: "voice")
      XCTAssertTrue(channel.requiresAuthentication)
      var scope: String?
      XCTAssertEqual(try SpeechSecretStore.read(channel: channel, loader: { account in
        scope = account
        return "fixture-key"
      }), "fixture-key")
      XCTAssertTrue(scope?.hasPrefix("speech:") == true)
      XCTAssertThrowsError(try SpeechSecretStore.read(channel: channel, loader: { _ in throw SpeechError.network })) {
        XCTAssertEqual($0 as? SpeechError, .keychain)
      }
      XCTAssertThrowsError(try SpeechSecretStore.save("key", channel: channel, writer: { _, _ in throw SpeechError.network })) {
        XCTAssertEqual($0 as? SpeechError, .keychain)
      }
    }
  }
}
