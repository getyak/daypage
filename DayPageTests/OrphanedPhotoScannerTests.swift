import XCTest
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Tests for OrphanedPhotoScanner — mirrors OrphanedVoiceScannerTests.
///
/// Covers:
///   1. findOrphans: correctly classifies referenced vs unreferenced photo files
///   2. runStartupScan: deletes stale orphans, retains recent ones
///   3. Memo deletion produces orphans (the original C5 leak scenario)
final class OrphanedPhotoScannerTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    private var assetsDir: URL {
        tempDir.appendingPathComponent("raw/assets", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("OrphanedPhotoTests-\(UUID().uuidString)", isDirectory: true)
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

    private func writePhotoFile(named name: String, modifiedAgo seconds: TimeInterval) throws -> URL {
        let url = assetsDir.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        let modified = Date().addingTimeInterval(-seconds)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func writeMemoFile(dateString: String, photoRelativePath: String?) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        guard let date = f.date(from: dateString) else {
            XCTFail("bad date \(dateString)"); return
        }
        let attachments: [Memo.Attachment]
        if let path = photoRelativePath {
            attachments = [
                Memo.Attachment(file: path, kind: "photo", duration: nil, transcript: nil, transcriptionStatus: nil)
            ]
        } else {
            attachments = []
        }
        let memo = Memo(type: .photo, created: date, attachments: attachments, body: "test photo memo")
        try RawStorage.rewrite([memo], for: date)
    }

    // MARK: - findOrphans

    func testFindOrphans_returnsEmpty_whenAssetsDirectoryMissing() throws {
        try fm.removeItem(at: assetsDir)
        let orphans = try OrphanedPhotoScanner.findOrphans()
        XCTAssertEqual(orphans, [])
    }

    func testFindOrphans_returnsEmpty_whenNoPhotoFiles() throws {
        let orphans = try OrphanedPhotoScanner.findOrphans()
        XCTAssertEqual(orphans, [])
    }

    func testFindOrphans_classifiesUnreferencedJPGAsOrphan() throws {
        _ = try writePhotoFile(named: "IMG_20260620_120000.jpg", modifiedAgo: 60)
        let orphans = try OrphanedPhotoScanner.findOrphans()
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans[0].url.lastPathComponent, "IMG_20260620_120000.jpg")
    }

    func testFindOrphans_excludesReferencedPhoto() throws {
        let filename = "IMG_20260620_120000.jpg"
        _ = try writePhotoFile(named: filename, modifiedAgo: 60)
        try writeMemoFile(dateString: "2026-06-20", photoRelativePath: "raw/assets/\(filename)")
        let orphans = try OrphanedPhotoScanner.findOrphans()
        XCTAssertEqual(orphans, [], "Referenced photo must not be classified as orphan")
    }

    func testFindOrphans_excludesNonPhotoFiles() throws {
        // Voice file under same assets dir — must be ignored by the photo scanner.
        _ = try writePhotoFile(named: "voice_20260620_120000.m4a", modifiedAgo: 60)
        let orphans = try OrphanedPhotoScanner.findOrphans()
        XCTAssertEqual(orphans, [])
    }

    // MARK: - runStartupScan

    func testRunStartupScan_deletesStaleOrphan() throws {
        let url = try writePhotoFile(named: "IMG_20260101_100000.jpg",
                                     modifiedAgo: 48 * 3600)
        let result = OrphanedPhotoScanner.runStartupScan()
        XCTAssertEqual(result.deletedStale, 1)
        XCTAssertEqual(result.retainedRecent, 0)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testRunStartupScan_retainsRecentOrphan() throws {
        let url = try writePhotoFile(named: "IMG_20260620_100000.jpg",
                                     modifiedAgo: 60)
        let result = OrphanedPhotoScanner.runStartupScan()
        XCTAssertEqual(result.deletedStale, 0)
        XCTAssertEqual(result.retainedRecent, 1)
        XCTAssertTrue(fm.fileExists(atPath: url.path),
                      "Recent orphan must survive so a future recovery UI can surface it")
    }

    // MARK: - Regression for the C5 leak

    func testMemoDeletion_leavesOrphan_thatScannerCleansLater() throws {
        // Reproduce C5: memo with a photo gets deleted from the day file
        // without touching the asset.
        let filename = "IMG_20260619_153012.jpg"
        let url = try writePhotoFile(named: filename, modifiedAgo: 48 * 3600)
        try writeMemoFile(dateString: "2026-06-19", photoRelativePath: "raw/assets/\(filename)")

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        let date = f.date(from: "2026-06-19")!
        try RawStorage.rewrite([], for: date)

        let result = OrphanedPhotoScanner.runStartupScan()
        XCTAssertEqual(result.deletedStale, 1)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }
}
