import Testing
import Foundation
@testable import DayPage

@Suite("DayProgressTests")
struct DayProgressTests {

    /// UTC calendar — stable, no DST, so assertions are exact.
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Build a Date from UTC components.
    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test func fraction_atMidnight_isZero() {
        let midnight = date(year: 2024, month: 3, day: 10, hour: 0)
        let result = DayProgress.fraction(at: midnight, calendar: utc)
        #expect(abs(result) < 0.0001)
    }

    @Test func fraction_atNoon_isHalf() {
        let noon = date(year: 2024, month: 3, day: 10, hour: 12)
        let result = DayProgress.fraction(at: noon, calendar: utc)
        #expect(abs(result - 0.5) < 0.0001)
    }

    @Test func fraction_nearMidnight_isNearOne() {
        let almostMidnight = date(year: 2024, month: 3, day: 10, hour: 23, minute: 59, second: 59)
        let result = DayProgress.fraction(at: almostMidnight, calendar: utc)
        #expect(result > 0.999)
        #expect(result <= 1.0)
    }

    @Test func fraction_clampsBelowZero() {
        // Manually crafted: pass a time 1s before startOfDay by giving it exactly startOfDay minus 1s.
        // We do this by computing startOfDay and subtracting one second.
        let noon = date(year: 2024, month: 3, day: 10, hour: 12)
        let start = utc.startOfDay(for: noon)
        let beforeStart = start.addingTimeInterval(-1)
        let result = DayProgress.fraction(at: beforeStart, calendar: utc)
        #expect(result == 0.0)
    }

    @Test func fraction_clampsAboveOne() {
        // Time one second past end-of-day = one second into the next day.
        let noon = date(year: 2024, month: 3, day: 10, hour: 12)
        let start = utc.startOfDay(for: noon)
        let next = utc.date(byAdding: .day, value: 1, to: start)!
        let afterEnd = next.addingTimeInterval(1)
        let result = DayProgress.fraction(at: afterEnd, calendar: utc)
        #expect(result == 1.0)
    }

    /// DST spring-forward: US/Eastern 2024-03-10 loses one hour (23-hour day).
    /// Noon on that day should be slightly past the halfway mark because 12h elapsed
    /// out of a 23h day → fraction ≈ 12/23 ≈ 0.5217.
    @Test func fraction_dstSpringForward_noonSlightlyAboveHalf() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!

        // Build noon local time on the spring-forward day.
        var c = DateComponents()
        c.year = 2024; c.month = 3; c.day = 10
        c.hour = 12; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "America/New_York")
        let noon = Calendar(identifier: .gregorian).date(from: c)!

        let result = DayProgress.fraction(at: noon, calendar: eastern)
        let expected = CGFloat(12.0 / 23.0)
        #expect(abs(result - expected) < 0.0001)
    }
}
