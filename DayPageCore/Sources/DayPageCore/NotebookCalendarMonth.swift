import Foundation

/// A presentation-only Gregorian month. Saved day keys never adopt the user's
/// alternate calendar; locale, first weekday and local time zone still apply.
public struct NotebookCalendarMonth {
    public struct Day: Equatable, Sendable, Identifiable {
        public let key: String
        public let number: Int
        public let date: Date
        public let title: String
        public var id: String { key }
    }

    public let monthKey: String
    public let title: String
    /// Complete weeks, with blank cells outside this month.
    public let days: [Day?]
    /// Foundation weekday numbering: Sunday is 1, Saturday is 7.
    public let weekdayNumbers: [Int]
    public let weekdaySymbols: [String]
    public let weekdayNames: [String]

    private let calendar: Calendar
    private let locale: Locale
    private let firstDate: Date

    public init?(containing day: String, calendar source: Calendar = .current, locale: Locale = .current) {
        guard Self.date(for: day, timeZone: source.timeZone) != nil,
              (1...7).contains(source.firstWeekday) else { return nil }
        let monthKey = String(day.prefix(7))
        guard let firstDate = Self.date(for: monthKey + "-01", timeZone: source.timeZone) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = source.timeZone
        calendar.firstWeekday = source.firstWeekday
        guard let range = calendar.range(of: .day, in: .month, for: firstDate) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = source.timeZone
        formatter.dateStyle = .full
        let dates = range.compactMap { number -> Day? in
            let key = monthKey + String(format: "-%02d", number)
            guard let date = Self.date(for: key, timeZone: source.timeZone) else { return nil }
            return Day(key: key, number: number, date: date, title: formatter.string(from: date))
        }
        guard dates.count == range.count else { return nil }

        let leading = (calendar.component(.weekday, from: firstDate) - calendar.firstWeekday + 7) % 7
        var cells = Array<Day?>(repeating: nil, count: leading) + dates.map(Optional.some)
        let trailing = (7 - cells.count % 7) % 7
        cells.append(contentsOf: Array<Day?>(repeating: nil, count: trailing))

        formatter.dateStyle = .none
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        self.monthKey = monthKey
        title = formatter.string(from: firstDate)
        days = cells
        weekdayNumbers = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        weekdaySymbols = weekdayNumbers.map { calendar.veryShortStandaloneWeekdaySymbols[$0 - 1] }
        weekdayNames = weekdayNumbers.map { calendar.standaloneWeekdaySymbols[$0 - 1] }
        self.calendar = calendar
        self.locale = locale
        self.firstDate = firstDate
    }

    public func addingMonths(_ value: Int) -> Self? {
        guard let date = calendar.date(byAdding: .month, value: value, to: firstDate) else { return nil }
        let components = calendar.dateComponents([.era, .year], from: date)
        guard components.era == 1, let year = components.year, (1...9999).contains(year) else { return nil }
        return Self(containing: Self.dayKey(for: date, timeZone: calendar.timeZone), calendar: calendar, locale: locale)
    }

    /// Resolve a strict ASCII Gregorian day at local noon. Noon avoids midnight
    /// DST transitions without interpreting a stored day key as an absolute UTC day.
    public static func date(for day: String, timeZone: TimeZone = .current) -> Date? {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }),
              let year = Int(day.prefix(4)), (1...9999).contains(year),
              let month = Int(day.dropFirst(5).prefix(2)), (1...12).contains(month),
              let number = Int(day.suffix(2)), (1...31).contains(number) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(timeZone: timeZone, era: 1, year: year, month: month, day: number, hour: 12)
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard resolved.era == 1, resolved.year == year,
              resolved.month == month, resolved.day == number else { return nil }
        return date
    }

    public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
