import XCTest
@testable import DayPageCore

final class AIHeaderSafetyTests: XCTestCase {
  func testControlScalarsIncludingCRLFAreRejectedBeforeAuthorization() {
    let configuration = AIConfiguration(baseURL: "https://example.invalid/v1", model: "text", usesAPIKey: true)
    for value in ["before\r\nafter", "before\nafter", "before\u{0000}after", "before\tafter"] {
      XCTAssertThrowsError(try AITransport.key(value, configuration: configuration), "Reject control characters before making a request")
    }
  }
}
