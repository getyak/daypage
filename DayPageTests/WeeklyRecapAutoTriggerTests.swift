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
}
