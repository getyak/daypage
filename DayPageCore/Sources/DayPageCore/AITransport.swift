import Foundation

/// Shared bounded, ephemeral transport for completion and model metadata.
struct AITransport: Sendable {
  typealias Loader = @Sendable (URLRequest, Int) async throws -> Data
  private let load: Loader
  init() { load = { request, maximumBytes in try await Self.fetch(request, maximumBytes: maximumBytes) } }
  init(load: @escaping Loader) { self.load = load }
  func data(for request: URLRequest, maximumBytes: Int = 2 * 1024 * 1024) async throws -> Data {
    try Task.checkCancellation()
    let data = try await load(request, maximumBytes)
    guard data.count <= maximumBytes else { throw AIError.tooLarge }
    return data
  }
  static func key(_ raw: String, configuration: AIConfiguration) throws -> String {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.contains("\n"), !key.contains("\r"), key.count <= 10000 else { throw AIError.configuration }
    if (configuration.usesAPIKey || AIProvider.matching(configuration: configuration).requiresAPIKey), key.isEmpty {
      throw AIError.unauthorized
    }
    return key
  }
  static func authorize(_ request: inout URLRequest, configuration: AIConfiguration, apiKey: String) throws {
    let key = try key(apiKey, configuration: configuration)
    if AIProvider.matching(configuration: configuration) == .anthropic {
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    } else if !key.isEmpty {
      request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }
  private static func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
    let settings = URLSessionConfiguration.ephemeral
    settings.httpCookieStorage = nil
    settings.urlCredentialStorage = nil
    settings.httpShouldSetCookies = false
    settings.urlCache = nil
    settings.timeoutIntervalForRequest = 60
    settings.timeoutIntervalForResource = 90
    let session = URLSession(configuration: settings, delegate: RejectAIRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
    switch http.statusCode {
    case 200...299: break
    case 401, 403: throw AIError.unauthorized
    case 429: throw AIError.rateLimited
    default: throw AIError.rejected(http.statusCode)
    }
    guard response.expectedContentLength <= Int64(maximumBytes) else { throw AIError.tooLarge }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else { throw AIError.tooLarge }
      data.append(byte)
    }
    return data
  }
}

private final class RejectAIRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
