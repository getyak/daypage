import XCTest
import DayPageStorage
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

    // MARK: - Saved Daily weather and raw fallback

    func testDailyWeatherReadsSavedQuotedWeather() {
        XCTAssertEqual(DailyPageView.dailyWeather(in: "---\nweather: \"QA local clear R1\"\n---\nBody"), "QA local clear R1")
        XCTAssertEqual(DailyPageView.dailyWeather(in: "---\nweather: Sunny 28°C\n---\nBody"), "Sunny 28°C")
    }

    func testDailyWeatherIgnoresNarrativeAndNestedFields() {
        for content in [
            "Body\nweather: Narrative",
            "---\nsummary: Day\n---\nweather: Narrative",
            "---\nmetadata:\n  weather: Nested\n---\nBody",
            "---\nmetadata:\n\tweather: Nested\n---\nBody"
        ] {
            XCTAssertEqual(DailyPageView.dailyWeather(in: content), "", content)
        }
    }

    func testDailyWeatherRejectsUnclosedFrontmatter() {
        XCTAssertEqual(DailyPageView.dailyWeather(in: "---\nweather: Sunny\nBody"), "")
    }

    func testDailyWeatherEmptyValuesAllowFallback() {
        for value in ["", "   ", "\"\"", "\"   \""] {
            XCTAssertEqual(DailyPageView.dailyWeather(in: "---\nweather: \(value)\n---\nBody"), "")
        }
    }

    func testDailyWeatherOverridesRawWithoutChangingOtherTiles() throws {
        let raw = [
            MetadataGridView.Tile(label: "WEATHER", value: "28°C", sub: "Sunny"),
            MetadataGridView.Tile(label: "ENTRIES", value: "2", sub: "MEMOS"),
            MetadataGridView.Tile(label: "SPAN", value: "10:00", sub: "→ 11:00"),
            MetadataGridView.Tile(label: "KIND", value: "Text", sub: "2 text")
        ]
        let saved = DailyPageView.dailyWeather(in: "---\nweather: \"QA local clear R2\"\n---\nBody")
        let result = try XCTUnwrap(DayDetailView.applyingDailyWeather(saved, to: raw))
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].value, "QA local clear R2")
        XCTAssertNil(result[0].sub)
        for i in 1..<raw.count {
            XCTAssertEqual(result[i].label, raw[i].label)
            XCTAssertEqual(result[i].value, raw[i].value)
            XCTAssertEqual(result[i].sub, raw[i].sub)
        }
        XCTAssertEqual(raw[0].value, "28°C")
        XCTAssertEqual(raw[0].sub, "Sunny")
    }

    func testDailyWeatherBlankUsesRawFallback() throws {
        let raw = [MetadataGridView.Tile(label: "WEATHER", value: "24°C", sub: "Rain")]
        for daily in [nil, "", " \t\n"] as [String?] {
            let result = try XCTUnwrap(DayDetailView.applyingDailyWeather(daily, to: raw))
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].value, "24°C")
            XCTAssertEqual(result[0].sub, "Rain")
        }
    }

    func testDailyWeatherTemperatureUsesExistingCompactFormat() throws {
        let result = try XCTUnwrap(DayDetailView.applyingDailyWeather(" Cloudy 19°C ", to: nil))
        XCTAssertEqual(result[0].value, "19°C")
        XCTAssertEqual(result[0].sub, "Cloudy")
    }

    func testDailyWeatherWithoutRawDoesNotInventStatistics() throws {
        let result = try XCTUnwrap(DayDetailView.applyingDailyWeather("Clear", to: nil))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].label, "WEATHER")
        XCTAssertEqual(result[0].value, "Clear")
        XCTAssertNil(DayDetailView.applyingDailyWeather("", to: nil))
    }

    func testCompiledStateUnreadableDailyKeepsFileExistenceContract() throws {
        let day = "2025-06-15"
        let daily = tempVaultURL.appendingPathComponent("wiki/daily/\(day).md")
        try Data([0xff, 0xfe, 0xff]).write(to: daily)
        try "raw".write(to: tempVaultURL.appendingPathComponent("raw/\(day).md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try String(contentsOf: daily, encoding: .utf8))
        let (state, hasRaw) = DayDetailView.resolveLoadState(dateString: day, vaultURL: tempVaultURL, fileManager: .default)
        XCTAssertEqual(state, .compiled)
        XCTAssertTrue(hasRaw)
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
        let expected = String(format: NSLocalizedString("daydetail.error.badFormat", comment: ""), "abc")
        XCTAssertEqual(message, expected, "Got message: \(message)")
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
        let expected = String(format: NSLocalizedString("daydetail.error.notFound", comment: ""), "2020-02-30")
        XCTAssertEqual(message, expected, "Got message: \(message)")
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

    // MARK: - Day paging (steppedDate)

    func testSteppedDate_forwardAndBackward_simpleDay() {
        XCTAssertEqual(DayDetailView.steppedDate(from: "2025-06-15", forward: true), "2025-06-16")
        XCTAssertEqual(DayDetailView.steppedDate(from: "2025-06-15", forward: false), "2025-06-14")
    }

    func testSteppedDate_rollsOverMonthBoundary() {
        // End of a 30-day month forward, and first-of-month backward.
        XCTAssertEqual(DayDetailView.steppedDate(from: "2025-06-30", forward: true), "2025-07-01")
        XCTAssertEqual(DayDetailView.steppedDate(from: "2025-07-01", forward: false), "2025-06-30")
    }

    func testSteppedDate_rollsOverYearBoundary() {
        XCTAssertEqual(DayDetailView.steppedDate(from: "2025-12-31", forward: true), "2026-01-01")
        XCTAssertEqual(DayDetailView.steppedDate(from: "2026-01-01", forward: false), "2025-12-31")
    }

    func testSteppedDate_handlesLeapDay() {
        // 2024 is a leap year — Feb 29 exists.
        XCTAssertEqual(DayDetailView.steppedDate(from: "2024-02-28", forward: true), "2024-02-29")
        XCTAssertEqual(DayDetailView.steppedDate(from: "2024-03-01", forward: false), "2024-02-29")
        // 2025 is not — Feb 28 rolls straight to Mar 1.
        XCTAssertEqual(DayDetailView.steppedDate(from: "2025-02-28", forward: true), "2025-03-01")
    }

    func testSteppedDate_forwardCapStopsAtBound() {
        // Stepping onto the cap itself is allowed (inclusive)…
        XCTAssertEqual(
            DayDetailView.steppedDate(from: "2026-06-08", forward: true, notAfter: "2026-06-09"),
            "2026-06-09"
        )
        // …but stepping past it returns nil so the caller halts at the boundary.
        XCTAssertNil(DayDetailView.steppedDate(from: "2026-06-09", forward: true, notAfter: "2026-06-09"))
    }

    func testSteppedDate_backwardIgnoresForwardCap() {
        // A nil cap (the backward case) never blocks.
        XCTAssertEqual(
            DayDetailView.steppedDate(from: "2026-06-09", forward: false, notAfter: nil),
            "2026-06-08"
        )
    }

    func testSteppedDate_returnsNilForUnparseableInput() {
        XCTAssertNil(DayDetailView.steppedDate(from: "not-a-date", forward: true))
        XCTAssertNil(DayDetailView.steppedDate(from: "", forward: false))
    }
}
