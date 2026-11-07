import Foundation

private enum FixtureFailure: Error { case assertion(String) }

// Each request owns its stop signal; late teardown cannot satisfy a later case.
final class InformationScenario {
  let handle: (InformationProtocol) -> Void
  private let condition = NSCondition()
  private var requests: [InformationProtocol] = []
  init(_ handle: @escaping (InformationProtocol) -> Void) { self.handle = handle }
  func started(_ request: InformationProtocol) {
    condition.lock(); requests.append(request); condition.broadcast(); condition.unlock()
  }
  func firstRequest() throws -> InformationProtocol {
    condition.lock(); defer { condition.unlock() }
    let limit = Date().addingTimeInterval(3)
    while requests.isEmpty {
      guard condition.wait(until: limit) else { throw FixtureFailure.assertion("Request did not start promptly") }
    }
    return requests[0]
  }
  var count: Int {
    condition.lock(); defer { condition.unlock() }; return requests.count
  }
}

final class InformationProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var scenario: InformationScenario?
  private let stopped = NSCondition()
  private var didStop = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); let scenario = Self.scenario; Self.lock.unlock()
    scenario?.started(self)
    scenario?.handle(self)
  }
  override func stopLoading() {
    stopped.lock(); didStop = true; stopped.broadcast(); stopped.unlock()
  }
  func requireStopped() throws {
    stopped.lock(); defer { stopped.unlock() }
    let limit = Date().addingTimeInterval(3)
    while !didStop {
      guard stopped.wait(until: limit) else { throw FixtureFailure.assertion("This request was not stopped promptly") }
    }
  }
  func respond(_ status: Int = 200, mime: String = "application/json", body: Data,
               headers: [String: String] = [:], finish: Bool = true) {
    let fields = headers.merging(["Content-Type": mime]) { _, contentType in contentType }
    let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: fields)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
  static func prepare(_ action: @escaping (InformationProtocol) -> Void) -> InformationScenario {
    let value = InformationScenario(action)
    lock.lock(); scenario = value; lock.unlock()
    return value
  }
}

final class FixtureClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock().now
  func now() -> ContinuousClock.Instant {
    lock.lock(); defer { lock.unlock() }; return instant
  }
  func advance() {
    lock.lock(); instant = instant.advanced(by: .seconds(9)); lock.unlock()
  }
}

@main struct InformationTests {
  static func require(_ value: Bool, _ message: String) throws {
    if !value { throw FixtureFailure.assertion(message) }
  }
  static func expectError(_ label: String, matching matches: (Error) -> Bool,
                          _ operation: () async throws -> Void) async throws {
    do { try await operation() } catch {
      try require(matches(error), "\(label): unexpected error \(error)")
      return
    }
    throw FixtureFailure.assertion("\(label): expected rejection")
  }
  static func expect(_ expected: AppInformationError, _ operation: () async throws -> Void) async throws {
    try await expectError("\(expected)", matching: { ($0 as? AppInformationError) == expected }, operation)
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
  static func service(clock: FixtureClock? = nil) -> AppInformationService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InformationProtocol.self]
    configuration.httpAdditionalHeaders = ["Authorization": "synthetic", "Cookie": "synthetic"]
    configuration.httpCookieStorage = .shared
    configuration.urlCredentialStorage = .shared
    if let clock { return AppInformationService(configuration: configuration, now: { clock.now() }) }
    return AppInformationService(configuration: configuration)
  }
  static func prompt(_ began: ContinuousClock.Instant) throws {
    try require(began.duration(to: ContinuousClock().now) < .seconds(3), "Watchdog must not satisfy a prompt rejection")
  }
  static func main() async throws {
    let valid = try payload()
    let decoded = try AppInformation.decode(valid)
    try require(decoded.revisionDate == "2026-11-07", "Valid content must decode")
    let bundled = try AppInformation.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try require(!bundled.languages["zh-Hans"]!.privacy.isEmpty, "Bundled Chinese policy must be readable")
    let invalidPayloads: [(inout [String: Any]) -> Void] = [
      { $0["schemaVersion"] = 2 }, { $0["appID"] = "other.app" },
      { $0["revisionDate"] = "2026-02-30" }, { $0["languages"] = [:] },
      { $0["languages"] = ["en": ["about": [], "privacy": [], "support": []]] },
    ]
    for change in invalidPayloads {
      let data = try payload(change)
      try await expect(.invalidContent) { _ = try AppInformation.decode(data) }
    }
    let overlong = try payload { object in
      var languages = object["languages"] as! [String: [String: Any]]
      languages["en"]?["privacy"] = [["title": "Privacy", "paragraphs": [String(repeating: "x", count: 4_001)]]]
      object["languages"] = languages
    }
    try await expect(.invalidContent) { _ = try AppInformation.decode(overlong) }
    let success = InformationProtocol.prepare { $0.respond(body: valid) }
    _ = try await service().fetch()
    let request = try success.firstRequest().request
    try require(request.url?.absoluteString == "https://daypage-api.cubxxw.com/daypage/v1/app-info.json", "Fixed endpoint")
    try require(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil, "Bodyless GET")
    try require(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil,
                "No authorization or cookies")
    for code in [URLError.notConnectedToInternet, .timedOut, .serverCertificateUntrusted] {
      _ = InformationProtocol.prepare { $0.client?.urlProtocol($0, didFailWithError: URLError(code)) }
      try await expectError("network error", matching: { ($0 as? URLError)?.code == code }) { _ = try await service().fetch() }
    }
    for status in [301, 302, 307, 308, 401, 404, 500] {
      _ = InformationProtocol.prepare { $0.respond(status, body: valid) }
      try await expect(.invalidResponse) { _ = try await service().fetch() }
    }
    _ = InformationProtocol.prepare { $0.respond(mime: "text/html", body: valid) }
    try await expect(.invalidResponse) { _ = try await service().fetch() }
    // Legal JSON padded with legal whitespace tests byte admission independently.
    var atLimit = valid
    atLimit.append(Data(repeating: 32, count: 131_072 - valid.count))
    _ = InformationProtocol.prepare { $0.respond(body: atLimit) }
    _ = try await service().fetch()
    var aboveLimit = atLimit
    aboveLimit.append(32)
    let declared = InformationProtocol.prepare {
      $0.respond(body: Data(), headers: ["Content-Length": "131073"], finish: false)
    }
    var began = ContinuousClock().now
    try await expect(.tooLarge) { _ = try await service().fetch() }
    try prompt(began)
    try declared.firstRequest().requireStopped()
    _ = InformationProtocol.prepare { $0.respond(body: aboveLimit) }
    try await expect(.tooLarge) { _ = try await service().fetch() }
    let streamed = InformationProtocol.prepare { proto in
      proto.respond(body: Data(), finish: false)
      for offset in stride(from: 0, to: aboveLimit.count, by: 4096) {
        proto.client?.urlProtocol(proto, didLoad: aboveLimit.subdata(in: offset..<min(offset + 4096, aboveLimit.count)))
      }
      // No EOF: removing the receive-time cap must yield timedOut, not pass.
    }
    began = ContinuousClock().now
    try await expect(.tooLarge) { _ = try await service().fetch() }
    try prompt(began)
    try streamed.firstRequest().requireStopped()
    for location in ["https://daypage-api.cubxxw.com/elsewhere", "https://example.invalid/collect"] {
      let redirected = InformationProtocol.prepare { proto in
        let response = HTTPURLResponse(url: proto.request.url!, statusCode: 302,
                                       httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
        proto.client?.urlProtocol(proto, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
      }
      began = ContinuousClock().now
      try await expect(.redirected) { _ = try await service().fetch() }
      try prompt(began)
      try redirected.firstRequest().requireStopped()
      try require(redirected.count == 1, "Redirect destination must never load")
    }
    let cancelledScenario = InformationProtocol.prepare { _ in }
    let cancelled = Task.detached { try await service().fetch() }
    let cancelledRequest = try cancelledScenario.firstRequest()
    began = ContinuousClock().now
    cancelled.cancel()
    try await expectError("caller cancellation", matching: { $0 is CancellationError }) { _ = try await cancelled.value }
    try prompt(began)
    try cancelledRequest.requireStopped()
    let clock = FixtureClock()
    let lateScenario = InformationProtocol.prepare { _ in }
    let late = Task.detached { try await service(clock: clock).fetch() }
    let lateRequest = try lateScenario.firstRequest()
    clock.advance()
    began = ContinuousClock().now
    lateRequest.respond(body: valid)
    try await expectError("expired valid completion", matching: { ($0 as? URLError)?.code == .timedOut }) { _ = try await late.value }
    try prompt(began) // The timer scheduled for real eight seconds has not fired.
    let silent = InformationProtocol.prepare { _ in }
    began = ContinuousClock().now
    try await expectError("silent deadline", matching: { ($0 as? URLError)?.code == .timedOut }) { _ = try await service().fetch() }
    let elapsed = began.duration(to: ContinuousClock().now)
    try require(elapsed >= .seconds(7) && elapsed < .seconds(11), "Silent transport must use the eight-second budget")
    try silent.firstRequest().requireStopped()
    print("PASS: public information boundaries")
  }
}
