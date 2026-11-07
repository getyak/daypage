import Foundation

// The only fake is the network boundary. Parsing, session policy, streaming,
// cancellation and redirect delegate are the production implementation.
final class InformationProtocol: URLProtocol {
  static let lock = NSLock()
  static var handler: ((InformationProtocol) -> Void)?
  static var requests: [URLRequest] = []
  static var stopped = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    let action = Self.handler
    Self.lock.unlock()
    action?(self)
  }
  override func stopLoading() {
    Self.lock.lock(); Self.stopped = true; Self.lock.unlock()
  }
  func respond(_ status: Int = 200, mime: String = "application/json", body: Data) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  static func prepare(_ action: @escaping (InformationProtocol) -> Void) {
    lock.lock(); defer { lock.unlock() }
    handler = action; requests = []; stopped = false
  }
  static func snapshot() -> ([URLRequest], Bool) {
    lock.lock(); defer { lock.unlock() }; return (requests, stopped)
  }
}

@main struct InformationTests {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "InformationTests", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: message]) }
  }
  static func reject(_ operation: () async throws -> Void) async throws {
    do { try await operation() } catch { return }
    try require(false, "Expected invalid/failed public information to be rejected")
  }
  static func payload(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    let text: [String: Any] = ["about": [["title": "DayPage", "paragraphs": ["Local notebook"]]],
                              "privacy": [["title": "Privacy", "paragraphs": ["No notes sent"]]],
                              "support": [["title": "Help", "paragraphs": ["Use Feedback"]]]]
    var object: [String: Any] = ["schemaVersion": 1, "appID": "com.daypage.app",
                                "revisionDate": "2026-11-07", "languages": ["en": text, "zh-Hans": text]]
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }
  static func service() -> AppInformationService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InformationProtocol.self]
    // Deliberately dirty injection verifies the client strips unrelated state.
    configuration.httpAdditionalHeaders = ["Authorization": "synthetic", "Cookie": "synthetic"]
    configuration.httpCookieStorage = .shared
    configuration.urlCredentialStorage = .shared
    return AppInformationService(configuration: configuration)
  }
  static func main() async throws {
    let valid = try payload()
    let decoded = try AppInformation.decode(valid)
    try require(decoded.revisionDate == "2026-11-07", "Valid content must decode")
    let bundled = try AppInformation.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try require(!bundled.languages["zh-Hans"]!.privacy.isEmpty, "Bundled Chinese policy must be readable")
    for change: (inout [String: Any]) -> Void in [
      { $0["schemaVersion"] = 2 }, { $0["appID"] = "other.app" },
      { $0["revisionDate"] = "2026-02-30" }, { $0["languages"] = [:] },
      { $0["languages"] = ["en": ["about": [], "privacy": [], "support": []]] },
    ] {
      let data = try payload(change)
      try await reject { _ = try AppInformation.decode(data) }
    }
    let overlong = try payload { object in
      var languages = object["languages"] as! [String: [String: Any]]
      languages["en"]?["privacy"] = [["title": "Privacy", "paragraphs": [String(repeating: "x", count: 4_001)]]]
      object["languages"] = languages
    }
    try await reject { _ = try AppInformation.decode(overlong) }
    InformationProtocol.prepare { $0.respond(body: valid) }
    _ = try await service().fetch()
    let request = InformationProtocol.snapshot().0[0]
    try require(request.url?.absoluteString == "https://daypage-api.cubxxw.com/daypage/v1/app-info.json", "Fixed endpoint")
    try require(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil, "Bodyless GET")
    try require(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil,
                "No authorization or cookies")
    for error in [URLError.notConnectedToInternet, .timedOut, .serverCertificateUntrusted] {
      InformationProtocol.prepare { $0.client?.urlProtocol($0, didFailWithError: URLError(error)) }
      try await reject { _ = try await service().fetch() }
    }
    for status in [301, 302, 307, 308, 401, 404, 500] {
      InformationProtocol.prepare { $0.respond(status, body: valid) }
      try await reject { _ = try await service().fetch() }
    }
    InformationProtocol.prepare { $0.respond(mime: "text/html", body: valid) }
    try await reject { _ = try await service().fetch() }
    InformationProtocol.prepare { $0.respond(body: Data(repeating: 32, count: 131_073)) }
    try await reject { _ = try await service().fetch() }
    // No declared length: successive chunks must cancel before EOF arrives.
    InformationProtocol.prepare { proto in
      let response = HTTPURLResponse(url: proto.request.url!, statusCode: 200,
                                     httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
      for _ in 0..<33 { proto.client?.urlProtocol(proto, didLoad: Data(repeating: 32, count: 4096)) }
    }
    try await reject { _ = try await service().fetch() }
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(InformationProtocol.snapshot().1, "Oversized unfinished stream must be cancelled")
    // A redirect delegate callback must reject both same- and cross-origin hops.
    for location in ["https://daypage-api.cubxxw.com/elsewhere", "https://example.invalid/collect"] {
      InformationProtocol.prepare { proto in
        let response = HTTPURLResponse(url: proto.request.url!, statusCode: 302,
                                       httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
        proto.client?.urlProtocol(proto, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
      }
      try await reject { _ = try await service().fetch() }
      try require(InformationProtocol.snapshot().0.count == 1, "Redirect must not dispatch a second request")
    }
    InformationProtocol.prepare { _ in }
    let cancelled = Task { try await service().fetch() }
    try await Task.sleep(nanoseconds: 50_000_000)
    cancelled.cancel()
    try await reject { _ = try await cancelled.value }
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(InformationProtocol.snapshot().1, "Caller cancellation must stop transport")
    print("PASS: public information boundaries")
  }
}
