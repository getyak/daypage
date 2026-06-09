import Testing
@testable import DayPage

/// Verifies the "On This Day" header renders natural, grammatically-correct
/// relative copy — clean month multiples collapse to months, and singular
/// counts never read as "1 DAYS AGO".
@Suite("OnThisDayHeaderTests")
struct OnThisDayHeaderTests {

    @Test func collapsesCleanMonthMultiples() {
        #expect(OnThisDayCard.relativeSpan(days: 180) == "6 MONTHS AGO")
        #expect(OnThisDayCard.relativeSpan(days: 90) == "3 MONTHS AGO")
    }

    @Test func singleMonthIsSingular() {
        #expect(OnThisDayCard.relativeSpan(days: 30) == "1 MONTH AGO")
    }

    @Test func singleDayIsSingular() {
        #expect(OnThisDayCard.relativeSpan(days: 1) == "1 DAY AGO")
    }

    @Test func nonMonthMultiplesStayInDays() {
        #expect(OnThisDayCard.relativeSpan(days: 5) == "5 DAYS AGO")
        #expect(OnThisDayCard.relativeSpan(days: 100) == "100 DAYS AGO")
    }
}
