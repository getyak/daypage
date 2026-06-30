import Testing
import SwiftUI
import DayPageServices
@testable import DayPage

@Suite("TimeOfDay")
struct TimeOfDayTests {

    // MARK: - bucket(hour:) boundary coverage

    @Test func hour4IsLateNight()   { #expect(TimeOfDay.bucket(hour: 4)  == .lateNight) }
    @Test func hour5IsMorning()     { #expect(TimeOfDay.bucket(hour: 5)  == .morning) }
    @Test func hour11IsMorning()    { #expect(TimeOfDay.bucket(hour: 11) == .morning) }
    @Test func hour12IsAfternoon()  { #expect(TimeOfDay.bucket(hour: 12) == .afternoon) }
    @Test func hour17IsAfternoon()  { #expect(TimeOfDay.bucket(hour: 17) == .afternoon) }
    @Test func hour18IsEvening()    { #expect(TimeOfDay.bucket(hour: 18) == .evening) }
    @Test func hour22IsEvening()    { #expect(TimeOfDay.bucket(hour: 22) == .evening) }
    @Test func hour23IsLateNight()  { #expect(TimeOfDay.bucket(hour: 23) == .lateNight) }
    @Test func hour0IsLateNight()   { #expect(TimeOfDay.bucket(hour: 0)  == .lateNight) }

    // MARK: - bucketIndex consistency

    @Test func bucketIndexMatchesRawValue() {
        #expect(TimeOfDay.morning.bucketIndex   == 0)
        #expect(TimeOfDay.afternoon.bucketIndex == 1)
        #expect(TimeOfDay.evening.bucketIndex   == 2)
        #expect(TimeOfDay.lateNight.bucketIndex == 3)
    }

    // MARK: - greetingKey consistency

    @Test func greetingKeysAreDistinct() {
        let keys = [
            TimeOfDay.morning.greetingKey,
            TimeOfDay.afternoon.greetingKey,
            TimeOfDay.evening.greetingKey,
            TimeOfDay.lateNight.greetingKey,
        ]
        #expect(Set(keys).count == 4)
    }

    @Test func greetingKeyValues() {
        #expect(TimeOfDay.morning.greetingKey   == "today.greeting.morning")
        #expect(TimeOfDay.afternoon.greetingKey == "today.greeting.afternoon")
        #expect(TimeOfDay.evening.greetingKey   == "today.greeting.evening")
        #expect(TimeOfDay.lateNight.greetingKey == "today.greeting.latenight")
    }

    // MARK: - tint consistency (four distinct colors)

    @Test func tintsAreDistinct() {
        let tints = [
            TimeOfDay.morning.tint,
            TimeOfDay.afternoon.tint,
            TimeOfDay.evening.tint,
            TimeOfDay.lateNight.tint,
        ]
        // Convert to string description for equality comparison since Color isn't Equatable in older SDKs
        let descriptions = tints.map { "\($0)" }
        #expect(Set(descriptions).count == 4)
    }

    // MARK: - TimeZoneBadge

    @Test func gmtZeroOffset() {
        let tz = TimeZone(secondsFromGMT: 0)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: Date()) == "GMT")
    }

    @Test func gmtPositiveWholeHour() {
        let tz = TimeZone(secondsFromGMT: 7 * 3600)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: Date()) == "GMT+7")
    }

    @Test func gmtNegativeWholeHour() {
        let tz = TimeZone(secondsFromGMT: -5 * 3600)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: Date()) == "GMT-5")
    }

    @Test func gmtIndiaHalfHour() {
        let tz = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: Date()) == "GMT+5:30")
    }

    @Test func gmtNepalQuarterHour() {
        let tz = TimeZone(secondsFromGMT: 5 * 3600 + 45 * 60)!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: Date()) == "GMT+5:45")
    }

    @Test func gmtNewfoundlandNegativeHalfHour() {
        let tz = TimeZone(secondsFromGMT: -(3 * 3600 + 30 * 60))!
        #expect(TimeZoneBadge.gmtOffset(for: tz, at: Date()) == "GMT-3:30")
    }

    // MARK: - continuousTint

    /// Helper: resolve a Color(red:green:blue:) to its (r,g,b) components in sRGB.
    private func components(_ color: Color) -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func makeDate(hour: Int, minute: Int = 0) -> (Date, Calendar) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1
        comps.hour = hour; comps.minute = minute
        return (cal.date(from: comps)!, cal)
    }

    @Test func continuousTintAtMorningAnchorApproximatesDiscrete() {
        let (date, cal) = makeDate(hour: 8, minute: 0)
        let continuous = TimeOfDay.continuousTint(at: date, calendar: cal)
        let discrete = TimeOfDay.morning.tint
        let c = components(continuous)
        let d = components(discrete)
        // Within 15% of the anchor — it's an interpolated midpoint, not exact equality
        #expect(abs(c.r - d.r) < 0.15)
        #expect(abs(c.g - d.g) < 0.15)
        #expect(abs(c.b - d.b) < 0.15)
    }

    @Test func continuousTintAtEveningAnchorApproximatesDiscrete() {
        let (date, cal) = makeDate(hour: 20, minute: 0)
        let continuous = TimeOfDay.continuousTint(at: date, calendar: cal)
        let discrete = TimeOfDay.evening.tint
        let c = components(continuous)
        let d = components(discrete)
        #expect(abs(c.r - d.r) < 0.15)
        #expect(abs(c.g - d.g) < 0.15)
        #expect(abs(c.b - d.b) < 0.15)
    }

    @Test func continuousTintBetweenMorningAndAfternoonFallsBetweenAnchors() {
        let (date, cal) = makeDate(hour: 11, minute: 15)
        let mid = TimeOfDay.continuousTint(at: date, calendar: cal)
        let morning = components(TimeOfDay.morning.tint)
        let afternoon = components(Color(red: 1.0, green: 0.75, blue: 0.0))
        let m = components(mid)
        // Each component should lie between the two anchor components (monotonic interpolation)
        func between(_ v: Double, _ a: Double, _ b: Double) -> Bool {
            let lo = min(a, b), hi = max(a, b)
            return v >= lo - 0.01 && v <= hi + 0.01
        }
        #expect(between(m.r, morning.r, afternoon.r))
        #expect(between(m.g, morning.g, afternoon.g))
        #expect(between(m.b, morning.b, afternoon.b))
    }

    @Test func continuousTintHasNoNaNComponents() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1
        for hour in 0..<24 {
            comps.hour = hour; comps.minute = 0
            let date = cal.date(from: comps)!
            let c = components(TimeOfDay.continuousTint(at: date, calendar: cal))
            #expect(!c.r.isNaN && !c.g.isNaN && !c.b.isNaN,
                    "NaN component at hour \(hour)")
            #expect((0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b),
                    "Component out of [0,1] at hour \(hour)")
        }
    }

    // MARK: - from(_:calendar:) round-trip

    @Test func fromDateUsesCalendarHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1

        comps.hour = 7
        #expect(TimeOfDay.from(cal.date(from: comps)!, calendar: cal) == .morning)

        comps.hour = 14
        #expect(TimeOfDay.from(cal.date(from: comps)!, calendar: cal) == .afternoon)

        comps.hour = 20
        #expect(TimeOfDay.from(cal.date(from: comps)!, calendar: cal) == .evening)

        comps.hour = 2
        #expect(TimeOfDay.from(cal.date(from: comps)!, calendar: cal) == .lateNight)
    }
}
