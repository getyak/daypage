import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import DayPageCore

final class AttachmentTextReaderTests: XCTestCase {
  func testImageOCRReadsTheActualGeneratedCardImage() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 800, height: 180,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: 800, height: 180))
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    bitmap.textPosition = CGPoint(x: 24, y: 75)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "DAYPAGE CARD 369", attributes: attributes)), bitmap)
    let image = try XCTUnwrap(bitmap.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let recognized = try await AttachmentTextReader.read(url: url, kind: "photo")
    XCTAssertTrue(recognized.uppercased().contains("DAYPAGE"), recognized)
    XCTAssertTrue(recognized.contains("369"), recognized)
    let fromData = try await AttachmentTextReader.readImage(data: Data(contentsOf: url))
    XCTAssertTrue(fromData.uppercased().contains("DAYPAGE"), fromData)
    XCTAssertTrue(fromData.contains("369"), fromData)
  }
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

  func testCancelledImageDataReadReturnsNoMaterial() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AttachmentTextReader.readImage(data: Data())
    }
    do { _ = try await task.value; XCTFail("A cancelled extraction must not produce content") }
    catch is CancellationError { }
  }

  func testImageDataRejectsNonImagesAndOversizedInput() async throws {
    do { _ = try await AttachmentTextReader.readImage(data: Data("not an image".utf8)); XCTFail("Invalid image read") }
    catch AttachmentTextError.unreadable { }
    do { _ = try await AttachmentTextReader.readImage(data: Data(repeating: 0, count: 25 * 1024 * 1024 + 1)); XCTFail("Oversized image read") }
    catch AttachmentTextError.tooLarge { }
  }
}
