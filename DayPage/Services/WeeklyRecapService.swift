import Foundation

// MARK: - WeeklyRecapRange

/// Pure date-range helper for the Weekly Recap section.
///
/// Extracts the date-math from `WeeklyRecapService` so it can be unit-tested
/// independently with an injected calendar.
enum WeeklyRecapRange {

    /// Returns local-midnight dates in [min(weekStart, yesterday), today),
    /// oldest-first. The `min` rule prevents the range from being empty on
    /// Mondays — without it, Monday's weekStart == today and the section vanishes.
    static func dates(referenceDate: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: referenceDate)
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return [] }

        let lowerBound = min(monday, yesterday)

        var cursor = lowerBound
        var result: [Date] = []
        while cursor < today {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}

// MARK: - WeeklyRecapEntry

/// One compiled day appearing in Today's "Weekly Recap" section.
///
/// Phase 1 only carries day-level compiled entries; Phase 2/3 will extend this
/// into an enum (`case day | week | month | year`). Keeping it flat for now
/// avoids speculative abstraction.
struct WeeklyRecapEntry: Identifiable, Equatable {

    /// `yyyy-MM-dd`, also stable id (at most one compiled entry per date).
    let dateString: String

    /// Local-timezone midnight of the compiled day.
    let date: Date

    /// Frontmatter `summary:` value; nil/empty if unset or unreadable.
    let summary: String?

    var id: String { dateString }
}

// MARK: - WeeklyRecapService

/// Loads the Today screen's "Weekly Recap" section data.
///
/// Range (Phase 1):
/// - Start (inclusive): the earlier of (a) Monday 00:00 of the week containing
///   `referenceDate`, or (b) yesterday 00:00. The `min(...)` rule guarantees
///   yesterday is always in range — without it, opening the app on a Monday
///   collapses the range to empty and the Recap section disappears, which
///   reads as a bug. Phase 2 will introduce a separate weekly-compilation
///   feed for last week, removing the need for this overlap.
/// - End (exclusive): Today 00:00 — today's raw memos render in TodayView's
///   own timeline, so we never duplicate today here even if its daily page
///   exists.
///
/// Returns newest-first. Days without a `vault/wiki/daily/{date}.md` file are
/// silently skipped (a missing file means "not compiled yet", not an error).
@MainActor
final class WeeklyRecapService {

    static let shared = WeeklyRecapService()

    private let calendar: Calendar
    private let dateFormatter: DateFormatter

    private init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 2  // Monday — matches Archive calendar convention
        self.calendar = cal

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        self.dateFormatter = f
    }

    /// Compiled day entries from this week's Monday up to (but not including)
    /// `referenceDate`'s local-midnight, newest first.
    /// On Monday, returns exactly yesterday (Sunday) — see `WeeklyRecapRange`.
    func entries(referenceDate: Date = Date()) -> [WeeklyRecapEntry] {
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")
        let fm = FileManager.default
        let dates = WeeklyRecapRange.dates(referenceDate: referenceDate, calendar: calendar)

        var entries: [WeeklyRecapEntry] = []
        for date in dates {
            let dateStr = dateFormatter.string(from: date)
            let url = dailyDir.appendingPathComponent("\(dateStr).md")
            guard fm.fileExists(atPath: url.path) else { continue }

            let summary: String?
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                summary = FrontmatterParser.extractField("summary", from: content)
            } else {
                summary = nil
            }

            entries.append(WeeklyRecapEntry(
                dateString: dateStr,
                date: date,
                summary: summary
            ))
        }

        return entries.reversed()
    }

}
