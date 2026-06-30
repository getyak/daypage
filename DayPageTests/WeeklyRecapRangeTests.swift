import Testing
import Foundation
import DayPageServices
@testable import DayPage

@Suite("WeeklyRecapRange")
struct WeeklyRecapRangeTests {

    /// Monday-first Gregorian calendar in UTC — stable, no DST.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2  // Monday
        return c
    }

    /// Build a UTC midnight Date from components.
    private func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    // MARK: - Mid-week (Wednesday)

    /// Wednesday 2026-06-03: range should be Mon 06-01 and Tue 06-02 (today excluded).
    @Test func midWeekWednesday_returnsMondayAndTuesday() {
        let wednesday = date(year: 2026, month: 6, day: 3)
        let result = WeeklyRecapRange.dates(referenceDate: wednesday, calendar: cal)

        let monday = date(year: 2026, month: 6, day: 1)
        let tuesday = date(year: 2026, month: 6, day: 2)
        #expect(result == [monday, tuesday])
    }

    @Test func midWeekWednesday_todayExcluded() {
        let wednesday = date(year: 2026, month: 6, day: 3)
        let result = WeeklyRecapRange.dates(referenceDate: wednesday, calendar: cal)
        #expect(!result.contains(wednesday))
    }

    // MARK: - Monday edge case

    /// Monday 2026-06-01: the week's Monday == today, so the lower bound falls
    /// back to yesterday (Sunday 2026-05-31). Result must be exactly [yesterday].
    @Test func monday_returnsExactlyYesterday_neverEmpty() {
        let monday = date(year: 2026, month: 6, day: 1)
        let result = WeeklyRecapRange.dates(referenceDate: monday, calendar: cal)

        let sunday = date(year: 2026, month: 5, day: 31)
        #expect(result == [sunday])
        #expect(result.count == 1)
    }

    // MARK: - Sunday

    /// Sunday 2026-06-07: range should be Mon 06-01 through Sat 06-06 (6 dates).
    @Test func sunday_returnsMonThroughSat() {
        let sunday = date(year: 2026, month: 6, day: 7)
        let result = WeeklyRecapRange.dates(referenceDate: sunday, calendar: cal)

        let expected = (1...6).map { day in date(year: 2026, month: 6, day: day) }
        #expect(result == expected)
    }

    // MARK: - Ordering and bounds

    /// Dates must be oldest-first and all strictly before today's midnight.
    @Test func dates_areOldestFirst_allBeforeToday() {
        let wednesday = date(year: 2026, month: 6, day: 3)
        let result = WeeklyRecapRange.dates(referenceDate: wednesday, calendar: cal)

        let today = cal.startOfDay(for: wednesday)
        #expect(result == result.sorted())
        for d in result {
            #expect(d < today)
        }
    }
}
