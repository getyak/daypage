import XCTest
@testable import DayPage

/// US-023: Trash TTL — files older than 7 days are deleted; recent files survive.
final class TrashTTLTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("TrashTTLTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    func testPruneTrash_deletesOldFiles() throws {
        let trashDir = tempDir
            .appendingPathComponent("wiki/daily/.trash", isDirectory: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)

        // Create a "stale" file by writing it and backdating via attribute
        let staleFile = trashDir.appendingPathComponent("old_backup.md")
        try "old content".write(to: staleFile, atomically: true, encoding: .utf8)

        // Backdate creation date to 8 days ago
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        try fm.setAttributes(
            [.creationDate: eightDaysAgo],
            ofItemAtPath: staleFile.path
        )

        XCTAssertTrue(fm.fileExists(atPath: staleFile.path), "Stale file must exist before pruning")

        RawStorage.pruneTrashOlderThan(days: 7)

        XCTAssertFalse(fm.fileExists(atPath: staleFile.path),
                       "Stale file (8 days old) must be deleted by pruneTrashOlderThan(days: 7)")
    }

    func testPruneTrash_preservesRecentFiles() throws {
        let trashDir = tempDir
            .appendingPathComponent("wiki/daily/.trash", isDirectory: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)

        // Create a "fresh" file (3 days old)
        let freshFile = trashDir.appendingPathComponent("recent_backup.md")
        try "recent content".write(to: freshFile, atomically: true, encoding: .utf8)

        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        try fm.setAttributes(
            [.creationDate: threeDaysAgo],
            ofItemAtPath: freshFile.path
        )

        RawStorage.pruneTrashOlderThan(days: 7)

        XCTAssertTrue(fm.fileExists(atPath: freshFile.path),
                      "Recent file (3 days old) must NOT be deleted by pruneTrashOlderThan(days: 7)")
    }

    func testPruneTrash_missingDirectoryIsNoop() {
        // Vault has no .trash dir at all — must not crash.
        XCTAssertNoThrow(RawStorage.pruneTrashOlderThan(days: 7))
    }
}
