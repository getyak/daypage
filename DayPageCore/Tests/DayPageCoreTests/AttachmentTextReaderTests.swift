import XCTest
import CoreGraphics
@testable import DayPageCore

final class AttachmentTextReaderTests: XCTestCase {
  func testLongImageOnlyPDFDoesNotReturnTruncationAsRecognizedText() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
    for _ in 0..<21 { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF()
    do {
      _ = try await AttachmentTextReader.read(url: url, kind: "file")
      XCTFail("A page limit marker is not PDF content")
    } catch AttachmentTextError.noText { }
  }
  func testReadsSelectedUTF8FileAndBoundsLongText() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try String(repeating: "卡片内容", count: 6_000).write(to: url, atomically: true, encoding: .utf8)
    let text = try await AttachmentTextReader.read(url: url, kind: "file")
    XCTAssertTrue(text.hasPrefix("卡片内容"))
    XCTAssertLessThanOrEqual(text.count, 16_100)
    XCTAssertTrue(text.contains("truncated"))
  }

  func testExistingTranscriptDoesNotNeedToOpenAudio() async throws {
    let text = try await AttachmentTextReader.read(url: URL(fileURLWithPath: "/missing/audio.m4a"), kind: "audio", transcript: "A recorded thought")
    XCTAssertEqual(text, "A recorded thought")
  }

  func testUnknownBinaryIsNotDecodedAsNotes() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0x00, 0xFF, 0x00]).write(to: url)
    do {
      _ = try await AttachmentTextReader.read(url: url, kind: "file")
      XCTFail("Unsupported binary must not be claimed as readable text")
    } catch AttachmentTextError.unsupported { }
  }

  func testCancelledReadReturnsNoMaterial() async throws {
    let task = Task {
      try Task.checkCancellation()
      return try await AttachmentTextReader.read(url: URL(fileURLWithPath: "/missing.txt"), kind: "file")
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("A cancelled read must not produce content") }
    catch is CancellationError { }
  }
}
