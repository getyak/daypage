import Testing
import Foundation
@testable import DayPage

/// US-023: Trash TTL — files older than 7 days are deleted; recent files survive.
///
/// Serialized because all tests in this suite mutate the global
/// `VaultInitializer.testOverrideURL` — running them in parallel would let
/// one test's vault leak into another.
@Suite("TrashTTLTests", .serialized)
struct TrashTTLTests {

    private let tempDir: URL
    private let fm = FileManager.default

    init() throws {
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("TrashTTLTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    // Swift Testing has no per-test tearDown; the suite is value-typed, so each
    // test gets a fresh init(). We still need to reset the global after the
    // test finishes — see the `defer` in each @Test below.
    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
    }

    @Test func pruneTrash_deletesOldFiles() throws {
        defer { cleanup() }

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

        #expect(fm.fileExists(atPath: staleFile.path), "Stale file must exist before pruning")

        RawStorage.pruneTrashOlderThan(days: 7)

        #expect(!fm.fileExists(atPath: staleFile.path),
                "Stale file (8 days old) must be deleted by pruneTrashOlderThan(days: 7)")
    }

    @Test func pruneTrash_preservesRecentFiles() throws {
        defer { cleanup() }

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

        #expect(fm.fileExists(atPath: freshFile.path),
                "Recent file (3 days old) must NOT be deleted by pruneTrashOlderThan(days: 7)")
    }

    @Test func pruneTrash_missingDirectoryIsNoop() {
        defer { cleanup() }
        // Vault has no .trash dir at all — must not crash. #expect(throws:) does
        // the same job as XCTAssertNoThrow.
        #expect(throws: Never.self) {
            RawStorage.pruneTrashOlderThan(days: 7)
        }
    }
}
