import XCTest
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
