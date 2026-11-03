import Foundation

struct SpeechHTTPResponse: Sendable {
  let data: Data
  let statusCode: Int
  let mimeType: String?
}

/// A short-lived session with bounded streamed bytes and no cross-origin redirect handling.
public struct SpeechTransport: Sendable {
  typealias Loader = @Sendable (URLRequest, Int) async throws -> SpeechHTTPResponse
  private let load: Loader
  public init() { load = Self.fetch }
  init(load: @escaping Loader) { self.load = load }
  public func data(for request: URLRequest, maximumBytes: Int = 12 * 1024 * 1024) async throws -> Data {
    try Task.checkCancellation()
    let response: SpeechHTTPResponse
    do { response = try await load(request, maximumBytes) }
    catch is CancellationError { throw CancellationError() }
    catch let error as SpeechError { throw error }
    catch {
      try Task.checkCancellation()
      throw SpeechError.network
    }
    try Task.checkCancellation()
    try Self.validateStatus(response.statusCode)
    guard response.data.count <= maximumBytes else { throw SpeechError.tooLarge }
    let mime = response.mimeType?.lowercased().split(separator: ";").first.map(String.init)
    guard ["audio/mpeg", "audio/mp3", "application/octet-stream"].contains(mime ?? ""),
      SpeechAudio.isMP3(response.data) else { throw SpeechError.invalidAudio }
    return response.data
  }
  private static func validateStatus(_ status: Int) throws {
    switch status {
    case 200...299: break
    case 401, 403: throw SpeechError.unauthorized
    case 429: throw SpeechError.rateLimited
    default: throw SpeechError.rejected(status)
    }
  }
  private static func fetch(_ request: URLRequest, maximumBytes: Int) async throws -> SpeechHTTPResponse {
    let settings = URLSessionConfiguration.ephemeral
    settings.httpCookieStorage = nil
    settings.urlCredentialStorage = nil
    settings.httpShouldSetCookies = false
    settings.urlCache = nil
    settings.timeoutIntervalForRequest = 60
    settings.timeoutIntervalForResource = 90
    let session = URLSession(configuration: settings, delegate: RejectSpeechRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw SpeechError.invalidAudio }
    try validateStatus(http.statusCode)
    guard response.expectedContentLength <= Int64(maximumBytes) else { throw SpeechError.tooLarge }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else { throw SpeechError.tooLarge }
      data.append(byte)
    }
    return SpeechHTTPResponse(data: data, statusCode: http.statusCode, mimeType: response.mimeType)
  }
}

private final class RejectSpeechRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum SpeechAudio {
  /// Check complete consecutive Layer III frames, including an optional bounded ID3v2 tag.
  /// AVAudioPlayer performs the final decode check before playback starts.
  public static func isMP3(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    var offset = 0
    if bytes.starts(with: [0x49, 0x44, 0x33]) {
      guard bytes.count >= 10, bytes[6...9].allSatisfy({ $0 < 128 }) else { return false }
      let size = bytes[6...9].reduce(0) { ($0 << 7) | Int($1) }
      offset = 10 + size + (bytes[5] & 0x10 == 0 ? 0 : 10)
      guard offset < bytes.count else { return false }
    }
    var frames = 0
    while offset + 4 <= bytes.count {
      let a = bytes[offset], b = bytes[offset + 1], c = bytes[offset + 2]
      guard a == 0xff, b & 0xe0 == 0xe0 else { break }
      let version = (b >> 3) & 3, layer = (b >> 1) & 3
      let bitrateIndex = Int(c >> 4), sampleIndex = Int((c >> 2) & 3)
      guard version != 1, layer == 1, (1...14).contains(bitrateIndex), sampleIndex < 3 else { return false }
      let rates = version == 3 ? [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320] : [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160]
      let sample = [44100,48000,32000][sampleIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
      let length = (version == 3 ? 144000 : 72000) * rates[bitrateIndex] / sample + Int((c >> 1) & 1)
      guard length >= 4, offset + length <= bytes.count else { return false }
      frames += 1
      offset += length
      if frames >= 2 { return true }
    }
    return false
  }
}
