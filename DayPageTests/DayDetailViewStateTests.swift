import XCTest
@testable import DayPage

/// Covers the 4 LoadState outcomes + 1 vault-corruption path for DayDetailView.
/// Each test mounts a disposable temp directory as the vault root via
/// `VaultInitializer.testOverrideURL`, then calls the pure resolver
/// `DayDetailView.resolveLoadState(...)` — no SwiftUI needed.
final class DayDetailViewStateTests: XCTestCase {

    private var tempVaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("wiki/daily", isDirectory: true),
            withIntermediateDirectories: true
        )
        tempVaultURL = root
        VaultInitializer.testOverrideURL = root
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let url = tempVaultURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempVaultURL = nil
        try super.tearDownWithError()
    }

    // MARK: - .empty

    func testEmptyState_whenNoFilesExist() {
        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "2020-01-01",
            vaultURL: tempVaultURL,
            fileManager: .default
        )
        XCTAssertEqual(state, .empty)
        XCTAssertFalse(hasRaw)
    }

    // MARK: - .error (invalid dateString format)

    func testErrorState_whenDateStringIsInvalidFormat() {
        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "abc",
            vaultURL: tempVaultURL,
            fileManager: .default
        )
        XCTAssertFalse(hasRaw)
        guard case .error(let message) = state else {
            return XCTFail("Expected .error, got \(state)")
        }
        XCTAssertTrue(message.contains("日期格式无效"), "Got message: \(message)")
    }

    func testErrorState_whenDateStringIsCalendarInvalid() {
        // Passes the regex (\d{4}-\d{2}-\d{2}) but February 30 does not exist.
        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "2020-02-30",
            vaultURL: tempVaultURL,
            fileManager: .default
        )
        XCTAssertFalse(hasRaw)
        guard case .error(let message) = state else {
            return XCTFail("Expected .error, got \(state)")
        }
        XCTAssertTrue(message.contains("日期不存在"), "Got message: \(message)")
    }

    // MARK: - .rawOnly

    func testRawOnlyState_whenOnlyRawFileExists() throws {
        let raw = tempVaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("2025-06-15.md")
        try "mock raw content".write(to: raw, atomically: true, encoding: .utf8)

        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "2025-06-15",
            vaultURL: tempVaultURL,
            fileManager: .default
        )
        XCTAssertEqual(state, .rawOnly)
        XCTAssertTrue(hasRaw)
    }

    // MARK: - .compiled

    func testCompiledState_whenBothRawAndDailyExist() throws {
        let raw = tempVaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("2025-07-20.md")
        let daily = tempVaultURL
            .appendingPathComponent("wiki/daily")
            .appendingPathComponent("2025-07-20.md")
        try "mock raw".write(to: raw, atomically: true, encoding: .utf8)
        try "mock daily".write(to: daily, atomically: true, encoding: .utf8)

        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "2025-07-20",
            vaultURL: tempVaultURL,
            fileManager: .default
        )
        XCTAssertEqual(state, .compiled)
        XCTAssertTrue(hasRaw)
    }

    func testCompiledState_whenOnlyDailyExists() throws {
        let daily = tempVaultURL
            .appendingPathComponent("wiki/daily")
            .appendingPathComponent("2025-07-21.md")
        try "mock daily".write(to: daily, atomically: true, encoding: .utf8)

        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "2025-07-21",
            vaultURL: tempVaultURL,
            fileManager: .default
        )
        XCTAssertEqual(state, .compiled)
        XCTAssertFalse(hasRaw)
    }

    // MARK: - .error (corrupted / missing vault path)

    func testErrorState_whenVaultPathIsMissing() throws {
        let bogusVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPageTests-missing-\(UUID().uuidString)", isDirectory: true)
        // Deliberately do NOT create bogusVault.

        let (state, hasRaw) = DayDetailView.resolveLoadState(
            dateString: "2025-08-10",
            vaultURL: bogusVault,
            fileManager: .default
        )
        XCTAssertFalse(hasRaw)
        guard case .error(let message) = state else {
            return XCTFail("Expected .error, got \(state)")
        }
        XCTAssertTrue(message.contains("vault unreachable"), "Got message: \(message)")
    }
}
