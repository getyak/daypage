import Foundation

enum RelativeDate {
    enum Style {
        case caps
        case natural
    }

    static func label(for dateString: String, style: Style = .caps) -> String {
        guard let date = Self.isoParser.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        let now = Date()

        switch style {
        case .caps:
            if cal.isDateInToday(date) { return "TODAY" }
            if cal.isDateInYesterday(date) { return "YESTERDAY" }
            let daysDiff = cal.dateComponents([.day], from: date, to: now).day ?? 0
            if daysDiff > 0 && daysDiff < 7 { return "\(daysDiff) DAYS AGO" }
            return Self.fullDateFormatter.string(from: date).uppercased()

        case .natural:
            // Natural style feeds content rows (sidebar Recent list) — it must
            // follow the UI locale. Hardcoded "Today" next to the 「今日」 nav
            // item read as two different products (FINDING-012). `.caps` stays
            // English by design: it's the archival mono-label register.
            if cal.isDateInToday(date) {
                return NSLocalizedString("relative.date.today", value: "今天", comment: "Relative date — today")
            }
            if cal.isDateInYesterday(date) {
                return NSLocalizedString("relative.date.yesterday", value: "昨天", comment: "Relative date — yesterday")
            }
            let daysDiff = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
            if daysDiff < 7 { return Self.weekdayFormatter.string(from: date) }
            return Self.shortMonthDayFormatter.string(from: date)
        }
    }

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
