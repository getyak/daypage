import XCTest
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Tests for OrphanedVoiceScanner — issue #21.
///
/// Three classes of behavior covered:
///   1. findOrphans: correctly classifies referenced vs unreferenced voice files
///   2. runStartupScan: deletes stale orphans, retains recent ones
///   3. Safety: corrupt day files do not cause referenced recordings to be
///      misclassified as orphans (which would silently delete user data)
final class OrphanedVoiceScannerTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    private var assetsDir: URL {
        tempDir.appendingPathComponent("raw/assets", isDirectory: true)
    }
    private var rawDir: URL {
        tempDir.appendingPathComponent("raw", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("OrphanedVoiceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeVoiceFile(named name: String, modifiedAgo seconds: TimeInterval) throws -> URL {
        let url = assetsDir.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        let modified = Date().addingTimeInterval(-seconds)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func writeMemoFile(dateString: String, audioRelativePath: String?) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        guard let date = f.date(from: dateString) else {
            XCTFail("bad date \(dateString)"); return
        }
        let attachments: [Memo.Attachment]
        if let path = audioRelativePath {
            attachments = [
                Memo.Attachment(file: path, kind: "audio", duration: 5, transcript: nil, transcriptionStatus: .done)
            ]
        } else {
            attachments = []
        }
        let memo = Memo(type: .voice, created: date, attachments: attachments, body: "test memo")
        try RawStorage.rewrite([memo], for: date)
    }

    // MARK: - findOrphans

    func testFindOrphans_returnsEmpty_whenAssetsDirectoryMissing() throws {
        try fm.removeItem(at: assetsDir)
        let orphans = try OrphanedVoiceScanner.findOrphans()
        XCTAssertEqual(orphans, [])
    }

    func testFindOrphans_returnsEmpty_whenAllVoiceFilesReferenced() throws {
        _ = try writeVoiceFile(named: "voice_20260601_120000.m4a", modifiedAgo: 60)
        try writeMemoFile(dateString: "2026-06-01", audioRelativePath: "raw/assets/voice_20260601_120000.m4a")

        let orphans = try OrphanedVoiceScanner.findOrphans()
        XCTAssertTrue(orphans.isEmpty)
    }

    func testFindOrphans_findsUnreferencedFile() throws {
        let orphanURL = try writeVoiceFile(named: "voice_20260601_120000.m4a", modifiedAgo: 60)
        // No memo references it.

        let orphans = try OrphanedVoiceScanner.findOrphans()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.url.lastPathComponent, orphanURL.lastPathComponent)
    }

    func testFindOrphans_ignoresNonVoicePrefixedFiles() throws {
        // IMG_*.jpg in the same directory must not be considered.
        _ = try writeVoiceFile(named: "IMG_20260601_120000.jpg", modifiedAgo: 60)
        _ = try writeVoiceFile(named: "voice_20260601_120000.m4a", modifiedAgo: 60)

        let orphans = try OrphanedVoiceScanner.findOrphans()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.url.lastPathComponent, "voice_20260601_120000.m4a")
    }

    func testFindOrphans_sortedNewestFirst() throws {
        let old = try writeVoiceFile(named: "voice_old.m4a", modifiedAgo: 3600 * 5)
        let new = try writeVoiceFile(named: "voice_new.m4a", modifiedAgo: 60)
        _ = old

        let orphans = try OrphanedVoiceScanner.findOrphans()
        XCTAssertEqual(orphans.map { $0.url.lastPathComponent },
                       [new.lastPathComponent, old.lastPathComponent])
    }

    // MARK: - runStartupScan

    func testStartupScan_deletesStaleOrphan_andRetainsRecent() throws {
        let stale = try writeVoiceFile(named: "voice_stale.m4a", modifiedAgo: 48 * 3600) // 48h
        let recent = try writeVoiceFile(named: "voice_recent.m4a", modifiedAgo: 60)       // 1m

        let result = OrphanedVoiceScanner.runStartupScan()
        XCTAssertEqual(result.deletedStale, 1)
        XCTAssertEqual(result.retainedRecent, 1)
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "stale orphan must be deleted")
        XCTAssertTrue(fm.fileExists(atPath: recent.path), "recent orphan must be retained")
    }

    func testStartupScan_doesNotDeleteReferencedFile_evenIfOld() throws {
        // A 48h-old voice file that IS referenced by a memo must never be
        // deleted. This is the safety-critical guarantee.
        let referenced = try writeVoiceFile(named: "voice_20260101_120000.m4a", modifiedAgo: 48 * 3600)
        try writeMemoFile(dateString: "2026-01-01", audioRelativePath: "raw/assets/voice_20260101_120000.m4a")

        let result = OrphanedVoiceScanner.runStartupScan()
        XCTAssertEqual(result.deletedStale, 0)
        XCTAssertTrue(fm.fileExists(atPath: referenced.path),
            "referenced voice files must never be garbage-collected")
    }

    func testStartupScan_emptyVault_returnsZeros() {
        let result = OrphanedVoiceScanner.runStartupScan()
        XCTAssertEqual(result.deletedStale, 0)
        XCTAssertEqual(result.retainedRecent, 0)
    }

    // MARK: - Corrupt day-file safety

    func testFindOrphans_corruptDayFile_doesNotMisclassifyOtherReferences() throws {
        // Scenario: day file A has a referenced voice file but is corrupt.
        // Day file B has another referenced voice file and parses cleanly.
        // Both voice files must be considered referenced — we must not let A's
        // parse failure cause B's referenced file to be misclassified as
        // orphan and deleted on a later GC pass.
        let referencedFromB = try writeVoiceFile(named: "voice_b.m4a", modifiedAgo: 48 * 3600)
        try writeMemoFile(dateString: "2026-02-02", audioRelativePath: "raw/assets/voice_b.m4a")

        // Write a deliberately broken day file referencing voice_a.m4a.
        _ = try writeVoiceFile(named: "voice_a.m4a", modifiedAgo: 48 * 3600)
        let badDay = rawDir.appendingPathComponent("2026-02-01.md")
        try "not-a-valid-frontmatter\n{{{ garbage }}}".data(using: .utf8)!.write(to: badDay)

        let orphans = try OrphanedVoiceScanner.findOrphans()

        // voice_b must be excluded (because day B parsed and referenced it).
        // voice_a may be reported as orphan (the corrupt day couldn't be parsed),
        // but voice_b — the file genuinely referenced by a healthy memo —
        // MUST NOT be deleted by a subsequent GC.
        XCTAssertFalse(orphans.contains(where: { $0.url.lastPathComponent == "voice_b.m4a" }),
            "a corrupt day file must not cause referenced voice files from other days to be reported as orphans")
        XCTAssertTrue(fm.fileExists(atPath: referencedFromB.path))
    }
}
