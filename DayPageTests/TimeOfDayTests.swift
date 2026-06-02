import Testing
import SwiftUI
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
