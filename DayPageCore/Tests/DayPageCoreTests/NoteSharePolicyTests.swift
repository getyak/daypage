import XCTest
@testable import DayPageCore

final class NoteSharePolicyTests: XCTestCase {
  func testLongOrLineHeavyBodyRequiresCompleteTextInsteadOfClippedImage() {
    XCTAssertEqual(NoteSharePolicy.imageAvailability(for: String(repeating: "字", count: 4_001)), .tooLong)
    XCTAssertEqual(NoteSharePolicy.imageAvailability(for: String(repeating: "a\n", count: 101)), .tooLong)
    XCTAssertEqual(NoteSharePolicy.imageAvailability(for: "A complete short thought."), .available)
  }

  func testAttachmentOnlyNoteDoesNotExportAnEmptyImage() {
    XCTAssertEqual(NoteSharePolicy.imageAvailability(for: " \n\t"), .emptyBody)
  }

  func testImageBudgetRejectsOversizedAndInvalidDimensionsBeforeRasterization() {
    XCTAssertTrue(NoteSharePolicy.canRenderImage(width: 360, height: 2_000, scale: 2))
    XCTAssertTrue(NoteSharePolicy.canRenderImage(width: 360, height: 2_400, scale: 2))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 360, height: 2_401, scale: 2))
    XCTAssertTrue(NoteSharePolicy.canRenderImage(width: 1_000, height: 1_000, scale: 2))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 1_000.1, height: 1_000, scale: 2))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 360, height: 2_401, scale: 1))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 360, height: 20_000, scale: 2))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 360, height: .infinity, scale: 2))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 0, height: 100, scale: 2))
    XCTAssertFalse(NoteSharePolicy.canRenderImage(width: 360, height: 100, scale: .nan))
  }

  func testCompleteTextPreservesEveryCharacterAndOnlyIncludesOptedInDate() {
    let body = "  Opening\n\n" + String(repeating: "A paragraph. ", count: 1_000) + "\nFinal line  "
    XCTAssertEqual(NoteSharePolicy.completeText(body: body, date: nil), body)
    let dated = NoteSharePolicy.completeText(body: body, date: "October 31, 2026")
    XCTAssertTrue(dated.hasPrefix("October 31, 2026\n\n  Opening"))
    XCTAssertTrue(dated.hasSuffix("\nFinal line  "))
    XCTAssertEqual(NoteSharePolicy.completeText(body: "", date: "October 31, 2026"), "")
  }
}
