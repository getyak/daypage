import Foundation

public enum SpeechProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, openAI, elevenLabs, openAICompatible
  public var id: String { rawValue }
  public var name: String {
    switch self {
    case .system: return "System speech"
    case .openAI: return "OpenAI"
    case .elevenLabs: return "ElevenLabs"
    case .openAICompatible: return "OpenAI-compatible"
    }
  }
  public var requiresAPIKey: Bool { self == .openAI || self == .elevenLabs }
  public var speedRange: ClosedRange<Double> {
    switch self {
    case .system: return 0.5...2
    case .elevenLabs: return 0.7...1.2
    case .openAI, .openAICompatible: return 0.25...4
    }
  }
}

/// Preferences contain connection metadata only. Credentials are device-only and scoped separately.
public struct SpeechChannel: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var provider: SpeechProvider
  public var baseURL: String
  public var model: String
  public var voice: String
  public var speed: Double
  public var allowsLocalHTTP: Bool
  public var usesAPIKey: Bool

  public init(id: String = UUID().uuidString, name: String = "", provider: SpeechProvider = .system,
    baseURL: String? = nil, model: String? = nil, voice: String? = nil, speed: Double = 1,
    allowsLocalHTTP: Bool = false, usesAPIKey: Bool = false) {
    self.id = id
    self.name = name.isEmpty ? provider.name : name
    self.provider = provider
    self.baseURL = baseURL ?? (provider == .elevenLabs ? "https://api.elevenlabs.io/v1" : provider == .openAI ? "https://api.openai.com/v1" : "")
    self.model = model ?? (provider == .elevenLabs ? "eleven_multilingual_v2" : provider == .openAI ? "gpt-4o-mini-tts" : "")
    self.voice = voice ?? (provider == .openAI ? "coral" : "")
    self.speed = speed
    self.allowsLocalHTTP = allowsLocalHTTP
    self.usesAPIKey = usesAPIKey
  }

  public static var system: SpeechChannel { SpeechChannel(id: "system", provider: .system) }
  public var requiresAuthentication: Bool { provider.requiresAPIKey || usesAPIKey }

  public var origin: String {
    get throws {
      guard provider != .system else { throw SpeechError.configuration }
      do { return try AIConfiguration(baseURL: baseURL, model: "speech").origin }
      catch { throw SpeechError.configuration }
    }
  }

  /// Distinct from chat keys, other channels, and other provider dialects at the same origin.
  public var credentialAccount: String {
    get throws {
      let parts = ["speech", provider.rawValue, id, try origin]
      return "speech:" + (try JSONEncoder().encode(parts)).base64EncodedString()
    }
  }

  public var endpoint: URL {
    get throws {
      guard provider != .system else { throw SpeechError.configuration }
      guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        model.count <= 200, voice.count <= 200 else { throw SpeechError.configuration }
      var components: URLComponents
      do {
        components = try AIConfiguration(baseURL: baseURL, model: "speech", allowsLocalHTTP: allowsLocalHTTP)
          .validatedComponents(checkTransport: true)
      } catch { throw SpeechError.configuration }
      let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path = "/" + (path.isEmpty ? "v1" : path)
      if provider == .elevenLabs {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard voice.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw SpeechError.configuration }
        components.path += "/text-to-speech/" + voice
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
      } else if !components.path.hasSuffix("/audio/speech") {
        components.path += "/audio/speech"
      }
      guard let url = components.url else { throw SpeechError.configuration }
      return url
    }
  }

  public func validated() throws -> SpeechChannel {
    guard !id.isEmpty, id.count <= 100,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
      speed.isFinite, provider.speedRange.contains(speed) else { throw SpeechError.configuration }
    if provider != .system { _ = try endpoint }
    return self
  }
}

public struct SpeechPreferences: Codable, Equatable, Sendable {
  public var channels: [SpeechChannel]
  public var selectedChannelID: String
  public init(channels: [SpeechChannel] = [.system], selectedChannelID: String = "system") {
    self.channels = channels
    self.selectedChannelID = selectedChannelID
  }
  public var selectedChannel: SpeechChannel? { channels.first { $0.id == selectedChannelID } }
  public func validated() throws -> SpeechPreferences {
    guard !channels.isEmpty, channels.count <= 20, selectedChannel != nil,
      Set(channels.map(\.id)).count == channels.count else { throw SpeechError.configuration }
    for channel in channels { _ = try channel.validated() }
    return self
  }
}

public struct SpeechPreferencesStore {
  public static let key = "local.speech.channels.v1"
  private let defaults: UserDefaults
  public init(defaults: UserDefaults) { self.defaults = defaults }
  public func load() -> SpeechPreferences {
    (try? loadValidated()) ?? SpeechPreferences()
  }
  public func loadValidated() throws -> SpeechPreferences {
    guard let data = defaults.data(forKey: Self.key) else { return SpeechPreferences() }
    guard data.count <= 128 * 1024,
      let value = try? JSONDecoder().decode(SpeechPreferences.self, from: data) else { throw SpeechError.configuration }
    return try value.validated()
  }
  public func save(_ preferences: SpeechPreferences) throws {
    let validated = try preferences.validated()
    defaults.set(try JSONEncoder().encode(validated), forKey: Self.key)
  }
}

public enum SpeechSecretStore {
  public typealias Loader = (String) throws -> String
  public typealias Writer = (String, String) throws -> Void

  public static func read(channel: SpeechChannel,
    loader: Loader = { try KeychainSecretStore.read(origin: $0) }) throws -> String {
    guard channel.requiresAuthentication else { return "" }
    let account = try channel.credentialAccount
    do { return try loader(account) }
    catch { throw SpeechError.keychain }
  }
  public static func save(_ value: String, channel: SpeechChannel,
    writer: Writer = { try KeychainSecretStore.save($0, origin: $1) }) throws {
    guard channel.requiresAuthentication else { return }
    let account = try channel.credentialAccount
    do { try writer(value, account) }
    catch { throw SpeechError.keychain }
  }
  /// Explicit cleanup is separate from saving an anonymous channel, which leaves old keys inert.
  public static func remove(channel: SpeechChannel,
    writer: Writer = { try KeychainSecretStore.save($0, origin: $1) }) throws {
    guard channel.provider != .system else { return }
    let account = try channel.credentialAccount
    do { try writer("", account) }
    catch { throw SpeechError.keychain }
  }
}

public enum SpeechError: Error, LocalizedError, Equatable, Sendable {
  case configuration, unauthorized, rateLimited, invalidAudio, tooLarge, inputTooLong, emptyInput
  case keychain, network, playback, microphoneInUse
  case rejected(Int)
  public var errorDescription: String? {
    switch self {
    case .configuration: return "Check the speech address, model, voice and speed. Local HTTP needs explicit permission."
    case .unauthorized: return "The speech service rejected this key. Check this channel’s key in Settings."
    case .rateLimited: return "The speech service is busy. Try again later."
    case .invalidAudio: return "The speech service returned unreadable audio. Check the channel and try again."
    case .tooLarge: return "The speech audio exceeded the size limit. Try a shorter passage."
    case .inputTooLong: return "Read aloud supports up to 4,096 characters at a time. Choose a shorter passage."
    case .emptyInput: return "There is no text to read aloud."
    case .keychain: return "Could not access this channel’s saved key. Unlock your device and retry. Your typed input is kept."
    case .network: return "Could not reach the speech service. Check the connection and try again."
    case .playback: return "This audio could not be played. Check the channel and try again."
    case .microphoneInUse: return "Finish the recording before reading aloud."
    case .rejected: return "The speech service could not complete this request. Check the channel and try again."
    }
  }
}
