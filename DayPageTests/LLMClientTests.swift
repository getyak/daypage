import XCTest
import DayPageStorage
import DayPageServices
@testable import DayPage

// MARK: - FakeTransport

/// Test double for `HTTPTransport`. Each call pops a programmed response
/// from `responses` so a test can script "first call fails, second
/// succeeds" cases for retry-logic coverage. If the queue runs dry the
/// fake fails the test rather than blocking the suite indefinitely.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let statusCode: Int
        let error: Error?
    }

    private let lock = NSLock()
    private var queue: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ queue: [Response]) {
        self.queue = queue
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        guard !queue.isEmpty else {
            lock.unlock()
            throw URLError(.cannotConnectToHost)
        }
        let next = queue.removeFirst()
        lock.unlock()
        if let error = next.error { throw error }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }
}

private func okBody(content: String) -> Data {
    let body: [String: Any] = [
        "choices": [
            ["message": ["role": "assistant", "content": content]]
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: body)
}

// MARK: - LLMClientTests

/// Integration tests for LLMClient — issues #30 / #31.
///
/// These exercise the same `complete()` path CompilationService uses on
/// every compile, just with a fake HTTP transport so the suite stays
/// offline-deterministic. Covers the retry classifier, error mapping,
/// and the happy path.
final class LLMClientTests: XCTestCase {

    private func makeConfig() -> LLMClient.Config {
        LLMClient.Config(
            baseURL: "https://example.test/v1",
            apiKey: "sk-fake-test-key",
            model: "deepseek-test",
            maxTokens: 256,
            temperature: 0.5,
            timeout: 5
        )
    }

    // MARK: - Happy path

    func testComplete_returnsAssistantContent_onHTTP200() async throws {
        let transport = FakeTransport([
            .init(data: okBody(content: "  hello world  "), statusCode: 200, error: nil)
        ])
        let client = LLMClient(config: makeConfig(), transport: transport)
        let result = try await client.complete(messages: [.user("hi")])
        XCTAssertEqual(result, "hello world", "Response content must be returned trimmed")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testComplete_sendsBearerTokenAndJSONBody() async throws {
        let transport = FakeTransport([
            .init(data: okBody(content: "ok"), statusCode: 200, error: nil)
        ])
        let client = LLMClient(config: makeConfig(), transport: transport)
        _ = try await client.complete(messages: [.user("ping")])
        let req = transport.requests.first!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-fake-test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(req.httpBody, "Request must carry a JSON body")
    }

    // MARK: - Retry classifier

    func testComplete_retriesOnHTTP500_thenSucceeds() async throws {
        let transport = FakeTransport([
            .init(data: Data("internal error".utf8), statusCode: 500, error: nil),
            .init(data: okBody(content: "recovered"), statusCode: 200, error: nil)
        ])
        let client = LLMClient(config: makeConfig(), transport: transport)
        let policy = RetryPolicy(maxAttempts: 2, backoffSeconds: [0])
        let result = try await client.complete(
            messages: [.user("ping")],
            policy: policy
        )
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(transport.requests.count, 2, "Must have retried once after the 500")
    }

    func testComplete_doesNotRetryOnHTTP401() async {
        let transport = FakeTransport([
            .init(data: Data("unauthorized".utf8), statusCode: 401, error: nil),
            .init(data: okBody(content: "should not see this"), statusCode: 200, error: nil)
        ])
        let client = LLMClient(config: makeConfig(), transport: transport)
        let policy = RetryPolicy(maxAttempts: 3, backoffSeconds: [0, 0])
        do {
            _ = try await client.complete(messages: [.user("ping")], policy: policy)
            XCTFail("401 must throw, not return a success body")
        } catch LLMError.apiError(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Expected LLMError.apiError(401), got \(error)")
        }
        XCTAssertEqual(transport.requests.count, 1, "401 is terminal — must not retry")
    }

    func testComplete_mapsHTTP429_toRateLimited() async {
        let transport = FakeTransport([
            .init(data: Data("rate limit".utf8), statusCode: 429, error: nil),
            .init(data: Data("rate limit".utf8), statusCode: 429, error: nil),
            .init(data: Data("rate limit".utf8), statusCode: 429, error: nil)
        ])
        let client = LLMClient(config: makeConfig(), transport: transport)
        let policy = RetryPolicy(maxAttempts: 3, backoffSeconds: [0, 0])
        do {
            _ = try await client.complete(messages: [.user("ping")], policy: policy)
            XCTFail("429 must throw after exhausting retries")
        } catch LLMError.rateLimited {
            // expected — 429 normalizes to rateLimited
        } catch {
            XCTFail("Expected LLMError.rateLimited, got \(error)")
        }
        XCTAssertEqual(transport.requests.count, 3, "Must have used the full retry budget")
    }

    // MARK: - Empty / malformed response

    func testComplete_throwsOnMissingContentField() async {
        let badBody: [String: Any] = ["choices": [["message": ["role": "assistant"]]]]
        let badData = try! JSONSerialization.data(withJSONObject: badBody)
        let transport = FakeTransport([
            .init(data: badData, statusCode: 200, error: nil)
        ])
        let client = LLMClient(config: makeConfig(), transport: transport)
        do {
            _ = try await client.complete(messages: [.user("ping")])
            XCTFail("Missing content field must throw")
        } catch {
            // Either emptyResponse or parseError — both are acceptable;
            // the contract is "do not silently return empty string".
        }
    }
}
