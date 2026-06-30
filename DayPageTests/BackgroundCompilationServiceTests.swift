import XCTest
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Tests for the BackgroundCompilationService state machine — issue #32.
///
/// Only the pure, vault-aware decision functions are exercised here:
///
///   • `shouldCompile(for:)` — the gate every entry point (BGAppRefreshTask
///     handler and foreground backfill) consults to decide whether a given
///     day needs work. The BGTask plumbing itself can only run in an iOS
///     foreground test host with a registered task identifier, so we test
///     the gate, not the scheduler.
///
///   • `foregroundRetryDelays` / `backgroundRetryDelays` — pinned so that a
///     future contributor cannot accidentally swap an aggressive foreground
///     schedule into the BGTask path (which has a ~30s budget).
final class BackgroundCompilationServiceTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default
    private var rawDir: URL { tempDir.appendingPathComponent("raw", isDirectory: true) }
    private var dailyDir: URL {
        tempDir.appendingPathComponent("wiki/daily", isDirectory: true)
    }
    private let dayString = "2026-02-14"
    private var date: Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f.date(from: dayString)!
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("BGCompileTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - shouldCompile

    @MainActor
    func testShouldCompile_returnsFalse_whenNoRawFile() {
        XCTAssertFalse(BackgroundCompilationService.shared.shouldCompile(for: date),
            "Without a raw memo file we have nothing to compile")
    }

    @MainActor
    func testShouldCompile_returnsTrue_whenRawFileExistsAndDailyDoesNot() throws {
        let rawFile = rawDir.appendingPathComponent("\(dayString).md")
        try "---\nid: \(UUID().uuidString)\ntype: text\ncreated: 2026-02-14T08:00:00.000Z\nentity_mentions: []\nattachments: []\n---\n\nhello".write(to: rawFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(BackgroundCompilationService.shared.shouldCompile(for: date))
    }

    @MainActor
    func testShouldCompile_returnsFalse_whenDailyAlreadyExists() throws {
        let rawFile = rawDir.appendingPathComponent("\(dayString).md")
        try "raw content".write(to: rawFile, atomically: true, encoding: .utf8)
        let dailyFile = dailyDir.appendingPathComponent("\(dayString).md")
        try "compiled".write(to: dailyFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(BackgroundCompilationService.shared.shouldCompile(for: date),
            "If the Daily Page is already on disk we must not re-compile")
    }

    // MARK: - Retry schedules

    /// The background schedule must be a single 0-delay attempt — anything
    /// else exceeds the iOS BGAppRefreshTask 30s budget and the run gets
    /// killed mid-compile. Pin it.
    func testBackgroundRetryDelays_singleImmediateAttempt() {
        XCTAssertEqual(BackgroundCompilationService.backgroundRetryDelays, [0],
            "BGTask schedule must stay at a single attempt — any wait would exceed iOS budget")
    }

    /// The foreground schedule is allowed to do full exponential backoff
    /// because it runs while the app is alive. The exact values are part
    /// of the documented behaviour (UX surface) and must not regress.
    func testForegroundRetryDelays_matchDocumentedSchedule() {
        XCTAssertEqual(BackgroundCompilationService.foregroundRetryDelays, [0, 30, 120, 600],
            "Foreground backfill schedule must remain 0/30s/2m/10m")
    }
}
