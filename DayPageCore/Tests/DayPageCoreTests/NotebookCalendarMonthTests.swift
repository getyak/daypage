import XCTest
@testable import DayPageCore

final class NotebookCalendarMonthTests: XCTestCase {
    private func calendar(
        firstWeekday: Int = 1,
        timeZone: String = "UTC",
        identifier: Calendar.Identifier = .gregorian
    ) throws -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    func testLeapFebruaryKeepsAll29CanonicalDaysAndWeekPadding() throws {
        let month = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2024-02-29", calendar: calendar(), locale: Locale(identifier: "en_US")))
        XCTAssertEqual(month.monthKey, "2024-02")
        XCTAssertEqual(month.days.count, 35)
        XCTAssertTrue(month.days.prefix(4).allSatisfy { $0 == nil })
        XCTAssertEqual(month.days[4]?.key, "2024-02-01")
        XCTAssertEqual(month.days[32]?.key, "2024-02-29")
        XCTAssertEqual(month.days.compactMap { $0 }.count, 29)
        XCTAssertTrue(month.days.suffix(2).allSatisfy { $0 == nil })
    }

    func testMondayFirstMovesGridAndWeekdayHeadingsTogether() throws {
        let month = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2027-01-15", calendar: calendar(firstWeekday: 2),
            locale: Locale(identifier: "en_GB")))
        XCTAssertEqual(month.weekdayNumbers, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(month.weekdayNames.first, "Monday")
        XCTAssertEqual(month.days.count, 35)
        XCTAssertTrue(month.days.prefix(4).allSatisfy { $0 == nil })
        XCTAssertEqual(month.days[4]?.key, "2027-01-01")
        XCTAssertEqual(month.days.compactMap { $0 }.last?.key, "2027-01-31")
    }

    func testSundayFirstJanuaryCanUseSixWeeks() throws {
        let month = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2027-01-15", calendar: calendar(), locale: Locale(identifier: "en_US")))
        XCTAssertEqual(month.weekdayNumbers, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(month.days.count, 42)
        XCTAssertEqual(month.days[5]?.key, "2027-01-01")
        XCTAssertEqual(month.days[35]?.key, "2027-01-31")
    }

    func testExactFourWeekMonthHasNoFabricatedNeighborDates() throws {
        let month = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2026-02-12", calendar: calendar()))
        XCTAssertEqual(month.days.count, 28)
        XCTAssertEqual(month.days.compactMap { $0 }.first?.key, "2026-02-01")
        XCTAssertEqual(month.days.compactMap { $0 }.last?.key, "2026-02-28")
    }

    func testMonthNavigationCrossesYearAndLeapDayWithoutClampingSelection() throws {
        let january = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2024-01-31", calendar: calendar()))
        let previous = try XCTUnwrap(january.addingMonths(-1))
        let next = try XCTUnwrap(january.addingMonths(1))
        XCTAssertEqual(previous.monthKey, "2023-12")
        XCTAssertEqual(previous.days.compactMap { $0 }.last?.key, "2023-12-31")
        XCTAssertEqual(next.monthKey, "2024-02")
        XCTAssertEqual(next.days.compactMap { $0 }.last?.key, "2024-02-29")
        XCTAssertEqual(next.addingMonths(10)?.monthKey, "2024-12")
        XCTAssertEqual(previous.addingMonths(1)?.monthKey, "2024-01")
    }

    func testCanonicalParserRejectsNormalizedAndNoncanonicalDates() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        for day in [
            "2026-02-29", "1900-02-29", "2100-02-29", "2024-04-31", "2024-13-01",
            "2024-00-01", "2024-01-00", "2024-2-01", "24-02-01", "2024-02-01x",
            " 2024-02-01", "2024-02-01 ", "２０２４-０２-０１", "0000-01-01",
        ] {
            XCTAssertNil(NotebookCalendarMonth.date(for: day, timeZone: zone), day)
        }
        XCTAssertNotNil(NotebookCalendarMonth.date(for: "2000-02-29", timeZone: zone))
        XCTAssertNotNil(NotebookCalendarMonth.date(for: "2024-02-29", timeZone: zone))
    }

    func testDayKeyUsesLocalDayOnBothSidesOfInternationalDateLine() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T12:30:00Z"))
        let east = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let west = try XCTUnwrap(TimeZone(identifier: "Pacific/Pago_Pago"))
        XCTAssertEqual(NotebookCalendarMonth.dayKey(for: instant, timeZone: east), "2027-01-01")
        XCTAssertEqual(NotebookCalendarMonth.dayKey(for: instant, timeZone: west), "2026-12-31")
    }

    func testSpringDSTMonthContainsEachLocalDayExactlyOnce() throws {
        let calendar = try calendar(firstWeekday: 2, timeZone: "America/Los_Angeles")
        let month = try XCTUnwrap(NotebookCalendarMonth(containing: "2026-03-08", calendar: calendar))
        let days = month.days.compactMap { $0 }
        XCTAssertEqual(days.count, 31)
        XCTAssertEqual(Set(days.map(\.key)).count, 31)
        XCTAssertEqual(days[7].key, "2026-03-08")
        XCTAssertEqual(days[8].key, "2026-03-09")
        for day in days {
            XCTAssertEqual(NotebookCalendarMonth.dayKey(for: day.date, timeZone: calendar.timeZone), day.key)
        }
    }

    func testBuddhistUserCalendarDoesNotChangeCanonicalYearOrLeapDay() throws {
        let month = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2024-02-29",
            calendar: calendar(firstWeekday: 2, timeZone: "Asia/Bangkok", identifier: .buddhist),
            locale: Locale(identifier: "th_TH")))
        XCTAssertEqual(month.monthKey, "2024-02")
        XCTAssertEqual(month.days.compactMap { $0 }.count, 29)
        XCTAssertEqual(month.days.compactMap { $0 }.last?.key, "2024-02-29")
        XCTAssertFalse(month.title.contains("2567"))
        XCTAssertEqual(month.addingMonths(1)?.monthKey, "2024-03")
    }

    func testIslamicUserCalendarStillShowsGregorianMonth() throws {
        let month = try XCTUnwrap(NotebookCalendarMonth(
            containing: "2026-12-31",
            calendar: calendar(firstWeekday: 7, timeZone: "Asia/Riyadh", identifier: .islamicUmmAlQura),
            locale: Locale(identifier: "ar_SA")))
        XCTAssertEqual(month.monthKey, "2026-12")
        XCTAssertEqual(month.weekdayNumbers, [7, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(month.days.compactMap { $0 }.count, 31)
        XCTAssertEqual(month.addingMonths(1)?.monthKey, "2027-01")
    }

    func testMonthNavigationStopsAtCanonicalFourDigitYearBoundary() throws {
        let first = try XCTUnwrap(NotebookCalendarMonth(containing: "0001-01-01", calendar: calendar()))
        let last = try XCTUnwrap(NotebookCalendarMonth(containing: "9999-12-31", calendar: calendar()))
        XCTAssertNil(first.addingMonths(-1))
        XCTAssertNil(last.addingMonths(1))
    }
}
