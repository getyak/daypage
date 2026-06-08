import Testing
import SwiftUI
import CoreGraphics
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

// MARK: - TimeOfDay.continuousTint anchor exactness & midnight wrap

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

// MARK: - DayProgress.fraction

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

    @Test func clampedToZeroForBeforeMidnight() {
        let start = cal.startOfDay(for: date(hour: 6))
        let result = DayProgress.fraction(at: start.addingTimeInterval(-1), calendar: cal)
        #expect(result == 0.0)
    }

    @Test func clampedToOneForAfterEndOfDay() {
        let start = cal.startOfDay(for: date(hour: 6))
        let nextDay = cal.date(byAdding: .day, value: 1, to: start)!
        let result = DayProgress.fraction(at: nextDay.addingTimeInterval(1), calendar: cal)
        #expect(result == 1.0)
    }
}

// MARK: - TimeZoneBadge.gmtOffset

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
