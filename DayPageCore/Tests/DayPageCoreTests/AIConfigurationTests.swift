import XCTest
@testable import DayPageCore

final class AIConfigurationTests: XCTestCase {
    func testOpenAICompatiblePathAndOrigin() throws {
        let c = AIConfiguration(baseURL: "https://EXAMPLE.com/v1/", model: "personal-model")
        XCTAssertEqual(try c.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(try c.origin, "https://example.com")
    }
    func testLocalAnonymousModelRequiresExplicitHTTPChoice() throws {
        let c = AIConfiguration(baseURL: "http://192.168.1.20:1234/v1", model: "local")
        XCTAssertThrowsError(try c.endpoint)
        var allowed = c; allowed.allowsLocalHTTP = true
        XCTAssertEqual(try allowed.endpoint.host, "192.168.1.20")
    }
    func testRejectsRemotePlainHTTPAndEmbeddedCredentials() {
        for address in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "file:///tmp/api"] {
            XCTAssertThrowsError(try AIConfiguration(baseURL: address, model: "x", allowsLocalHTTP: true).endpoint)
        }
    }
    func testRejectsMissingModelAndMissingAddress() {
        XCTAssertThrowsError(try AIConfiguration(baseURL: "https://example.com/v1", model: " ").endpoint)
        XCTAssertThrowsError(try AIConfiguration(baseURL: "", model: "x").endpoint)
    }
    func testPreferencesContainNoSecretAndOriginsAreSeparate() throws {
        let a = AIConfiguration(baseURL: "https://a.example/v1", model: "x")
        let b = AIConfiguration(baseURL: "https://b.example/v1", model: "x")
        XCTAssertNotEqual(try a.origin, try b.origin)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(a), as: UTF8.self).contains("apiKey"))
    }
    func testNumericPrefixOfPublicDomainIsNotALocalAddress() {
        for host in ["10.0.0.1.attacker.example", "127.0.0.1.evil.example", "010.0.0.1", "192.168.1.1.example"] {
            XCTAssertThrowsError(try AIConfiguration(baseURL: "http://" + host + "/v1", model: "x", allowsLocalHTTP: true).endpoint)
        }
    }
    func testKeyOriginDoesNotChangeWhileEditingModelOrHTTPPermission() throws {
        var c = AIConfiguration(baseURL: "http://192.168.1.20:1234/v1", model: "")
        let origin = try c.origin
        c.model = "local-model"; c.allowsLocalHTTP = true
        XCTAssertEqual(try c.origin, origin)
        XCTAssertNoThrow(try c.endpoint)
    }
}
