// WeeklyRecapAutoTriggerTests.swift — Round 8 (R8-HIGH: 周回顾自动触发)
//
// Pure-function tests for the auto-trigger decision: "should the 2am
// background compilation fire the weekly recap *this morning*?"
//
// The brief for the auto-trigger landed concurrently in another
// agent's lane (BackgroundCompilationService), so this file deliberately
// stays decoupled from that production type. We test the same decision
// rule against a local `shouldTriggerWeeklyOnMonday(referenceDate:dailyCount:)`
// implementation that mirrors the agreed contract:
//
//   - Trigger only on Monday (Gregorian weekday == 2).
//   - Trigger only when the previous-week daily-page count >= 3 (the
//     minimum for a useful recap; below that, the LLM has nothing to
//     summarise and we'd burn the user's tokens for filler).
//
// When BackgroundCompilationService adopts a real helper it can replace
// the local copy with `BackgroundCompilationService.shouldTriggerWeeklyOnMonday(...)`
// and the assertions remain valid.

import Testing
import Foundation
@testable import DayPage

@MainActor
@Suite(.serialized)
struct WeeklyRecapAutoTriggerTests {

    // MARK: - Local copy of the decision rule
    //
    // Pure, side-effect-free; mirrors the rule documented for the
    // forthcoming BackgroundCompilationService.tryAutoCompileWeekly.
    // Lives here so these tests don't reach into the production
    // singleton's clock or file system.

    private func shouldTriggerWeeklyOnMonday(referenceDate: Date, dailyCount: Int) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        // Gregorian weekday: 1 = Sunday, 2 = Monday, …, 7 = Saturday.
        let weekday = cal.component(.weekday, from: referenceDate)
        let isMonday = (weekday == 2)
        return isMonday && dailyCount >= 3
    }

    // MARK: - Fixtures

    private func date(_ string: String) -> Date {
        // ISO yyyy-MM-dd in UTC so the weekday math is deterministic
        // regardless of where the test runs.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: string)!
    }

    // MARK: - Tests

    @Test
    func mondayWithThreeDailiesTriggers() {
        // 2026-06-22 is a Monday (verified with `date -j` at fixture
        // time — change the fixture if the test moves to a different
        // calendar root).
        let monday = date("2026-06-22")
        #expect(shouldTriggerWeeklyOnMonday(referenceDate: monday, dailyCount: 3))
        #expect(shouldTriggerWeeklyOnMonday(referenceDate: monday, dailyCount: 7))
    }

    @Test
    func mondayWithTooFewDailiesSkips() {
        let monday = date("2026-06-22")
        #expect(!shouldTriggerWeeklyOnMonday(referenceDate: monday, dailyCount: 0))
        #expect(!shouldTriggerWeeklyOnMonday(referenceDate: monday, dailyCount: 1))
        #expect(!shouldTriggerWeeklyOnMonday(referenceDate: monday, dailyCount: 2))
    }

    @Test
    func nonMondaysNeverTrigger() {
        // Sweep the rest of the week — none should trigger even when
        // dailyCount comfortably exceeds the floor.
        let sunday    = date("2026-06-21")
        let tuesday   = date("2026-06-23")
        let wednesday = date("2026-06-24")
        let thursday  = date("2026-06-25")
        let friday    = date("2026-06-26")
        let saturday  = date("2026-06-27")

        for day in [sunday, tuesday, wednesday, thursday, friday, saturday] {
            #expect(!shouldTriggerWeeklyOnMonday(referenceDate: day, dailyCount: 7),
                    "weekday \(day) should not trigger weekly recap")
        }
    }

    @Test
    func boundaryCountIsThree() {
        // Defensive regression: the rule is `>= 3`, not `> 3`. If
        // someone tightens it to `> 3`, a user with exactly 3 dailies
        // will silently lose their Monday recap.
        let monday = date("2026-06-22")
        #expect(shouldTriggerWeeklyOnMonday(referenceDate: monday, dailyCount: 3))
    }

    // MARK: - Real BackgroundCompilationService.tryAutoCompileWeekly path
    //
    // R9-MEDIUM: the pure-function tests above pin the decision rule, but
    // they don't catch a regression where someone deletes / breaks the
    // guard inside `BackgroundCompilationService.tryAutoCompileWeekly`
    // itself. These tests exercise the real method through
    // `@testable internal` access, seeding a temp vault via
    // `VaultInitializer.testOverrideURL` (same pattern as
    // `BackgroundCompilationServiceTests`).
    //
    // We can't override `Date()` without a clock seam, so each test
    // gates on the *actual* current weekday and asserts the correct
    // branch for that day. At least one of the three cases will run on
    // any given CI day; across a Mon–Sun rotation the suite covers all
    // branches.

    /// Seed a temp vault, point `VaultInitializer.testOverrideURL` at
    /// it, run the body, then tear down so state doesn't leak. Async
    /// because callers `await BackgroundCompilationService.shared.tryAutoCompileWeekly()`.
    private func withTempVault<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("weekly-auto-\(UUID().uuidString)", isDirectory: true)
        let dailyDir = root.appendingPathComponent("wiki/daily", isDirectory: true)
        let weeklyDir = root.appendingPathComponent("wiki/weekly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: weeklyDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = root
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(root)
    }

    /// Minimal daily-page frontmatter that satisfies
    /// `collectWeekMetadata`'s mood/summary/entities/locations
    /// extraction. The gate is "file exists and is parseable".
    private func dailyStub(date: String) -> String {
        """
        ---
        type: daily_page
        date: \(date)
        mood: calm
        summary: stub
        entities:
          - work
        locations:
          - home
        ---

        # \(date)
        body
        """
    }

    private func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f.string(from: d)
    }

    /// True if `now` falls on a Monday under the same calendar
    /// configuration `tryAutoCompileWeekly` uses. Each test gates on
    /// this to run the branch that's actually reachable today.
    private func isCurrentMonday() -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AppSettings.currentTimeZone()
        cal.firstWeekday = 2
        return cal.component(.weekday, from: Date()) == 2
    }

    /// Capture whether `.weeklyRecapAvailable` fires during `body`.
    /// Returns the captured count once the awaited body completes.
    private func captureWeeklyRecapNotifications(_ body: () async -> Void) async -> Int {
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .weeklyRecapAvailable,
            object: nil,
            queue: .main
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        await body()
        return count
    }

    @Test
    func tryAutoCompileWeekly_skipsOnNonMonday() async throws {
        // Only meaningful on non-Monday days. On Mondays this branch is
        // unreachable; soft-skip via early return (Swift Testing has no
        // first-class skip primitive — `#require(false)` records an
        // expectation failure, which we don't want for a calendar-gated
        // case).
        guard !isCurrentMonday() else { return }

        try await withTempVault { root in
            // Seed 7 daily files for "last week" — the week containing
            // yesterday. Non-Monday guard wins regardless of how many
            // daily pages exist.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = AppSettings.currentTimeZone()
            cal.firstWeekday = 2
            let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
            let weekInterval = cal.dateInterval(of: .weekOfYear, for: yesterday)!
            let weekStart = cal.startOfDay(for: weekInterval.start)
            let dailyDir = root.appendingPathComponent("wiki/daily", isDirectory: true)
            for offset in 0..<7 {
                let d = cal.date(byAdding: .day, value: offset, to: weekStart)!
                let url = dailyDir.appendingPathComponent("\(ymd(d)).md")
                try? Data(dailyStub(date: ymd(d)).utf8).write(to: url, options: .atomic)
            }

            let count = await captureWeeklyRecapNotifications {
                await BackgroundCompilationService.shared.tryAutoCompileWeekly()
            }
            // Non-Monday: must NOT enter compile path, must NOT post.
            #expect(count == 0, "non-Monday must not fire weeklyRecapAvailable")
        }
    }

    @Test
    func tryAutoCompileWeekly_skipsWhenInsufficientDays() async throws {
        // Monday-only branch; soft-skip on other days.
        guard isCurrentMonday() else { return }

        try await withTempVault { root in
            // Seed only 2 daily files — below the `>= 3` floor.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = AppSettings.currentTimeZone()
            cal.firstWeekday = 2
            let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
            let weekInterval = cal.dateInterval(of: .weekOfYear, for: yesterday)!
            let weekStart = cal.startOfDay(for: weekInterval.start)
            let dailyDir = root.appendingPathComponent("wiki/daily", isDirectory: true)
            for offset in 0..<2 {
                let d = cal.date(byAdding: .day, value: offset, to: weekStart)!
                let url = dailyDir.appendingPathComponent("\(ymd(d)).md")
                try? Data(dailyStub(date: ymd(d)).utf8).write(to: url, options: .atomic)
            }

            let count = await captureWeeklyRecapNotifications {
                await BackgroundCompilationService.shared.tryAutoCompileWeekly()
            }
            // Insufficient dailies: guard returns before compileWeekly,
            // so no notification fires.
            #expect(count == 0, "<3 dailies must not fire weeklyRecapAvailable")
        }
    }

    @Test
    func tryAutoCompileWeekly_triggersOnMondayWithSufficientDays() async throws {
        // Monday-only happy path; soft-skip on other days.
        guard isCurrentMonday() else { return }

        try await withTempVault { root in
            // Seed 5 daily files + a pre-cached weekly file. compileWeekly
            // hits the cache path (no LLM round-trip) and returns
            // successfully → tryAutoCompileWeekly posts the refresh
            // notification. This is the "happy path" smoke test: the
            // success branch is wired without depending on the network
            // or AI key.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = AppSettings.currentTimeZone()
            cal.firstWeekday = 2
            let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
            let weekInterval = cal.dateInterval(of: .weekOfYear, for: yesterday)!
            let weekStart = cal.startOfDay(for: weekInterval.start)
            let dailyDir = root.appendingPathComponent("wiki/daily", isDirectory: true)
            for offset in 0..<5 {
                let d = cal.date(byAdding: .day, value: offset, to: weekStart)!
                let url = dailyDir.appendingPathComponent("\(ymd(d)).md")
                try? Data(dailyStub(date: ymd(d)).utf8).write(to: url, options: .atomic)
            }

            // Pre-cache the weekly recap so compileWeekly short-circuits
            // on the cache hit. The format mirrors what
            // WeeklyCompilationService.write produces.
            let isoWeek = WeeklyCompilationService.isoWeekKey(for: weekStart)
            let weeklyFile = root
                .appendingPathComponent("wiki/weekly")
                .appendingPathComponent("\(isoWeek).md")
            let weekEndStr = ymd(cal.date(byAdding: .day, value: 6, to: weekStart)!)
            // Cache field names mirror what
            // WeeklyCompilationService.renderMarkdown writes:
            // isoWeek / dateRange / compiledAt (camelCase, not snake).
            let cachedRecap = """
            ---
            type: weekly_recap
            isoWeek: \(isoWeek)
            dateRange: \(ymd(weekStart)) to \(weekEndStr)
            compiledAt: 2026-01-01T00:00:00Z
            ---

            ## 本周关键词

            - test

            ## 本周心情

            ok

            ## 本周地点

            ok

            ## 本周高光

            - cached fixture
            """
            try? Data(cachedRecap.utf8).write(to: weeklyFile, options: .atomic)

            let count = await captureWeeklyRecapNotifications {
                await BackgroundCompilationService.shared.tryAutoCompileWeekly()
            }
            // Monday + ≥3 dailies + cache hit: compileWeekly succeeds
            // synchronously, notification fires at least once.
            #expect(count >= 1, "Monday with sufficient dailies + cache hit must post weeklyRecapAvailable")
        }
    }
}
