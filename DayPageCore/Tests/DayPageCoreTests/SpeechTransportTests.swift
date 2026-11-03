import XCTest
@testable import DayPageCore

final class SpeechTransportTests: XCTestCase {
  // Two complete MPEG1 Layer III frames at 128 kbps / 44.1 kHz.
  private var mp3: Data {
    let frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(repeating: 0, count: 413)
    return frame + frame
  }
  private func request() throws -> URLRequest {
    try SpeechRequest.make(channel: SpeechChannel(provider: .openAI), text: "Synthetic sample.", apiKey: "fixture")
  }

  func testAcceptsBoundedMP3AndRejectsJSONDisguisedAsAudio() async throws {
    let valid = mp3
    let transport = SpeechTransport(load: { _, _ in SpeechHTTPResponse(data: valid, statusCode: 200, mimeType: "audio/mpeg") })
    let result = try await transport.data(for: request())
    XCTAssertEqual(result, valid)
    let invalid = SpeechTransport(load: { _, _ in SpeechHTTPResponse(data: Data("{\"error\":\"private\"}".utf8), statusCode: 200, mimeType: "audio/mpeg") })
    do { _ = try await invalid.data(for: request()); XCTFail("Expected malformed audio rejection") }
    catch { XCTAssertEqual(error as? SpeechError, .invalidAudio) }
  }

  func testRejectsTruncatedID3HTMLAndTruncatedAudio() {
    XCTAssertFalse(SpeechAudio.isMP3(Data("ID3".utf8)))
    XCTAssertFalse(SpeechAudio.isMP3(Data("<html>not audio</html>".utf8)))
    XCTAssertFalse(SpeechAudio.isMP3(mp3.prefix(500)))
    XCTAssertTrue(SpeechAudio.isMP3(mp3))
  }

  func testRejectsHTTPFailuresRedirectsUnexpectedMimeAndOversizedData() async throws {
    for (status, expected) in [(401, SpeechError.unauthorized), (403, .unauthorized), (429, .rateLimited), (302, .rejected(302)), (500, .rejected(500))] {
      let transport = SpeechTransport(load: { _, _ in SpeechHTTPResponse(data: Data("private server body".utf8), statusCode: status, mimeType: "text/plain") })
      do { _ = try await transport.data(for: request()); XCTFail("Expected HTTP rejection") }
      catch { XCTAssertEqual(error as? SpeechError, expected); XCTAssertFalse(error.localizedDescription.contains("private server body")) }
    }
    let valid = mp3
    let badMime = SpeechTransport(load: { _, _ in SpeechHTTPResponse(data: valid, statusCode: 200, mimeType: "text/html") })
    do { _ = try await badMime.data(for: request()); XCTFail("Expected MIME rejection") }
    catch { XCTAssertEqual(error as? SpeechError, .invalidAudio) }
    let large = SpeechTransport(load: { _, _ in SpeechHTTPResponse(data: Data(repeating: 0, count: 1025), statusCode: 200, mimeType: "audio/mpeg") })
    do { _ = try await large.data(for: request(), maximumBytes: 1024); XCTFail("Expected size rejection") }
    catch { XCTAssertEqual(error as? SpeechError, .tooLarge) }
  }

  func testCancellationBeforeAndAfterLoadingDoesNotReturnAudio() async throws {
    let valid = mp3
    let request = try request()
    let task = Task { () throws -> Data in
      let transport = SpeechTransport(load: { _, _ in
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return SpeechHTTPResponse(data: valid, statusCode: 200, mimeType: "audio/mpeg")
      })
      return try await transport.data(for: request)
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    let lateCancellation = Task { () throws -> Data in
      let transport = SpeechTransport(load: { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return SpeechHTTPResponse(data: valid, statusCode: 200, mimeType: "audio/mpeg")
      })
      return try await transport.data(for: request)
    }
    do { _ = try await lateCancellation.value; XCTFail("Expected cancellation after loading") }
    catch { XCTAssertTrue(error is CancellationError) }
  }
}
