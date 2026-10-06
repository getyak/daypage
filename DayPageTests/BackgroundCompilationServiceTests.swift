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
///
///   • `isAutomaticCompileEligible` + entry-point guards (UI14 P2) — the
///     AI OFF (local-only) gate in front of the automatic backfill, foreground
///     retry, and weekly auto compile, with yesterday's raw seeded in an
///     isolated temp vault; plus the retry classifier's non-retryable
///     configuration states (`.aiDisabled`, `.missingApiKey`).
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
    func testWikiIndex_rebuild_writesIndexFromVault() async throws {
        try writeDaily(sourceHash: "abc")
        // rebuild() is fire-and-forget in production; await the returned
        // task so the assertion runs after the detached write lands.
        await WikiIndexService.shared.rebuild().value
        let indexURL = tempDir.appendingPathComponent("wiki/index.md")
        let content = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(content.contains("- [[wiki/daily/\(dayString)|\(dayString)]]"))
        XCTAssertTrue(content.contains("daily_count: 1"))
    }

    // MARK: - Retry schedules

    func testCompileStages_haveForwardMovingUserFacingProgress() {
        let activeStages = BackgroundCompilationService.CompileStage.allCases
            .filter { $0 != .idle }

        XCTAssertTrue(activeStages.allSatisfy { !$0.displayLabel.isEmpty })
        XCTAssertEqual(activeStages.map(\.progressFraction), [0.15, 0.30, 0.65, 0.85, 0.95])
        XCTAssertEqual(activeStages.map(\.progressFraction), activeStages.map(\.progressFraction).sorted())
    }

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

    func testMissingAPIKey_bypassesExponentialRetry() {
        XCTAssertFalse(
            BackgroundCompilationService.shouldRetryCompilation(after: CompilationError.missingApiKey),
            "Missing credentials must reach the actionable Settings banner immediately"
        )
        XCTAssertTrue(
            BackgroundCompilationService.shouldRetryCompilation(after: CompilationError.networkTimeout),
            "Transient transport failures should retain the documented retry policy"
        )
    }

    // MARK: - AI OFF (local-only) eligibility — UI14 P2 regression
    //
    // Incident: with the global AI toggle OFF, `backfillIfNeeded()` still
    // selected yesterday's raw, ran the batch, and `aiDisabled` was classified
    // as retryable — so the runner slept 30/120/600s while Today showed a
    // misleading "Preparing your notes 30%" rail. These tests pin: (a) the
    // retry classifier treats `.aiDisabled` as non-retryable user state, and
    // (b) the automatic entry points gate on the shared AI-enabled condition
    // before any work — no compile start/end notifications, idle stage, raw
    // vault untouched, no daily written.

    /// Flips the process-global `AppSettings` AI toggle and returns a closure
    /// restoring the exact previous state (including "key was absent"). The
    /// toggle is UserDefaults-global — every caller MUST run the restore in
    /// `defer` so the rest of the serialized suite sees the original value.
    private func setAIFeaturesEnabled(_ enabled: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let key = AppSettings.Keys.aiFeaturesEnabled
        let previous = defaults.object(forKey: key)
        defaults.set(enabled, forKey: key)
        return {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Real yesterday in the production eligibility calendar — the date the
    /// automatic entries (backfill / foreground retry / BGTask) target.
    /// Returned as a pair so the file name and Date can never straddle a
    /// midnight rollover independently.
    private var yesterdayPair: (date: Date, dayString: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AppSettings.currentTimeZone()
        let date = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return (date, f.string(from: date))
    }

    /// Writes a raw memo file for real yesterday (raw exists, daily missing →
    /// `shouldCompile` is true in the temp vault) and returns the file URL,
    /// written content, and yyyy-MM-dd key.
    private func writeYesterdayRaw() throws -> (url: URL, content: String, dayString: String) {
        let (date, dayString) = yesterdayPair
        let memo = Memo(type: .text, created: date, body: "UI14 regression: yesterday note")
        let content = memo.toMarkdown()
        let url = rawDir.appendingPathComponent("\(dayString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return (url, content, dayString)
    }

    /// Counts the notifications the automatic compile paths post around a
    /// run: during `body` plus a short window afterwards. The AI-off guards
    /// must prevent work from starting at all; a regressed entry point posts
    /// `.compilationDidStart` as its first side effect inside that window.
    private func captureCompileNotifications(
        _ body: () async -> Void
    ) async -> (start: Int, end: Int, foregroundSuccess: Int, weeklyRecap: Int) {
        var start = 0, end = 0, foregroundSuccess = 0, weeklyRecap = 0
        let t1 = NotificationCenter.default.addObserver(
            forName: .compilationDidStart, object: nil, queue: .main
        ) { _ in start += 1 }
        let t2 = NotificationCenter.default.addObserver(
            forName: .compilationDidEnd, object: nil, queue: .main
        ) { _ in end += 1 }
        let t3 = NotificationCenter.default.addObserver(
            forName: .compileSucceededForeground, object: nil, queue: .main
        ) { _ in foregroundSuccess += 1 }
        let t4 = NotificationCenter.default.addObserver(
            forName: .weeklyRecapAvailable, object: nil, queue: .main
        ) { _ in weeklyRecap += 1 }
        defer {
            NotificationCenter.default.removeObserver(t1)
            NotificationCenter.default.removeObserver(t2)
            NotificationCenter.default.removeObserver(t3)
            NotificationCenter.default.removeObserver(t4)
        }
        await body()
        // Regression window: let any stray Task a regressed entry point may
        // have spawned reach its first observable side effect.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return (start, end, foregroundSuccess, weeklyRecap)
    }

    /// UI14 P2 core regression: AI OFF must gate the automatic backfill BEFORE
    /// the vault scan and batch Task creation. Yesterday's raw is present and
    /// needs a compile — nothing may run, post, or change.
    @MainActor
    func testAIOff_backfillEntry_doesNotStartBackfillForYesterday() async throws {
        let restoreAI = setAIFeaturesEnabled(false)
        defer { restoreAI() }
        XCTAssertFalse(BackgroundCompilationService.isAutomaticCompileEligible,
            "test setup: the shared gate must read the global toggle")

        let (rawURL, rawContent, dayString) = try writeYesterdayRaw()

        let counts = await captureCompileNotifications {
            await BackgroundCompilationService.shared.backfillIfNeeded()
        }

        XCTAssertEqual(counts.start, 0,
            "AI-off backfill must not post .compilationDidStart — the incident ran a live batch")
        XCTAssertEqual(counts.end, 0,
            "AI-off backfill must not post .compilationDidEnd")
        XCTAssertEqual(BackgroundCompilationService.shared.stage, .idle,
            "AI-off backfill must keep Today's progress rail idle — the incident showed a fake 30%")
        XCTAssertFalse(BackgroundCompilationService.shared.isPresentingStage)
        XCTAssertEqual(try String(contentsOf: rawURL, encoding: .utf8), rawContent,
            "raw vault content must remain byte-identical")
        XCTAssertFalse(
            fm.fileExists(atPath: dailyDir.appendingPathComponent("\(dayString).md").path),
            "no daily page may be written while AI is off"
        )
    }

    /// UI14 P2: the automatic foreground retry (scenePhase catch-up targeting
    /// yesterday) must be gated before any compile work when AI is off.
    @MainActor
    func testAIOff_foregroundRetryEntry_doesNotStartYesterdaysCompile() async throws {
        let restoreAI = setAIFeaturesEnabled(false)
        defer { restoreAI() }

        let (rawURL, rawContent, dayString) = try writeYesterdayRaw()

        let counts = await captureCompileNotifications {
            await BackgroundCompilationService.shared.foregroundRetryIfNeeded()
        }

        XCTAssertEqual(counts.start, 0, "AI-off foreground retry must not start a compile")
        XCTAssertEqual(counts.end, 0, "AI-off foreground retry must not post .compilationDidEnd")
        XCTAssertEqual(counts.foregroundSuccess, 0,
            "no .compileSucceededForeground toast may fire while AI is off")
        XCTAssertEqual(BackgroundCompilationService.shared.stage, .idle,
            "AI-off foreground retry must keep the progress rail idle")
        XCTAssertFalse(BackgroundCompilationService.shared.isPresentingStage)
        XCTAssertEqual(try String(contentsOf: rawURL, encoding: .utf8), rawContent,
            "raw vault content must remain byte-identical")
        XCTAssertFalse(
            fm.fileExists(atPath: dailyDir.appendingPathComponent("\(dayString).md").path),
            "no daily page may be written while AI is off"
        )
    }

    /// UI14 P2: the weekly automatic compile shares the same eligibility gate
    /// and must return without side effects while AI is off.
    @MainActor
    func testAIOff_weeklyAutoCompileEntry_runsNoWork() async {
        let restoreAI = setAIFeaturesEnabled(false)
        defer { restoreAI() }

        let counts = await captureCompileNotifications {
            await BackgroundCompilationService.shared.tryAutoCompileWeekly()
        }

        XCTAssertEqual(counts.weeklyRecap, 0,
            "AI-off must gate the weekly auto compile before any work")
        XCTAssertEqual(counts.start, 0, "no compile work may start while AI is off")
        XCTAssertEqual(BackgroundCompilationService.shared.stage, .idle)
    }

    /// Positive control: the shared gate reflects the global toggle in both
    /// directions — the AI-off tests above must not pass against a gate that
    /// is permanently closed.
    func testAutomaticCompileEligibility_reflectsGlobalToggle() {
        let restoreAI = setAIFeaturesEnabled(true)
        defer { restoreAI() }
        XCTAssertTrue(BackgroundCompilationService.isAutomaticCompileEligible,
            "AI ON must leave the automatic compile gate open (positive control)")

        UserDefaults.standard.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        XCTAssertFalse(BackgroundCompilationService.isAutomaticCompileEligible,
            "AI OFF must close the automatic compile gate")
    }

    /// Retry classification contract (UI14 P2): `.aiDisabled` and
    /// `.missingApiKey` are non-retryable user/configuration state; transient
    /// transport failures keep the documented retry policy.
    func testRetryClassification_aiDisabled_missingKey_transient() {
        XCTAssertFalse(
            BackgroundCompilationService.shouldRetryCompilation(after: CompilationError.aiDisabled),
            "AI OFF is a deliberate user choice — retrying it kept a fake 30% rail alive for ~12.5 minutes (UI14 P2)"
        )
        XCTAssertFalse(
            BackgroundCompilationService.shouldRetryCompilation(after: CompilationError.missingApiKey),
            "Missing credentials must reach the actionable Settings banner immediately"
        )
        XCTAssertTrue(
            BackgroundCompilationService.shouldRetryCompilation(after: CompilationError.networkTimeout),
            "Transient transport failures should retain the documented retry policy"
        )
        XCTAssertTrue(
            BackgroundCompilationService.shouldRetryCompilation(after: CompilationError.networkError("connection reset")),
            "Transient transport failures should retain the documented retry policy"
        )
    }
}
