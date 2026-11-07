import XCTest
@testable import DayPageCore

final class MemoTimestampTests: XCTestCase {
  private func raw(created: String, pinned: String? = nil) -> String {
    "---\nid: 11111111-2222-4333-8444-555555555555\ntype: text\ncreated: \(created)\n"
      + (pinned.map { "pinned_at: \($0)\n" } ?? "") + "---\n\nSynthetic timestamp compatibility"
  }
  private func instant(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }

  func testWholeSecondCreatedAndPinnedDoNotFallBackToNowOrNil() throws {
    let expected = try instant("2026-11-07T02:03:04Z")
    let memo = try XCTUnwrap(Memo.fromMarkdown(raw(created: "2026-11-07T02:03:04Z", pinned: "2026-11-07T03:03:04Z")))
    XCTAssertEqual(memo.created, expected)
    XCTAssertEqual(memo.pinnedAt, expected.addingTimeInterval(3600))
  }

  func testWholeSecondOffsetFormsPreserveTheSameInstant() throws {
    let expected = try instant("2026-11-07T02:03:04Z")
    let memo = try XCTUnwrap(Memo.fromMarkdown(raw(created: "2026-11-07T10:03:04+08:00", pinned: "2026-11-07T07:33:04+05:30")))
    XCTAssertEqual(memo.created, expected); XCTAssertEqual(memo.pinnedAt, expected)
    for value in ["2026-11-08T02:02:04+23:59", "2026-11-06T02:04:04-23:59", "2026-11-07t02:03:04z"] {
      XCTAssertEqual(try XCTUnwrap(Memo.fromMarkdown(raw(created: value))).created, expected)
    }
  }

  func testExistingFractionalWriterRoundTripKeepsMemoMilliseconds() throws {
    let expected = try instant("2026-11-07T02:03:04Z").addingTimeInterval(0.123)
    let original = Memo(created: expected, pinnedAt: expected.addingTimeInterval(3600), body: "Synthetic fractional timestamp")
    let markdown = original.toMarkdown(), reopened = try XCTUnwrap(Memo.fromMarkdown(markdown))
    XCTAssertTrue(markdown.contains(".123Z"))
    XCTAssertEqual(reopened.created.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.00001)
    XCTAssertEqual(try XCTUnwrap(reopened.pinnedAt).timeIntervalSince1970,
      try XCTUnwrap(original.pinnedAt).timeIntervalSince1970, accuracy: 0.00001)
    let precise = try XCTUnwrap(Memo.fromMarkdown(raw(created: "2026-11-07T02:03:04.123456Z")))
    XCTAssertEqual(precise.created.timeIntervalSinceReferenceDate,
      try instant("2026-11-07T02:03:04Z").timeIntervalSinceReferenceDate + 0.123456, accuracy: 0.000001)
  }

  func testFrozenCrossClientFixtureParsesItsDeclaredWholeSecondCreationTime() throws {
    let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let file = fixtures.appendingPathComponent("file-exchange-v1/raw/2026-11-07.md")
    let raw = try String(contentsOf: file), memo = try XCTUnwrap(Memo.fromMarkdown(raw))
    XCTAssertEqual(memo.created, try instant("2026-11-07T02:03:04Z"))
  }
}
