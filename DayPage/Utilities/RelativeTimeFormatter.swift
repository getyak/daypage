import Foundation

/// Human-friendly relative date strings: TODAY · 14:23 / YESTERDAY · 14:23 / 3 DAYS AGO · APR 14 / APR 14, 2026
enum RelativeTimeFormatter {

    static func relative(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let hhmm = timeString(date)

        if cal.isDate(date, inSameDayAs: now) {
            return "TODAY · \(hhmm)"
        }

        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(date, inSameDayAs: yesterday) {
            return "YESTERDAY · \(hhmm)"
        }

        let daysDiff = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if daysDiff > 0 && daysDiff < 7 {
            let monthDay = monthDayString(date)
            return "\(daysDiff) DAYS AGO · \(monthDay)"
        }

        return longDateString(date)
    }

    // MARK: - Private formatters (shared; DateFormatter is thread-safe after init)

    private static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Private helpers

    private static func timeString(_ date: Date) -> String {
        hhmmFormatter.string(from: date)
    }

    private static func monthDayString(_ date: Date) -> String {
        monthDayFormatter.string(from: date).uppercased()
    }

    private static func longDateString(_ date: Date) -> String {
        longDateFormatter.string(from: date).uppercased()
    }
}
