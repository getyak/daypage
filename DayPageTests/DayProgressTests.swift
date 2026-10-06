import Testing
import Foundation
import DayPageServices
@testable import DayPage

extension DayPageSerialSwiftTests {
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

    @Test func fraction_beforeMidnightUsesPreviousDay() {
        // The API chooses the day containing its timestamp, so -1s is the
        // previous day's last second rather than outside a fixed day interval.
        let noon = date(year: 2024, month: 3, day: 10, hour: 12)
        let start = utc.startOfDay(for: noon)
        let beforeStart = start.addingTimeInterval(-1)
        let result = DayProgress.fraction(at: beforeStart, calendar: utc)
        #expect(abs(result - CGFloat(86399.0 / 86400.0)) < 0.0000001)
    }

    @Test func fraction_afterMidnightUsesNextDay() {
        // Time one second past end-of-day = one second into the next day.
        let noon = date(year: 2024, month: 3, day: 10, hour: 12)
        let start = utc.startOfDay(for: noon)
        let next = utc.date(byAdding: .day, value: 1, to: start)!
        let afterEnd = next.addingTimeInterval(1)
        let result = DayProgress.fraction(at: afterEnd, calendar: utc)
        #expect(abs(result - CGFloat(1.0 / 86400.0)) < 0.0000001)
    }

    /// DST spring-forward: US/Eastern 2024-03-10 loses one hour (23-hour day).
    /// Noon on that day is slightly *below* the halfway mark: only 11 hours of
    /// real time elapse between local midnight and local noon (the 02:00→03:00
    /// jump skips a wall-clock hour), out of a 23h day → fraction = 11/23 ≈ 0.4783.
    /// `DayProgress.fraction` measures real elapsed ÷ real day length, so the
    /// spring-forward gap must compress the morning, not inflate it.
    @Test func fraction_dstSpringForward_noonSlightlyBelowHalf() {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!

        // Build noon local time on the spring-forward day.
        var c = DateComponents()
        c.year = 2024; c.month = 3; c.day = 10
        c.hour = 12; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "America/New_York")
        let noon = Calendar(identifier: .gregorian).date(from: c)!

        let result = DayProgress.fraction(at: noon, calendar: eastern)
        let expected = CGFloat(11.0 / 23.0)
        #expect(abs(result - expected) < 0.0001)
    }
}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias DayProgressTests = DayPageSerialSwiftTests.DayProgressTests
