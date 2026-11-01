import XCTest
@testable import DayPageCore

final class AIProviderTests: XCTestCase {
    func testOfficialPresetsAndRegionsKeepDistinctSecureOrigins() throws {
        XCTAssertEqual(AIProvider.allCases.filter { $0 != .custom }.count, 8)
        XCTAssertEqual(AIProvider.gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        for provider in AIProvider.allCases where provider != .custom {
            XCTAssertTrue(provider.requiresAPIKey)
            XCTAssertEqual(provider.keyURL?.scheme, "https")
            for endpoint in provider.endpoints {
                let configuration = AIConfiguration(baseURL: endpoint.baseURL, model: "fixed")
                XCTAssertEqual(AIProvider.matching(configuration: configuration), provider)
                XCTAssertEqual(try configuration.endpoint.scheme, "https")
            }
        }
        XCTAssertGreaterThan(AIProvider.qwen.endpoints.count, 1)
        XCTAssertFalse(AIProvider.glm.supportsAutomaticModels)
        XCTAssertEqual(AIProvider.glm.configuration.model, "glm-5.3")
    }

    func testProtocolInferenceRequiresExactOfficialOriginAndPath() {
        for base in ["https://api.anthropic.com.evil.test/v1", "https://api.anthropic.com/proxy/v1",
                     "http://api.anthropic.com/v1", "https://api.anthropic.com:8443/v1"] {
            XCTAssertEqual(AIProvider.matching(configuration: .init(baseURL: base, model: "x")), .custom)
        }
        XCTAssertEqual(AIProvider.matching(configuration: .init(baseURL: "https://API.ANTHROPIC.COM:443/v1/messages/", model: "x")), .anthropic)
    }

    func testAutomaticSelectionUsesExistingCodingFieldsOnly() throws {
        let configuration = AIProvider.openAI.configuration
        let data = try JSONEncoder().encode(configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["baseURL", "model", "allowsLocalHTTP", "usesAPIKey"])
        XCTAssertEqual(configuration.model, AIModelCatalog.automaticModel)
        XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self, from: data), configuration)
    }
}
