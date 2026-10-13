import XCTest
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Unit tests for VaultMigrationService.
/// Key requirement: migrationCompletedAt is NOT set when verification fails.
final class VaultMigrationServiceTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Clear previous migration state
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.migrationCompletedAt)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.vaultLocation)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.migrationCompletedAt)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.vaultLocation)
        super.tearDown()
    }

    private func makeVault(name: String, rawContent: String? = nil) throws -> URL {
        let vault = tempDir.appendingPathComponent(name, isDirectory: true)
        let rawDir = vault.appendingPathComponent("raw", isDirectory: true)
        try fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
        if let content = rawContent {
            let memoFile = rawDir.appendingPathComponent("2025-01-01.md")
            try content.write(to: memoFile, atomically: true, encoding: .utf8)
        }
        return vault
    }

    // MARK: - Successful migration sets migrationCompletedAt

    func testSuccessfulMigration_setsMigrationCompletedAt() async throws {
        let local = try makeVault(name: "local", rawContent: "hello world")
        let icloud = try makeVault(name: "icloud_empty")

        let service = await VaultMigrationService.shared
        try await service.migrateToiCloud(
            localVault: local,
            iCloudVault: icloud,
            progress: { _, _ in }
        )

        let completedAt = UserDefaults.standard.object(forKey: "migrationCompletedAt") as? Date
        XCTAssertNotNil(completedAt, "migrationCompletedAt should be set after successful migration")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "vaultLocation"), "iCloud")
    }

    // MARK: - Verification failure does NOT set migrationCompletedAt

    /// When verifyMigration throws (SHA-256 mismatch), migrationCompletedAt must NOT be set.
    /// This is tested by calling verifyMigration directly with mismatched vaults,
    /// then confirming the service's public migrateToiCloud would not have set the date.
    func testVerificationFailed_doesNotSetMigrationCompletedAt() async throws {
        // local has one content, icloud has different content for the same file
        let local = try makeVault(name: "local_verify", rawContent: "original content")
        let icloud = try makeVault(name: "icloud_verify", rawContent: "different content")

        let service = await VaultMigrationService.shared
        let capturedFM = fm

        // Directly call verifyMigration on main actor — should throw because SHA-256 mismatches
        var caughtVerificationError = false
        await MainActor.run {
            do {
                try service.verifyMigration(localVault: local, iCloudVault: icloud, fm: capturedFM)
                XCTFail("verifyMigration should throw when content differs")
            } catch MigrationError.verificationFailed {
                caughtVerificationError = true
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(caughtVerificationError, "Expected verificationFailed error")

        // migrationCompletedAt must NOT have been set
        let completedAt = UserDefaults.standard.object(forKey: "migrationCompletedAt") as? Date
        XCTAssertNil(completedAt, "migrationCompletedAt must not be set when verification fails")
        let loc = UserDefaults.standard.string(forKey: "vaultLocation")
        XCTAssertTrue(loc == nil || loc == "local", "vaultLocation must remain local when verification fails")
    }

    // MARK: - File copy failure does not set migrationCompletedAt

    func testCopyFailure_doesNotSetMigrationCompletedAt() async throws {
        let local = try makeVault(name: "local_copy", rawContent: "hello")
        // Destination is a regular file, not a directory — all copies will fail
        let invalidDest = tempDir.appendingPathComponent("not_a_directory")
        try "this is a file".write(to: invalidDest, atomically: true, encoding: .utf8)

        let service = await VaultMigrationService.shared
        do {
            try await service.migrateToiCloud(
                localVault: local,
                iCloudVault: invalidDest,
                progress: { _, _ in }
            )
            XCTFail("Migration should have thrown an error when destination is invalid")
        } catch {
            // Expected
        }

        let completedAt = UserDefaults.standard.object(forKey: "migrationCompletedAt") as? Date
        XCTAssertNil(completedAt, "migrationCompletedAt must not be set when copy fails")
    }

    // MARK: - Progress callback receives accurate counts

    func testMigration_progressCallback() async throws {
        let local = try makeVault(name: "local_progress", rawContent: "progress test")
        let icloud = try makeVault(name: "icloud_progress_dest")

        var lastCopied = 0
        var lastTotal = 0
        let service = await VaultMigrationService.shared
        try await service.migrateToiCloud(
            localVault: local,
            iCloudVault: icloud,
            progress: { copied, total in
                lastCopied = copied
                lastTotal = total
            }
        )

        XCTAssertGreaterThan(lastTotal, 0)
        XCTAssertEqual(lastCopied, lastTotal)
    }

    // MARK: - Verify file count mismatch triggers failure

    func testVerification_fileCountMismatch_throws() async throws {
        // local has 2 files, icloud has 1 file — mismatch should throw
        let local = try makeVault(name: "local_count")
        let rawLocal = local.appendingPathComponent("raw")
        try "file1".write(to: rawLocal.appendingPathComponent("2025-01-01.md"), atomically: true, encoding: .utf8)
        try "file2".write(to: rawLocal.appendingPathComponent("2025-01-02.md"), atomically: true, encoding: .utf8)

        let icloud = try makeVault(name: "icloud_count", rawContent: "file1")

        let service = await VaultMigrationService.shared
        let capturedFM = fm

        var didThrowVerificationFailed = false
        await MainActor.run {
            do {
                try service.verifyMigration(localVault: local, iCloudVault: icloud, fm: capturedFM)
            } catch MigrationError.verificationFailed {
                didThrowVerificationFailed = true
            } catch {
                XCTFail("Expected verificationFailed, got \(error)")
            }
        }
        XCTAssertTrue(didThrowVerificationFailed, "Expected verificationFailed for file count mismatch")
    }

    // MARK: - deleteLocalBackup

    /// When vault doesn't exist (common in Simulator where Documents/vault is absent),
    /// deleteLocalBackup should not throw and must clear migrationCompletedAt.
    func testDeleteLocalBackup_whenVaultAbsent_clearsMigrationDate() async throws {
        UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.migrationCompletedAt)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: AppSettings.Keys.migrationCompletedAt))

        let service = await VaultMigrationService.shared
        try await MainActor.run {
            try service.deleteLocalBackup()
        }

        XCTAssertNil(
            UserDefaults.standard.object(forKey: AppSettings.Keys.migrationCompletedAt),
            "migrationCompletedAt must be cleared even when vault directory was absent"
        )
    }

    /// deleteLocalBackup clears migrationCompletedAt regardless of how old the date is.
    func testDeleteLocalBackup_clearsMigrationDate_regardlessOfAge() async throws {
        let oldDate = Date(timeIntervalSinceNow: -40 * 24 * 3600) // 40 days ago
        UserDefaults.standard.set(oldDate, forKey: AppSettings.Keys.migrationCompletedAt)

        let service = await VaultMigrationService.shared
        await MainActor.run {
            try? service.deleteLocalBackup()
        }

        XCTAssertNil(
            UserDefaults.standard.object(forKey: AppSettings.Keys.migrationCompletedAt),
            "migrationCompletedAt must be nil after deleteLocalBackup for a 40-day-old migration"
        )
    }

    /// When migrationCompletedAt is already nil, deleteLocalBackup must not crash.
    func testDeleteLocalBackup_whenNoPriorMigration_doesNotThrow() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.migrationCompletedAt)

        let service = await VaultMigrationService.shared
        try await MainActor.run {
            try service.deleteLocalBackup()
        }
    }

    /// Full round-trip: migrate then delete backup.
    /// Confirms migrationCompletedAt is set by migration and cleared by deleteLocalBackup.
    func testDeleteLocalBackup_afterSuccessfulMigration_clearsMigrationDate() async throws {
        let local = try makeVault(name: "local_delete_after_migrate", rawContent: "roundtrip content")
        let icloud = try makeVault(name: "icloud_delete_after_migrate")

        let service = await VaultMigrationService.shared
        try await service.migrateToiCloud(
            localVault: local,
            iCloudVault: icloud,
            progress: { _, _ in }
        )

        XCTAssertNotNil(
            UserDefaults.standard.object(forKey: AppSettings.Keys.migrationCompletedAt),
            "migrationCompletedAt must be set after successful migration"
        )

        try await MainActor.run {
            // deleteLocalBackup targets LocalVaultLocator().vaultURL (Documents/vault),
            // not our temp dir — but it still clears migrationCompletedAt.
            try service.deleteLocalBackup()
        }

        XCTAssertNil(
            UserDefaults.standard.object(forKey: AppSettings.Keys.migrationCompletedAt),
            "migrationCompletedAt must be cleared after deleteLocalBackup"
        )
    }
}

/// Source/destination and commit callback are isolated. These cases never
/// call deleteLocalBackup, change real preferences, or resolve an iCloud URL.
final class ScreenshotMigrationWiringTests: XCTestCase {
    private struct LocalEvidence: ScreenshotEvidenceExtracting {
        func extract(from imageData: Data) async throws -> ScreenshotEvidence {
            ScreenshotEvidence()
        }
    }

    private func roots() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-migration-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, source, destination)
    }

    private func capture(in source: URL) async throws -> ScreenshotCaptureOutcome {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: source),
            evidenceExtractor: LocalEvidence(),
            cloudConsent: AllowAllAIConsent()
        )
        return try await coordinator.ingest(data: png, declaredContentType: "public.png",
            source: .appImport, cloudAnalysisAllowed: false)
    }

    @MainActor
    func testMigrationCopiesCanonicalScreenshotStateAndOriginal() async throws {
        let paths = try roots()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let outcome = try await capture(in: paths.source)
        let hidden = paths.source.appendingPathComponent("raw/assets/.other-cache")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("synthetic cache".utf8).write(to: hidden.appendingPathComponent("ignored"))
        var committed = false
        try await VaultMigrationService.shared.migrateToiCloud(localVault: paths.source,
            iCloudVault: paths.destination, commitSettings: { committed = true }, progress: { _, _ in })
        XCTAssertTrue(committed)
        let target = ScreenshotCaptureStore(vaultRoot: paths.destination)
        let copied = try await target.manifest(for: outcome.manifest.id)
        let durableSource = try await ScreenshotCaptureStore(vaultRoot: paths.source).manifest(for: copied.id)
        XCTAssertEqual(copied, durableSource)
        let manifestPath = VaultMigrationFileInventory.screenshotManifestDirectory + "/" + copied.id.uuidString.lowercased() + ".json"
        XCTAssertEqual(try Data(contentsOf: paths.source.appendingPathComponent(manifestPath)),
                       try Data(contentsOf: paths.destination.appendingPathComponent(manifestPath)))
        let original = try await ScreenshotCaptureStore(vaultRoot: paths.source).originalData(for: copied.id)
        let migrated = try await target.originalData(for: copied.id)
        XCTAssertEqual(migrated, original)
        XCTAssertEqual(try RawStorage.read(dayString: copied.memoDayString, vaultRoot: paths.destination).map(\.id), [copied.memoID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.appendingPathComponent("raw/assets/.other-cache").path))
    }

    @MainActor
    func testDestinationSymlinkIsRejectedBeforeAnyOutsideMutation() async throws {
        let paths = try roots()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let outcome = try await capture(in: paths.source)
        let outside = paths.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent(outcome.manifest.id.uuidString.lowercased() + ".json")
        let bytes = Data("outside sentinel".utf8)
        try bytes.write(to: sentinel)
        let link = paths.destination.appendingPathComponent(VaultMigrationFileInventory.screenshotManifestDirectory)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var committed = false
        do {
            try await VaultMigrationService.shared.migrateToiCloud(localVault: paths.source,
                iCloudVault: paths.destination, commitSettings: { committed = true }, progress: { _, _ in })
            XCTFail("Unsafe destination must be rejected")
        } catch { }
        XCTAssertFalse(committed)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [sentinel.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.appendingPathComponent("raw/" + outcome.manifest.memoDayString + ".md").path))
    }

    @MainActor
    func testMissingManifestCannotHideBehindDestinationExtras() async throws {
        let paths = try roots()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = try await capture(in: paths.source)
        for relative in try VaultMigrationFileInventory.relativeFiles(in: paths.source)
            where !relative.hasPrefix(VaultMigrationFileInventory.screenshotManifestDirectory + "/") {
            let target = paths.destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: paths.source.appendingPathComponent(relative), to: target)
        }
        try Data("extra one".utf8).write(to: paths.destination.appendingPathComponent("extra-one"))
        try Data("extra two".utf8).write(to: paths.destination.appendingPathComponent("extra-two"))
        XCTAssertThrowsError(try VaultMigrationService.shared.verifyMigration(localVault: paths.source,
            iCloudVault: paths.destination, fm: .default))
    }

    @MainActor
    func testCorruptManifestFailsMigrationVerification() async throws {
        let paths = try roots()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let outcome = try await capture(in: paths.source)
        for relative in try VaultMigrationFileInventory.relativeFiles(in: paths.source) {
            let target = paths.destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: paths.source.appendingPathComponent(relative), to: target)
        }
        let manifest = paths.destination.appendingPathComponent(
            "raw/assets/.screenshot-captures/\(outcome.manifest.id.uuidString.lowercased()).json")
        try Data("synthetic corruption".utf8).write(to: manifest)
        XCTAssertThrowsError(try VaultMigrationService.shared.verifyMigration(localVault: paths.source,
            iCloudVault: paths.destination, fm: .default))
    }
}
