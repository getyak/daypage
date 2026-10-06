import Testing
import SwiftUI
import CoreGraphics
import DayPageServices
@testable import DayPage

// MARK: - Helpers

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}

private func makeUTCDate(hour: Int, minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 1; c.day = 15
    c.hour = hour; c.minute = minute
    c.timeZone = TimeZone(secondsFromGMT: 0)
    return Calendar(identifier: .gregorian).date(from: c)!
}

/// Bridge Color → sRGB components via UIColor.
private func rgb(_ color: Color) -> (r: Double, g: Double, b: Double) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Double(r), Double(g), Double(b))
}

// MARK: - TimeOfDay bucket boundaries

extension DayPageSerialSwiftTests {
@Suite("TimeLogic — TimeOfDay.bucket")
struct TimeOfDayBucketTests {
    @Test func hour5IsMorning()    { #expect(TimeOfDay.bucket(hour: 5)  == .morning) }
    @Test func hour11IsMorning()   { #expect(TimeOfDay.bucket(hour: 11) == .morning) }
    @Test func hour12IsAfternoon() { #expect(TimeOfDay.bucket(hour: 12) == .afternoon) }
    @Test func hour17IsAfternoon() { #expect(TimeOfDay.bucket(hour: 17) == .afternoon) }
    @Test func hour18IsEvening()   { #expect(TimeOfDay.bucket(hour: 18) == .evening) }
    @Test func hour22IsEvening()   { #expect(TimeOfDay.bucket(hour: 22) == .evening) }
    @Test func hour23IsLateNight() { #expect(TimeOfDay.bucket(hour: 23) == .lateNight) }
    @Test func hour0IsLateNight()  { #expect(TimeOfDay.bucket(hour: 0)  == .lateNight) }
    @Test func hour4IsLateNight()  { #expect(TimeOfDay.bucket(hour: 4)  == .lateNight) }
}
}

// MARK: - TimeOfDay.continuousTint anchor exactness & midnight wrap

extension DayPageSerialSwiftTests {
@Suite("TimeLogic — TimeOfDay.continuousTint")
struct ContinuousTintTests {

    // Each anchor hour should produce its exact anchor color (within floating-point rounding).
    // Anchors defined in TimeOfDay.swift: 01:30→lateNight, 08:00→morning, 14:30→afternoon, 20:00→evening.

    @Test func lateNightAnchorExact() {
        let cal = utcCalendar()
        let color = TimeOfDay.continuousTint(at: makeUTCDate(hour: 1, minute: 30), calendar: cal)
        let c = rgb(color)
        #expect(abs(c.r - 0.28) < 0.001)
        #expect(abs(c.g - 0.22) < 0.001)
        #expect(abs(c.b - 0.60) < 0.001)
    }

    @Test func morningAnchorExact() {
        let cal = utcCalendar()
        let color = TimeOfDay.continuousTint(at: makeUTCDate(hour: 8, minute: 0), calendar: cal)
        let c = rgb(color)
        #expect(abs(c.r - 0.45) < 0.001)
        #expect(abs(c.g - 0.55) < 0.001)
        #expect(abs(c.b - 0.88) < 0.001)
    }

    @Test func afternoonAnchorExact() {
        let cal = utcCalendar()
        let color = TimeOfDay.continuousTint(at: makeUTCDate(hour: 14, minute: 30), calendar: cal)
        let c = rgb(color)
        #expect(abs(c.r - 1.00) < 0.001)
        #expect(abs(c.g - 0.75) < 0.001)
        #expect(abs(c.b - 0.00) < 0.001)
    }

    @Test func eveningAnchorExact() {
        let cal = utcCalendar()
        let color = TimeOfDay.continuousTint(at: makeUTCDate(hour: 20, minute: 0), calendar: cal)
        let c = rgb(color)
        #expect(abs(c.r - 0.85) < 0.001)
        #expect(abs(c.g - 0.40) < 0.001)
        #expect(abs(c.b - 0.15) < 0.001)
    }

    /// 23:00 sits between the evening anchor (20:00) and the late-night anchor (01:30 next day).
    /// The interpolated result must have no NaN/out-of-[0,1] channels and must lie between
    /// the two anchor colors channel-by-channel.
    @Test func midnightWrapInterpolatesValidly() {
        let cal = utcCalendar()
        let color = TimeOfDay.continuousTint(at: makeUTCDate(hour: 23, minute: 0), calendar: cal)
        let c = rgb(color)
        // No NaN
        #expect(!c.r.isNaN && !c.g.isNaN && !c.b.isNaN)
        // All channels in [0, 1]
        #expect(c.r >= 0 && c.r <= 1)
        #expect(c.g >= 0 && c.g <= 1)
        #expect(c.b >= 0 && c.b <= 1)
        // Between evening (0.85, 0.40, 0.15) and lateNight (0.28, 0.22, 0.60)
        #expect(c.r >= 0.28 - 0.001 && c.r <= 0.85 + 0.001)
        #expect(c.g >= 0.22 - 0.001 && c.g <= 0.40 + 0.001)
        #expect(c.b >= 0.15 - 0.001 && c.b <= 0.60 + 0.001)
    }
}
}

// MARK: - DayProgress.fraction

extension DayPageSerialSwiftTests {
@Suite("TimeLogic — DayProgress.fraction")
struct DayProgressFractionTests {

    private func date(hour: Int, minute: Int = 0) -> Date { makeUTCDate(hour: hour, minute: minute) }
    private var cal: Calendar { utcCalendar() }

    @Test func zeroAtStartOfDay() {
        let result = DayProgress.fraction(at: date(hour: 0), calendar: cal)
        #expect(abs(result) < 0.0001)
    }

    @Test func halfAtLocalNoon() {
        let result = DayProgress.fraction(at: date(hour: 12), calendar: cal)
        #expect(abs(result - 0.5) < 0.0001)
    }

    @Test func monotonicallyIncreasing() {
        let hours = [0, 3, 6, 9, 12, 15, 18, 21, 23]
        let fractions = hours.map { DayProgress.fraction(at: date(hour: $0), calendar: cal) }
        for i in 1..<fractions.count {
            #expect(fractions[i] > fractions[i - 1])
        }
    }

    @Test func previousDayEndsNearOne() {
        let start = cal.startOfDay(for: date(hour: 6))
        let result = DayProgress.fraction(at: start.addingTimeInterval(-1), calendar: cal)
        #expect(abs(result - CGFloat(86399.0 / 86400.0)) < 0.0000001)
    }

    @Test func nextDayStartsNearZero() {
        let start = cal.startOfDay(for: date(hour: 6))
        let nextDay = cal.date(byAdding: .day, value: 1, to: start)!
        let result = DayProgress.fraction(at: nextDay.addingTimeInterval(1), calendar: cal)
        #expect(abs(result - CGFloat(1.0 / 86400.0)) < 0.0000001)
    }
}
}

// MARK: - TimeZoneBadge.gmtOffset

extension DayPageSerialSwiftTests {
@Suite("TimeLogic — TimeZoneBadge.gmtOffset")
struct TimeZoneBadgeTests {

    private let anchor = Date(timeIntervalSince1970: 0) // 1970-01-01 00:00 UTC

    @Test func gmtZero() {
        let tz = TimeZone(secondsFromGMT: 0)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: anchor) == "GMT")
    }

    @Test func gmtPlusSeven() {
        let tz = TimeZone(secondsFromGMT: 7 * 3600)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: anchor) == "GMT+7")
    }

    @Test func gmtMinusThreeThirty() {
        let tz = TimeZone(secondsFromGMT: -(3 * 3600 + 30 * 60))!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: anchor) == "GMT-3:30")
    }

    @Test func gmtPlusFiveFortyFive() {
        let tz = TimeZone(secondsFromGMT: 5 * 3600 + 45 * 60)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: anchor) == "GMT+5:45")
    }
}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias ContinuousTintTests = DayPageSerialSwiftTests.ContinuousTintTests
typealias DayProgressFractionTests = DayPageSerialSwiftTests.DayProgressFractionTests
typealias TimeOfDayBucketTests = DayPageSerialSwiftTests.TimeOfDayBucketTests
typealias TimeZoneBadgeTests = DayPageSerialSwiftTests.TimeZoneBadgeTests

// Same absolute capture timestamp, including civil-day and DST boundaries.
// Actual SwiftUI settings observation is verified separately in the real UI.
extension DayPageSerialSwiftTests {
@Suite("Memo detail — preferred-zone timestamp presentation")
struct MemoDetailTimeZonePresentationTests {
    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test func fixtureFollowsSelectedZoneAndPreservesAbsoluteInstant() {
        let date = instant("2026-10-03T17:09:59Z")
        let unchanged = date
        let values: [(String, String, String)] = [
            ("Asia/Shanghai", "2026-10-04 01:09:59", "2026-10-04  01:09"),
            ("Pacific/Kiritimati", "2026-10-04 07:09:59", "2026-10-04  07:09"),
            ("America/Los_Angeles", "2026-10-03 10:09:59", "2026-10-03  10:09")
        ]
        for (identifier, full, kicker) in values {
            let zone = TimeZone(identifier: identifier)!
            #expect(MemoDetailDatePresentation.createdFull(date, timeZone: zone) == full)
            #expect(MemoDetailDatePresentation.kicker(date, timeZone: zone) == kicker)
            #expect(date == unchanged)
        }
    }

    @Test func returningToAZoneDoesNotReuseAnotherZoneFormatter() {
        let date = instant("2026-10-03T17:09:59Z")
        for (id, expected) in [("Pacific/Kiritimati", "2026-10-04 07:09:59"),
                               ("America/Los_Angeles", "2026-10-03 10:09:59"),
                               ("Pacific/Kiritimati", "2026-10-04 07:09:59"),
                               ("Asia/Shanghai", "2026-10-04 01:09:59")] {
            #expect(MemoDetailDatePresentation.createdFull(date, timeZone: TimeZone(identifier: id)!) == expected)
        }
    }

    @Test func losAngelesUsesSeasonalOffsetAtCaptureInstant() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(MemoDetailDatePresentation.createdFull(instant("2026-01-15T08:00:00Z"), timeZone: zone) == "2026-01-15 00:00:00")
        #expect(MemoDetailDatePresentation.createdFull(instant("2026-07-15T07:00:00Z"), timeZone: zone) == "2026-07-15 00:00:00")
    }

    @Test func daylightSavingSpringGapIsAnInstantConversion() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(MemoDetailDatePresentation.createdFull(instant("2026-03-08T09:59:59Z"), timeZone: zone) == "2026-03-08 01:59:59")
        #expect(MemoDetailDatePresentation.createdFull(instant("2026-03-08T10:00:00Z"), timeZone: zone) == "2026-03-08 03:00:00")
    }

    @Test func daylightSavingFallRepeatPreservesBothInstants() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let first = instant("2026-11-01T08:59:59Z")
        let second = instant("2026-11-01T09:00:00Z")
        #expect(first < second)
        #expect(MemoDetailDatePresentation.createdFull(first, timeZone: zone) == "2026-11-01 01:59:59")
        #expect(MemoDetailDatePresentation.createdFull(second, timeZone: zone) == "2026-11-01 01:00:00")
    }

    @Test func fractionalOffsetAndLeapDayCanCrossCivilDay() {
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
        #expect(MemoDetailDatePresentation.createdFull(instant("2026-10-03T17:09:59Z"), timeZone: kathmandu) == "2026-10-03 22:54:59")
        let date = instant("2024-02-29T23:30:00Z")
        #expect(MemoDetailDatePresentation.createdFull(date, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!) == "2024-03-01 13:30:00")
        #expect(MemoDetailDatePresentation.createdFull(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2024-02-29 15:30:00")
    }
}
}


// Real card observation and dot-separated rendering are checked separately in UI.
extension DayPageSerialSwiftTests {
@MainActor
@Suite("Memo card — preferred-zone capture clock")
struct MemoCardTimeZonePresentationTests {
    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
    private func clock(_ date: Date, _ identifier: String) -> String {
        MemoCardTimePresentation.shortTime(date, timeZone: TimeZone(identifier: identifier)!)
    }

    @Test func fixtureFollowsSelectedZoneAndPreservesAbsoluteInstant() {
        let date = instant("2026-10-03T17:09:59Z")
        let unchanged = date
        for (zone, expected) in [("Asia/Shanghai", "01:09"),
                                 ("Pacific/Kiritimati", "07:09"),
                                 ("America/Los_Angeles", "10:09")] {
            #expect(clock(date, zone) == expected)
            #expect(date == unchanged)
        }
    }

    @Test func returningToAZoneUsesItsImmutableFormatter() {
        let date = instant("2026-10-03T17:09:59Z")
        for (zone, expected) in [("Pacific/Kiritimati", "07:09"),
                                 ("America/Los_Angeles", "10:09"),
                                 ("Pacific/Kiritimati", "07:09"),
                                 ("Asia/Shanghai", "01:09"),
                                 ("America/Los_Angeles", "10:09")] {
            #expect(clock(date, zone) == expected)
        }
    }

    @Test func losAngelesUsesSeasonalOffsetAtCaptureInstant() {
        #expect(clock(instant("2026-01-15T08:00:00Z"), "America/Los_Angeles") == "00:00")
        #expect(clock(instant("2026-07-15T07:00:00Z"), "America/Los_Angeles") == "00:00")
    }

    @Test func daylightSavingSpringGapIsAnInstantConversion() {
        #expect(clock(instant("2026-03-08T09:59:59Z"), "America/Los_Angeles") == "01:59")
        #expect(clock(instant("2026-03-08T10:00:00Z"), "America/Los_Angeles") == "03:00")
    }

    @Test func daylightSavingFallRepeatPreservesBothInstants() {
        let first = instant("2026-11-01T08:59:59Z")
        let second = instant("2026-11-01T09:00:00Z")
        #expect(first < second)
        #expect(clock(first, "America/Los_Angeles") == "01:59")
        #expect(clock(second, "America/Los_Angeles") == "01:00")
    }

    @Test func fractionalOffsetAndLeapDayUseCaptureClock() {
        #expect(clock(instant("2026-10-03T17:09:59Z"), "Asia/Kathmandu") == "22:54")
        let date = instant("2024-02-29T23:30:00Z")
        #expect(clock(date, "Pacific/Kiritimati") == "13:30")
        #expect(clock(date, "America/Los_Angeles") == "15:30")
    }
}
}
