import Foundation

public struct AIConfiguration: Codable, Equatable, Sendable {
  public var baseURL: String
  public var model: String
  public var allowsLocalHTTP: Bool
  public var usesAPIKey: Bool
  public init(
    baseURL: String = "", model: String = "", allowsLocalHTTP: Bool = false,
    usesAPIKey: Bool = false
  ) {
    self.baseURL = baseURL
    self.model = model
    self.allowsLocalHTTP = allowsLocalHTTP
    self.usesAPIKey = usesAPIKey
  }
  private enum CodingKeys: String, CodingKey { case baseURL, model, allowsLocalHTTP, usesAPIKey }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    baseURL = try container.decode(String.self, forKey: .baseURL)
    model = try container.decode(String.self, forKey: .model)
    allowsLocalHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowsLocalHTTP) ?? false
    usesAPIKey = try container.decodeIfPresent(Bool.self, forKey: .usesAPIKey) ?? false
  }
  public var endpoint: URL {
    get throws {
      guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIError.configuration
      }
      var components = try validatedComponents(checkTransport: true)
      let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path = "/" + (path.isEmpty ? "v1" : path)
      if !components.path.hasSuffix("/chat/completions") { components.path += "/chat/completions" }
      guard let url = components.url else { throw AIError.configuration }
      return url
    }
  }
  public var origin: String {
    get throws {
      var components = try validatedComponents(checkTransport: false)
      components.path = ""
      if (components.scheme == "https" && components.port == 443)
        || (components.scheme == "http" && components.port == 80)
      {
        components.port = nil
      }
      guard let value = components.string else { throw AIError.configuration }
      return value
    }
  }
  private func validatedComponents(checkTransport: Bool) throws -> URLComponents {
    guard var c = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      let rawHost = c.host, !rawHost.isEmpty, c.user == nil, c.password == nil,
      c.query == nil, c.fragment == nil
    else { throw AIError.configuration }
    let host = rawHost.lowercased()
    c.host = host
    c.scheme = c.scheme?.lowercased()
    guard c.scheme == "https" || c.scheme == "http" else { throw AIError.configuration }
    if checkTransport, c.scheme == "http", !(allowsLocalHTTP && Self.isLocalHost(host)) {
      throw AIError.configuration
    }
    return c
  }
  private static func isLocalHost(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") {
      return true
    }
    let segments = host.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 4,
      segments.allSatisfy({
        !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
          && ($0.count == 1 || $0.first != "0")
      })
    else { return false }
    let pieces = segments.compactMap { Int($0) }
    guard pieces.count == 4, pieces.allSatisfy({ (0...255).contains($0) }) else { return false }
    return pieces[0] == 127 || pieces[0] == 10 || (pieces[0] == 192 && pieces[1] == 168)
      || (pieces[0] == 172 && (16...31).contains(pieces[1]))
  }
}

public enum AIError: LocalizedError {
  case configuration, unauthorized, rateLimited
  case rejected(Int)
  case invalidResponse, tooLarge
  public var errorDescription: String? {
    switch self {
    case .configuration:
      return "Enter a valid AI address and model. Local HTTP requires explicit permission."
    case .unauthorized:
      return "The AI service rejected this key. Check the key for this service in Settings."
    case .rateLimited:
      return "The AI service is busy. Your question has been kept; try again later."
    case .rejected(let code):
      return "The AI service returned HTTP \(code). Your notes have not changed."
    case .invalidResponse: return "The AI service returned an unreadable response."
    case .tooLarge: return "The AI response exceeded the size limit."
    }
  }
}
