import XCTest
import Foundation
import DayPageStorage
@testable import DayPageServices

// MARK: - Fakes

/// Recording `HTTPTransport` with a programmed response queue. Each outbound
/// attempt appends the request BEFORE popping a response, so "zero transport
/// calls" assertions are meaningful.
private actor RecordingTransport: HTTPTransport {
    struct Reply {
        let statusCode: Int
        let body: Data
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://llm.invalid")!,
            statusCode: reply.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (reply.body, response)
    }

    var requestCount: Int { requests.count }
}

/// Terminal `URLProtocol` standing in for the LLM endpoint at the REAL
/// streaming boundary (`URLSession.bytes`). Records every request it is asked
/// to load and serves a canned SSE body. Hit counts are filtered per request
/// URL because Swift Testing/XCTest may run suites in parallel.
private final class CannedSSEProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var loadedURLs: [URL] = []

    static func hits(matching url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return loadedURLs.filter { $0 == url }.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if let url = request.url { Self.loadedURLs.append(url) }
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://llm.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"strea\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"med\"}}]}\n\n"
            + "data: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func streamingSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CannedSSEProtocol.self]
    return URLSession(configuration: configuration)
}

private func okBody(_ content: String) -> Data {
    let json: [String: Any] = [
        "choices": [["message": ["role": "assistant", "content": content]]]
    ]
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: json)
}

/// Counts stream deltas across the `@MainActor` onDelta callback boundary.
private final class DeltaCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}

// MARK: - Suite

/// Issue #928 — no LLM transport call may happen while the master AI switch is
/// off: not at entry, not on a retry after a mid-retry toggle, and not at SSE
/// connect. Allowed calls must still succeed. Nothing here touches the live
/// network — the transport and the streaming session are fakes.
final class LLMClientConsentTests: XCTestCase {

    private func makeClient(
        transport: HTTPTransport,
        consent: AIConsentChecking,
        baseURL: String = "https://llm.invalid/v1",
        streamSession: URLSession = .shared
    ) -> LLMClient {
        LLMClient(
            config: .init(
                baseURL: baseURL,
                apiKey: "sk-test-key",
                model: "test-model",
                maxTokens: 16,
                temperature: 0,
                timeout: 5
            ),
            spanName: "test.consent",
            transport: transport,
            consent: consent,
            streamSession: streamSession
        )
    }

    // MARK: Blocked without permission

    func testCompleteBlockedAtEntryReachesNoTransport() async {
        let transport = RecordingTransport([.init(statusCode: 200, body: okBody("leaked?"))])
        let client = makeClient(
            transport: transport,
            consent: ScriptedAIConsent([.failure(.aiDisabled)])
        )
        do {
            _ = try await client.complete(messages: [.user("hi")])
            XCTFail("complete() must throw when the master switch is off")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }

    func testStreamBlockedAtEntryReachesNoConnection() async throws {
        let session = streamingSession()
        defer { session.finishTasksAndInvalidate() }
        let baseURL = "https://stream-entry-\(UUID().uuidString).invalid/v1"
        let client = makeClient(
            transport: RecordingTransport([]),
            consent: ScriptedAIConsent([.failure(.aiDisabled)]),
            baseURL: baseURL,
            streamSession: session
        )
        let counter = DeltaCounter()
        do {
            _ = try await client.stream(messages: [.user("hi")]) { _ in counter.increment() }
            XCTFail("stream() must throw when the master switch is off")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        }
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(
            CannedSSEProtocol.hits(matching: try XCTUnwrap(URL(string: "\(baseURL)/chat/completions"))),
            0
        )
    }

    func testStreamRevokedBetweenEntryAndConnectStopsBeforeTheSocket() async throws {
        let session = streamingSession()
        defer { session.finishTasksAndInvalidate() }
        let baseURL = "https://stream-preconnect-\(UUID().uuidString).invalid/v1"
        let client = makeClient(
            transport: RecordingTransport([]),
            consent: ScriptedAIConsent([.success(()), .failure(.aiDisabled)]),
            baseURL: baseURL,
            streamSession: session
        )
        do {
            _ = try await client.stream(messages: [.user("hi")]) { _ in }
            XCTFail("stream() must throw when the switch turns off before connecting")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        }
        XCTAssertEqual(
            CannedSSEProtocol.hits(matching: try XCTUnwrap(URL(string: "\(baseURL)/chat/completions"))),
            0
        )
    }

    // MARK: Allowed traffic still works

    func testAllowedCompleteSucceedsThroughTransport() async throws {
        let transport = RecordingTransport([.init(statusCode: 200, body: okBody("  hello  "))])
        let client = makeClient(transport: transport, consent: AllowAllAIConsent())
        let response = try await client.complete(messages: [.user("hi")])
        XCTAssertEqual(response, "hello")
        let count = await transport.requestCount
        XCTAssertEqual(count, 1)
    }

    func testAllowedStreamDeliversDeltasThroughTheStreamBoundary() async throws {
        let session = streamingSession()
        defer { session.finishTasksAndInvalidate() }
        let baseURL = "https://stream-allowed-\(UUID().uuidString).invalid/v1"
        let client = makeClient(
            transport: RecordingTransport([]),
            consent: AllowAllAIConsent(),
            baseURL: baseURL,
            streamSession: session
        )
        let counter = DeltaCounter()
        let text = try await client.stream(messages: [.user("hi")]) { _ in counter.increment() }
        XCTAssertEqual(text, "streamed")
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(
            CannedSSEProtocol.hits(matching: try XCTUnwrap(URL(string: "\(baseURL)/chat/completions"))),
            1
        )
    }

    // MARK: Revocation mid-retry

    func testDisablingDuringRetryPreventsTheNextAttempt() async {
        // Attempts 1–2 are authorized (entry check + first sendOnce); the
        // first transport call gets a retryable 500. The user then turns the
        // switch off — the retry's sendOnce re-authorizes and must stop
        // BEFORE transport.
        let transport = RecordingTransport([
            .init(statusCode: 500, body: Data("boom".utf8)),
            .init(statusCode: 200, body: okBody("should never be fetched")),
        ])
        let consent = ScriptedAIConsent([.success(()), .success(()), .failure(.aiDisabled)])
        let client = makeClient(transport: transport, consent: consent)
        do {
            _ = try await client.complete(
                messages: [.user("hi")],
                policy: RetryPolicy(maxAttempts: 3, backoffSeconds: [0, 0, 0])
            )
            XCTFail("complete() must surface the revocation")
        } catch let error as AIAuthorizationError {
            XCTAssertEqual(error, .aiDisabled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 1, "the second request must never be built")
        XCTAssertEqual(consent.calls, 3, "entry + sendOnce#1 + refused sendOnce#2")
    }

    // MARK: Retry classifier

    func testAuthorizationErrorsAreTerminalRetries() {
        XCTAssertTrue(Self.isStop(LLMClient.shouldRetry(AIAuthorizationError.aiDisabled)))
        XCTAssertTrue(Self.isStop(LLMClient.shouldRetry(AIAuthorizationError.screenshotCloudDisabled)))
        // Sanity: transient errors still retry.
        XCTAssertTrue(Self.isRetry(LLMClient.shouldRetry(LLMError.rateLimited)))
    }

    private static func isStop(_ decision: RetryDecision) -> Bool {
        if case .stop = decision { return true }
        return false
    }

    private static func isRetry(_ decision: RetryDecision) -> Bool {
        if case .retry = decision { return true }
        return false
    }
}
