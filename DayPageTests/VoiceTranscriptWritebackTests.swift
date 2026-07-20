import XCTest
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Unit tests for VoiceAttachmentQueue.applyTranscript — covers issue #19's
/// acceptance criteria:
///   • The previous string-replace implementation never matched the actual
///     on-disk indentation, so a transcript silently failed to land.
///   • Two concurrent transcript callbacks would read-modify-write the same
///     file, with the last writer clobbering the first.
///   • Transcripts containing YAML metacharacters (quotes, backslashes,
///     newlines) corrupted the front-matter.
///
/// The new implementation parses the day file, mutates the matching
/// Memo.Attachment, and rewrites through RawStorage.rewrite, which is
/// serialized by RawStorage.writeQueue — so both writers see a coherent
/// snapshot and YAML escaping is handled by Memo.toMarkdown.
final class VoiceTranscriptWritebackTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    private let dateString = "2026-06-19"
    private var dayDate: Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f.date(from: dateString)!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("VoiceTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeVoiceMemo(audioPath: String, body: String = "") -> Memo {
        Memo(
            type: .voice,
            created: dayDate,
            attachments: [
                Memo.Attachment(
                    file: audioPath,
                    kind: "audio",
                    duration: 12.3,
                    transcript: nil,
                    transcriptionStatus: .pending
                )
            ],
            body: body
        )
    }

    private func seedDayFile(memos: [Memo]) throws {
        try RawStorage.rewrite(memos, for: dayDate)
    }

    private func readBack() throws -> [Memo] {
        try RawStorage.read(for: dayDate)
    }

    // MARK: - Single transcript

    func testApplyTranscript_setsTranscriptOnMatchingAttachment() throws {
        let memo = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a", body: "morning note")
        try seedDayFile(memos: [memo])

        let ok = VoiceAttachmentQueue.applyTranscript(
            transcript: "hello world",
            audioPath: "raw/assets/voice-a.m4a",
            memoDate: dateString
        )
        XCTAssertTrue(ok)

        let memos = try readBack()
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].attachments.first?.transcript, "hello world")
        XCTAssertEqual(memos[0].attachments.first?.transcriptionStatus, .done)
        XCTAssertEqual(memos[0].body, "morning note", "body must be preserved")
    }

    func testApplyTranscript_noMatchingAttachment_returnsFalse() throws {
        let memo = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a")
        try seedDayFile(memos: [memo])

        let ok = VoiceAttachmentQueue.applyTranscript(
            transcript: "hello",
            audioPath: "raw/assets/voice-DOES-NOT-EXIST.m4a",
            memoDate: dateString
        )
        XCTAssertFalse(ok)

        let memos = try readBack()
        XCTAssertNil(memos[0].attachments.first?.transcript)
    }

    func testApplyTranscript_invalidDate_returnsFalse() {
        let ok = VoiceAttachmentQueue.applyTranscript(
            transcript: "x",
            audioPath: "raw/assets/voice.m4a",
            memoDate: "not-a-date"
        )
        XCTAssertFalse(ok)
    }

    // MARK: - applyStatus (retry-exhaustion path, #821 + stuck-pending fix)

    /// When retries are exhausted the queue writes a bare `.failed` status so
    /// the card can downgrade from the shimmer to a retry affordance. If this
    /// silently no-ops, the card shimmers forever — the exact "一直转录中" bug.
    func testApplyStatus_writesFailedOnMatchingAttachment() throws {
        let memo = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a")
        try seedDayFile(memos: [memo])

        let ok = VoiceAttachmentQueue.applyStatus(
            .failed,
            audioPath: "raw/assets/voice-a.m4a",
            memoDate: dateString
        )
        XCTAssertTrue(ok)

        let m = try readBack().first!
        XCTAssertEqual(m.attachments.first?.transcriptionStatus, .failed,
            "status must flip to .failed so the card leaves the shimmer state")
        XCTAssertNil(m.attachments.first?.transcript, "no transcript text on a failed write")
    }

    /// The match-miss must be observable (returns false), not silent — the
    /// caller relies on this to breadcrumb instead of leaving a frozen card.
    func testApplyStatus_noMatchingAttachment_returnsFalse() throws {
        let memo = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a")
        try seedDayFile(memos: [memo])

        let ok = VoiceAttachmentQueue.applyStatus(
            .failed,
            audioPath: "raw/assets/voice-DOES-NOT-EXIST.m4a",
            memoDate: dateString
        )
        XCTAssertFalse(ok)

        // The real attachment's status is untouched — we didn't clobber it.
        let m = try readBack().first!
        XCTAssertEqual(m.attachments.first?.transcriptionStatus, .pending)
    }

    // MARK: - YAML escape safety (the prior implementation broke on these)

    func testApplyTranscript_handlesQuotesBackslashesAndNewlines() throws {
        let memo = makeVoiceMemo(audioPath: "raw/assets/voice-x.m4a")
        try seedDayFile(memos: [memo])

        let tricky = "She said \"hi\"\nback\\slash\there"
        let ok = VoiceAttachmentQueue.applyTranscript(
            transcript: tricky,
            audioPath: "raw/assets/voice-x.m4a",
            memoDate: dateString
        )
        XCTAssertTrue(ok)

        let memos = try readBack()
        XCTAssertEqual(memos[0].attachments.first?.transcript, tricky,
            "Memo.toMarkdown / fromMarkdown must round-trip quotes, backslashes, newlines and tabs")
    }

    // MARK: - Multi-memo, multi-attachment correctness

    func testApplyTranscript_targetsCorrectAttachmentAmongMany() throws {
        let memoA = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a", body: "A")
        let memoB = makeVoiceMemo(audioPath: "raw/assets/voice-b.m4a", body: "B")
        let memoC = makeVoiceMemo(audioPath: "raw/assets/voice-c.m4a", body: "C")
        try seedDayFile(memos: [memoA, memoB, memoC])

        _ = VoiceAttachmentQueue.applyTranscript(
            transcript: "for B only",
            audioPath: "raw/assets/voice-b.m4a",
            memoDate: dateString
        )

        let memos = try readBack().sorted { $0.body < $1.body }
        XCTAssertEqual(memos.map { $0.attachments.first?.transcript },
                       [nil, "for B only", nil])
    }

    // MARK: - Concurrency: the main correctness claim

    /// Two transcripts completing in the same window must both land.
    /// Pre-fix: read-modify-atomicWrite race meant the second writer
    /// overwrote the first, dropping one transcript silently.
    ///
    /// Uses concurrentPerform to drive real parallel writers off the main
    /// queue while keeping the worker count bounded — NSFileCoordinator on
    /// the simulator stalls if main thread is hammered, so we keep this
    /// test off the main queue and below the file-coordinator thrashing
    /// threshold.
    func testApplyTranscript_concurrentWritesBothLand() throws {
        let memoA = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a")
        let memoB = makeVoiceMemo(audioPath: "raw/assets/voice-b.m4a")
        try seedDayFile(memos: [memoA, memoB])

        let iterations = 20
        let captured = dateString

        let done = expectation(description: "concurrent writes")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: iterations * 2) { idx in
                let isA = idx % 2 == 0
                let pair = idx / 2
                _ = VoiceAttachmentQueue.applyTranscript(
                    transcript: isA ? "A-\(pair)" : "B-\(pair)",
                    audioPath: isA ? "raw/assets/voice-a.m4a" : "raw/assets/voice-b.m4a",
                    memoDate: captured
                )
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        let memos = try readBack()
        XCTAssertEqual(memos.count, 2, "no memo may be lost under concurrent writes")

        let transcripts = memos.compactMap { $0.attachments.first?.transcript }
        XCTAssertEqual(transcripts.count, 2, "both attachments must have a transcript")

        // Don't assert exact final value — under concurrency any iteration
        // may be the last writer per attachment. The contract is: each
        // attachment ends with SOME A-* / B-* transcript, never nil.
        XCTAssertTrue(transcripts.allSatisfy { $0.hasPrefix("A-") || $0.hasPrefix("B-") })

        // Cross-contamination check: A's attachment must never end up with
        // B's transcript and vice versa.
        for memo in memos {
            guard let att = memo.attachments.first, let t = att.transcript else { continue }
            if att.file.hasSuffix("voice-a.m4a") {
                XCTAssertTrue(t.hasPrefix("A-"), "voice-a got \(t)")
            } else if att.file.hasSuffix("voice-b.m4a") {
                XCTAssertTrue(t.hasPrefix("B-"), "voice-b got \(t)")
            }
        }
    }

    // MARK: - Front-matter integrity after rewrite

    func testApplyTranscript_preservesOtherFrontmatterFields() throws {
        var memo = makeVoiceMemo(audioPath: "raw/assets/voice-a.m4a", body: "with weather")
        memo.weather = "晴"
        memo.mood = "good"
        memo.entityMentions = ["Chiang Mai", "café"]
        memo.location = Memo.Location(name: "Home", lat: 18.787, lng: 98.993)
        try seedDayFile(memos: [memo])

        _ = VoiceAttachmentQueue.applyTranscript(
            transcript: "preserved",
            audioPath: "raw/assets/voice-a.m4a",
            memoDate: dateString
        )

        let m = try readBack().first!
        XCTAssertEqual(m.weather, "晴")
        XCTAssertEqual(m.mood, "good")
        XCTAssertEqual(m.entityMentions, ["Chiang Mai", "café"])
        XCTAssertEqual(m.location?.name, "Home")
        XCTAssertEqual(m.location?.lat, 18.787)
        XCTAssertEqual(m.attachments.first?.transcript, "preserved")
    }
}

// MARK: - RecordingSendFloorTests (#826)

/// Contract tests for the press-to-talk send floor: releases under
/// `RecordingLimits.minSendableSeconds` are accidental touches and must be
/// discarded (no memo, no transcription), regardless of audio content.
final class RecordingSendFloorTests: XCTestCase {

    /// The floor is a product decision (3s, issue #826) — a silent change
    /// here should fail loudly, not slip through a refactor.
    func testFloorIsThreeSeconds() {
        XCTAssertEqual(RecordingLimits.minSendableSeconds, 3)
    }

    func testReleasesUnderFloorAreDiscarded() {
        XCTAssertTrue(RecordingLimits.isBelowSendFloor(0))
        XCTAssertTrue(RecordingLimits.isBelowSendFloor(1))
        XCTAssertTrue(RecordingLimits.isBelowSendFloor(2))
    }

    func testReleasesAtOrOverFloorAreSent() {
        XCTAssertFalse(RecordingLimits.isBelowSendFloor(3))
        XCTAssertFalse(RecordingLimits.isBelowSendFloor(4))
        XCTAssertFalse(RecordingLimits.isBelowSendFloor(600))
    }

    /// Duration alone decides — the floor must sit below the 5:00 amber
    /// warning band so the two thresholds can never invert.
    func testFloorSitsBelowWarningBands() {
        XCTAssertLessThan(RecordingLimits.minSendableSeconds, RecordingLimits.amberThreshold)
    }
}
