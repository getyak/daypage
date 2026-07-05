import XCTest
import DayPageModels
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

    // MARK: - Source-hash dedup (issue #814)

    /// Writes a raw file for `dayString`, reads it back through RawStorage
    /// (the same parse path production uses), and returns the source hash.
    @MainActor
    private func writeRawAndHash(bodies: [String]) throws -> String {
        let memos = bodies.map { Memo(type: .text, created: date, body: $0) }
        let content = memos.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
        try content.write(to: rawDir.appendingPathComponent("\(dayString).md"), atomically: true, encoding: .utf8)
        let parsed = try RawStorage.read(for: date)
        return CompilationService.sourceHash(of: parsed)
    }

    private func writeDaily(sourceHash: String?) throws {
        var frontmatter = ["---", "type: daily", "date: \(dayString)"]
        if let sourceHash { frontmatter.append("source_hash: \(sourceHash)") }
        frontmatter.append(contentsOf: ["---", "", "# \(dayString)", ""])
        try frontmatter.joined(separator: "\n")
            .write(to: dailyDir.appendingPathComponent("\(dayString).md"), atomically: true, encoding: .utf8)
    }

    /// Same memos → same hash; changing a body → different hash. Mood /
    /// entityMentions must NOT affect the hash: `applyMemoUpdates` writes
    /// those back into the raw file right after every successful compile,
    /// so hashing them would flag freshly compiled days as stale forever.
    func testSourceHash_deterministicAndMetadataExempt() {
        let id = UUID()
        let base = Memo(id: id, type: .text, created: Date(timeIntervalSince1970: 0), body: "hello")
        var moodBackfilled = base
        moodBackfilled.mood = "愉快"
        moodBackfilled.entityMentions = ["joma-coffee"]
        var edited = base
        edited.body = "hello, edited"

        XCTAssertEqual(CompilationService.sourceHash(of: [base]),
                       CompilationService.sourceHash(of: [moodBackfilled]),
            "mood/entityMentions backfill must not change the source hash")
        XCTAssertNotEqual(CompilationService.sourceHash(of: [base]),
                          CompilationService.sourceHash(of: [edited]),
            "a body edit must change the source hash")
    }

    /// Hash must be order-independent: a pin/unpin rewrite reorders the
    /// raw file without changing substance.
    func testSourceHash_orderIndependent() {
        let a = Memo(type: .text, created: Date(timeIntervalSince1970: 0), body: "a")
        let b = Memo(type: .text, created: Date(timeIntervalSince1970: 60), body: "b")
        XCTAssertEqual(CompilationService.sourceHash(of: [a, b]),
                       CompilationService.sourceHash(of: [b, a]))
    }

    func testInjectAndExtractSourceHash_roundTrip() {
        let daily = "---\ntype: daily\ndate: \(dayString)\nmood: 平静\n---\n\n# \(dayString)\n"
        let injected = CompilationService.injectSourceHash("abc123", into: daily)
        XCTAssertEqual(CompilationService.extractSourceHash(from: injected), "abc123")
        // Re-injecting replaces rather than duplicates.
        let reinjected = CompilationService.injectSourceHash("def456", into: injected)
        XCTAssertEqual(CompilationService.extractSourceHash(from: reinjected), "def456")
        XCTAssertEqual(reinjected.components(separatedBy: "source_hash:").count, 2,
            "source_hash line must appear exactly once")
        // Body must survive injection untouched.
        XCTAssertTrue(reinjected.hasSuffix("# \(dayString)\n"))
    }

    func testInjectSourceHash_noFrontmatter_returnsInputUnchanged() {
        let plain = "# no frontmatter here\n"
        XCTAssertEqual(CompilationService.injectSourceHash("abc", into: plain), plain)
        XCTAssertNil(CompilationService.extractSourceHash(from: plain))
    }

    /// daily present + matching source_hash → fresh, no recompile.
    @MainActor
    func testShouldCompile_returnsFalse_whenHashMatches() throws {
        let hash = try writeRawAndHash(bodies: ["morning note", "evening note"])
        try writeDaily(sourceHash: hash)
        XCTAssertFalse(BackgroundCompilationService.shared.shouldCompile(for: date),
            "Unchanged raw content must not trigger a recompile (LLM cost guard)")
    }

    /// daily present + stale source_hash (raw edited afterwards) → recompile.
    @MainActor
    func testShouldCompile_returnsTrue_whenRawEditedAfterCompile() throws {
        let hash = try writeRawAndHash(bodies: ["morning note"])
        try writeDaily(sourceHash: hash)
        _ = try writeRawAndHash(bodies: ["morning note", "late-night addition"])
        XCTAssertTrue(BackgroundCompilationService.shared.shouldCompile(for: date),
            "Raw edits after a compile must mark the day stale")
    }

    /// Legacy daily (compiled before #814, no source_hash) → treated as
    /// fresh so backfill never mass-recompiles history.
    @MainActor
    func testShouldCompile_returnsFalse_forLegacyDailyWithoutHash() throws {
        _ = try writeRawAndHash(bodies: ["old day"])
        try writeDaily(sourceHash: nil)
        XCTAssertFalse(BackgroundCompilationService.shared.shouldCompile(for: date),
            "Pages compiled before #814 carry no hash and must be left alone")
    }

    // MARK: - Wiki index (issue #814)

    /// Pure renderer shape check: sections, counts, link + summary lines.
    func testWikiIndex_buildIndexMarkdown_shape() {
        let markdown = WikiIndexService.buildIndexMarkdown(
            daily: [
                .init(dateString: "2026-02-14", summary: "试验日", mood: "平静"),
                .init(dateString: "2026-02-13", summary: "", mood: "")
            ],
            weekly: ["2026-W07"],
            entities: [(type: "places", slug: "test-cafe", name: "Test Cafe")],
            updatedAt: "2026-02-14T09:00:00.000Z"
        )
        XCTAssertTrue(markdown.contains("type: index"))
        XCTAssertTrue(markdown.contains("daily_count: 2"))
        XCTAssertTrue(markdown.contains("- [[wiki/daily/2026-02-14|2026-02-14]] 平静 — 试验日"))
        XCTAssertTrue(markdown.contains("- [[wiki/daily/2026-02-13|2026-02-13]]"))
        XCTAssertTrue(markdown.contains("## Weekly"))
        XCTAssertTrue(markdown.contains("- [[wiki/weekly/2026-W07|2026-W07]]"))
        XCTAssertTrue(markdown.contains("## Places"))
        XCTAssertTrue(markdown.contains("- [[wiki/places/test-cafe|Test Cafe]]"))
    }

    /// End-to-end against the temp vault: rebuild() scans daily pages and
    /// writes wiki/index.md.
    @MainActor
    func testWikiIndex_rebuild_writesIndexFromVault() throws {
        try writeDaily(sourceHash: "abc")
        WikiIndexService.shared.rebuild()
        let indexURL = tempDir.appendingPathComponent("wiki/index.md")
        let content = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- [[wiki/daily/\(dayString)|\(dayString)]]"))
        XCTAssertTrue(content.contains("daily_count: 1"))
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
