import XCTest
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Regression tests for the watch-audio receive path.
///
/// Bug: when the iPhone received a voice clip from the Apple Watch, it saved
/// the file and enqueued transcription (which bumped the "N pending" count),
/// but never created a memo — so the audio arrived and the count showed, yet
/// no card ever appeared in Today, and the transcript could never match a
/// non-existent attachment (retries exhausted into `.failed`).
///
/// The fix mirrors the phone-side capture path: `appendVoiceMemo` writes a
/// `.voice` memo with a `.pending` audio attachment into the day file, so the
/// card shows immediately and `VoiceAttachmentQueue.applyTranscript` can patch
/// the transcript onto the attachment whose `file` matches `audioPath`.
final class WatchReceiveServiceTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("WatchReceiveServiceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - appendVoiceMemo

    /// The core regression: receiving a watch clip must produce exactly one
    /// readable voice memo in today's file — not just an enqueued transcription.
    func testAppendVoiceMemo_writesReadableVoiceMemoToDayFile() throws {
        let now = Date()
        let audioPath = "raw/assets/watch_20260714_101500_ABCD.m4a"

        let memo = WatchReceiveService.appendVoiceMemo(audioPath: audioPath, duration: 12.0, created: now)

        let readBack = try RawStorage.read(for: now)
        XCTAssertEqual(readBack.count, 1, "Receiving a watch clip must create exactly one memo")
        let saved = try XCTUnwrap(readBack.first)
        XCTAssertEqual(saved.id, memo.id, "Read-back memo must be the one appendVoiceMemo returned")
        XCTAssertEqual(saved.type, .voice, "Watch audio memo must be typed .voice")
    }

    /// The attachment must carry the audio metadata and start in `.pending` so
    /// the card shows the shimmer placeholder and the queue can later match it.
    func testAppendVoiceMemo_attachmentIsPendingAudioMatchingAudioPath() throws {
        let now = Date()
        let audioPath = "raw/assets/watch_20260714_101500_WXYZ.m4a"

        WatchReceiveService.appendVoiceMemo(audioPath: audioPath, duration: 8.5, created: now)

        let saved = try XCTUnwrap(try RawStorage.read(for: now).first)
        XCTAssertEqual(saved.attachments.count, 1)
        let att = try XCTUnwrap(saved.attachments.first)
        XCTAssertEqual(att.kind, "audio")
        XCTAssertEqual(att.file, audioPath,
            "attachment.file must equal audioPath so VoiceAttachmentQueue.applyTranscript can match it")
        XCTAssertEqual(att.transcriptionStatus, .pending,
            "A freshly received clip must be pending — not done, not failed")
        XCTAssertNil(att.transcript, "No transcript should exist yet")
        XCTAssertEqual(att.duration, 8.5, "Duration from the transfer metadata must be preserved")
    }

    /// Duration is optional in the transfer metadata (older watch builds omit
    /// it); a nil duration must still produce a valid pending audio memo.
    func testAppendVoiceMemo_nilDurationStillProducesValidMemo() throws {
        let now = Date()
        let audioPath = "raw/assets/watch_nodur.m4a"

        WatchReceiveService.appendVoiceMemo(audioPath: audioPath, duration: nil, created: now)

        let saved = try XCTUnwrap(try RawStorage.read(for: now).first)
        let att = try XCTUnwrap(saved.attachments.first)
        XCTAssertNil(att.duration, "A missing duration must round-trip as nil, not crash or default")
        XCTAssertEqual(att.transcriptionStatus, .pending)
    }

    /// The memo must be tagged so it's distinguishable from phone captures.
    func testAppendVoiceMemo_taggedAsAppleWatch() throws {
        let now = Date()
        WatchReceiveService.appendVoiceMemo(audioPath: "raw/assets/watch_x.m4a", duration: 3, created: now)
        let saved = try XCTUnwrap(try RawStorage.read(for: now).first)
        XCTAssertEqual(saved.device, "Apple Watch", "Watch-sourced memos must be tagged for provenance")
    }

    /// A transcript written back through the queue's applyTranscript path must
    /// land on the appended attachment — proving the end-to-end shape works:
    /// append (pending) → applyTranscript (done). This is the exact failure the
    /// bug caused (no attachment to match) inverted into a passing assertion.
    func testAppendedMemo_canReceiveTranscriptWriteback() throws {
        let now = Date()
        let audioPath = "raw/assets/watch_writeback.m4a"
        WatchReceiveService.appendVoiceMemo(audioPath: audioPath, duration: 5, created: now)

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        let memoDate = f.string(from: now)

        let matched = VoiceAttachmentQueue.applyTranscript(
            transcript: "hello from the watch",
            audioPath: audioPath,
            memoDate: memoDate
        )
        XCTAssertTrue(matched, "applyTranscript must find the appended attachment by audioPath")

        let saved = try XCTUnwrap(try RawStorage.read(for: now).first)
        let att = try XCTUnwrap(saved.attachments.first)
        XCTAssertEqual(att.transcript, "hello from the watch")
        XCTAssertEqual(att.transcriptionStatus, .done)
    }
}
