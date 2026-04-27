import Foundation

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
    /// Returns empty when `referenceDate` falls on Monday.
    func entries(referenceDate: Date = Date()) -> [WeeklyRecapEntry] {
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")
        let fm = FileManager.default

        let today = calendar.startOfDay(for: referenceDate)
        guard let monday = startOfWeek(for: today),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return [] }
        // Whichever is earlier — usually Monday, but on Monday itself the
        // Monday-only range would be empty, so yesterday (Sunday) takes over.
        let lowerBound = min(monday, yesterday)

        var cursor = lowerBound
        var dates: [Date] = []
        while cursor < today {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var entries: [WeeklyRecapEntry] = []
        for date in dates {
            let dateStr = dateFormatter.string(from: date)
            let url = dailyDir.appendingPathComponent("\(dateStr).md")
            guard fm.fileExists(atPath: url.path) else { continue }

            let summary: String?
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                summary = Self.extractSummary(from: content)
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

    // MARK: - Private

    /// Monday 00:00 of the week containing `date`.
    /// `dateInterval(of: .weekOfYear, for:)` honors `calendar.firstWeekday`,
    /// which we forced to Monday in init.
    private func startOfWeek(for date: Date) -> Date? {
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }

    /// Extract `summary:` from a daily page's frontmatter. Behaviour matches
    /// `ArchiveView.extractSummary` and `TodayViewModel.extractSummary`; kept
    /// local so Phase 2 (weekly/monthly compilations with different schemas)
    /// can extend parsing here without touching unrelated callers.
    static func extractSummary(from content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("summary:") {
                let value = String(trimmed.dropFirst("summary:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
