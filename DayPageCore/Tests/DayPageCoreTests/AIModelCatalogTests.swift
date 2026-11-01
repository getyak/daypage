import XCTest
@testable import DayPageCore

actor AIFixture {
    var requests: [URLRequest] = []
    var responses: [Data]
    init(_ objects: [[String: Any]]) throws {
        responses = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    }
    func load(_ request: URLRequest) throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else { throw AIError.invalidResponse }
        return responses.removeFirst()
    }
    func recorded() -> [URLRequest] { requests }
}

final class AIModelCatalogTests: XCTestCase {
    private func catalog(_ fixture: AIFixture) -> AIModelCatalog {
        AIModelCatalog(transport: AITransport(load: { request, _ in try await fixture.load(request) }))
    }

    func testOpenAIAutomaticTracksSupportedFlagshipAndExcludesSpecializedAndRetired() async throws {
        let fixture = try AIFixture([["data": [
            ["id": "gpt-6-astra", "created": 10], ["id": "gpt-6.2-astra", "created": 20],
            ["id": "gpt-6.3-mini", "created": 30], ["id": "gpt-6.9-codex", "created": 50],
            ["id": "gpt-image-9", "created": 60], ["id": "gpt-6.8-astra", "lifecycle": "retired"],
        ]]] )
        let resolved = try await catalog(fixture).resolve(configuration: AIProvider.openAI.configuration, apiKey: "fixture-key")
        XCTAssertEqual(resolved.model, "gpt-6.2-astra")
        let recorded = await fixture.recorded()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
    }

    func testFixedModelDoesNotFetchOrChangeSavedChoice() async throws {
        let fixture = try AIFixture([])
        var configuration = AIProvider.openAI.configuration
        configuration.model = "gpt-6-astra"
        let resolved = try await catalog(fixture).resolve(configuration: configuration, apiKey: "fixture-key")
        XCTAssertEqual(resolved, configuration)
        let recorded = await fixture.recorded()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testClaudePaginationUsesOfficialHeadersReleaseDatesAndActiveLifecycle() async throws {
        let fixture = try AIFixture([
            ["data": [["id": "claude-opus-old", "created_at": "2025-01-01T00:00:00Z", "line": "opus", "lifecycle": "active"]],
             "has_more": true, "last_id": "claude-opus-old"],
            ["data": [["id": "claude-sonnet-new", "created_at": "2026-10-01T00:00:00Z", "line": "sonnet", "lifecycle": "active"],
                      ["id": "claude-opus-retired", "created_at": "2026-11-01T00:00:00Z", "lifecycle": "retired"]], "has_more": false],
        ])
        let resolved = try await catalog(fixture).resolve(configuration: AIProvider.anthropic.configuration, apiKey: "fixture-key")
        XCTAssertEqual(resolved.model, "claude-sonnet-new")
        let recorded = await fixture.recorded()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[0].value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        XCTAssertNil(recorded[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(recorded[1].url?.query?.contains("after_id=claude-opus-old") == true)
    }

    func testKimiUsesAvailableCurrentGeneralModelNotDiscontinuedAliasOrCodeModel() async throws {
        let fixture = try AIFixture([["data": [["id": "kimi-latest"], ["id": "kimi-k2.5"],
                                               ["id": "kimi-k3.1-pro"], ["id": "kimi-k3.2-code"]]]])
        let resolved = try await catalog(fixture).resolve(configuration: AIProvider.kimi.configuration, apiKey: "fixture-key")
        XCTAssertEqual(resolved.model, "kimi-k3.1-pro")
    }

    func testQwenAutomaticUsesDocumentedRollingAliasWithoutInventingModelsAPI() async throws {
        let fixture = try AIFixture([])
        let resolved = try await catalog(fixture).resolve(configuration: AIProvider.qwen.configuration, apiKey: "fixture-key")
        XCTAssertEqual(resolved.model, "qwen-max-latest")
        let recorded = await fixture.recorded()
        XCTAssertTrue(recorded.isEmpty)
        do { _ = try await catalog(fixture).models(configuration: AIProvider.glm.configuration, apiKey: "fixture-key"); XCTFail("No undocumented GLM /models") }
        catch { XCTAssertTrue(error is AIError) }
    }

    func testDiscoveryFailureAndEmptyListNeverResolveToSentinel() async throws {
        for response in [["data": []], ["error": ["message": "unavailable"]]] as [[String: Any]] {
            let fixture = try AIFixture([response])
            do { _ = try await catalog(fixture).resolve(configuration: AIProvider.openAI.configuration, apiKey: "fixture-key"); XCTFail("Must preserve unresolved automatic choice") }
            catch { XCTAssertTrue(error is AIError) }
        }
    }

    func testMissingKeyAndUnconsentedHTTPFailBeforeTransport() async throws {
        let fixture = try AIFixture([])
        for (configuration, key) in [(AIProvider.openAI.configuration, ""),
                                     (AIConfiguration(baseURL: "http://example.test/v1", model: AIModelCatalog.automaticModel), "")] {
            do { _ = try await catalog(fixture).models(configuration: configuration, apiKey: key); XCTFail("Reject before transport") }
            catch { XCTAssertTrue(error is AIError) }
        }
        let recorded = await fixture.recorded()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testCrossOriginOrDifferentPathPaginationDoesNotReceiveKey() async throws {
        for next in ["https://outside.test/v1/models", "https://api.openai.com/v1/files", "http://api.openai.com/v1/models"] {
            let fixture = try AIFixture([["data": [["id": "gpt-6-astra"]], "links": ["next": next]]])
            do { _ = try await catalog(fixture).models(configuration: AIProvider.openAI.configuration, apiKey: "fixture-key"); XCTFail("Unsafe pagination") }
            catch { XCTAssertTrue(error is AIError) }
            let recorded = await fixture.recorded()
            XCTAssertEqual(recorded.count, 1)
        }
    }

    func testModelResponseSizeIsBoundedEvenAtInjectedTransportBoundary() async throws {
        let fixture = try AIFixture([["data": [["id": "gpt-6-astra", "name": String(repeating: "x", count: 2 * 1024 * 1024)]]]])
        do { _ = try await catalog(fixture).models(configuration: AIProvider.openAI.configuration, apiKey: "fixture-key"); XCTFail("Oversized metadata") }
        catch { XCTAssertTrue(error is AIError) }
    }

    func testMalformedPaginationCannotSilentlyReturnFirstPage() async throws {
        let fixture = try AIFixture([["data": [["id": "gpt-6-astra"]], "links": ["next": 42]]])
        do { _ = try await catalog(fixture).models(configuration: AIProvider.openAI.configuration, apiKey: "fixture-key"); XCTFail("Do not hide incomplete catalog") }
        catch { XCTAssertTrue(error is AIError) }
    }

    func testOpenRouterRespectsUserCatalogAndOnlyCurrentChatEndpoints() async throws {
        let fixture = try AIFixture([["data": [
            ["id": "openai/gpt-6-astra", "created": 10, "endpoints": ["/api/v1/chat/completions"]],
            ["id": "openai/gpt-6.2-astra", "created": 50, "endpoints": ["/api/v1/responses"]],
            ["id": "anthropic/claude-sonnet-expired", "created": 70, "expiration_date": "2025-01-01"],
        ]]] )
        let resolved = try await catalog(fixture).resolve(configuration: AIProvider.openRouter.configuration, apiKey: "fixture-key")
        XCTAssertEqual(resolved.model, "openai/gpt-6-astra")
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://openrouter.ai/api/v1/models/user")
    }
}
