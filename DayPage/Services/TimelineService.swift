import Foundation

// MARK: - TimelineDayEntry

/// One day in the Today timeline. Carries enough metadata to render the
/// collapsed card (date + summary + memo count) without re-reading the file;
/// the raw memos themselves are loaded lazily on demand when the card is
/// expanded, so an opening cold scroll doesn't pay the parse cost for every
/// historical day.
struct TimelineDayEntry: Identifiable, Equatable {

    /// `yyyy-MM-dd`. Stable id (at most one entry per date).
    let dateString: String

    /// Local-timezone midnight of the day.
    let date: Date

    /// Number of raw memos parsed from the day file.
    let memoCount: Int

    /// Frontmatter `summary:` from `vault/wiki/daily/{date}.md`, if compiled.
    /// nil/empty when the day has not been AI-compiled yet.
    let summary: String?

    var id: String { dateString }

    static func == (lhs: TimelineDayEntry, rhs: TimelineDayEntry) -> Bool {
        lhs.dateString == rhs.dateString &&
        lhs.memoCount == rhs.memoCount &&
        lhs.summary == rhs.summary
    }
}

// MARK: - TimelineSectionKind

/// Identifies which time band a section represents. The view layer maps this
/// to a localized title; the service stays locale-agnostic.
enum TimelineSectionKind: Hashable {
    /// User-pinned days, surfaced at the very top of the timeline. Days in
    /// this section are *removed* from their natural time-band section so the
    /// pin acts as a single source of truth — no duplicate rows.
    case pinned
    case thisWeekOthers
    case lastWeek
    case weekBeforeLast
    /// Month bucket for entries older than three weeks back. Carries the first
    /// day of that month for label formatting (e.g. "2026-04-01" → "April 2026").
    case month(Date)
}

// MARK: - TimelineSection

struct TimelineSection: Identifiable, Equatable {

    let kind: TimelineSectionKind

    /// Newest-first within a section.
    let days: [TimelineDayEntry]

    var id: String {
        switch kind {
        case .pinned: return "pinned"
        case .thisWeekOthers: return "thisWeekOthers"
        case .lastWeek: return "lastWeek"
        case .weekBeforeLast: return "weekBeforeLast"
        case .month(let date):
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = AppSettings.currentTimeZone()
            return "month-\(f.string(from: date))"
        }
    }

    static func == (lhs: TimelineSection, rhs: TimelineSection) -> Bool {
        lhs.kind == rhs.kind && lhs.days == rhs.days
    }
}

// MARK: - TimelineService

/// Scans `vault/raw/*.md` and produces the Today timeline grouped into
/// time bands: this-week-others / last week / week-before-last / older
/// buckets by calendar month.
///
/// The service is intentionally nonisolated and stateless — all heavy I/O
/// happens off the main actor. The week boundary respects the user's system
/// `Calendar.current.firstWeekday` (per CLAUDE.md guidance).
enum TimelineService {

    // MARK: - Public entry points

    /// All days that contain at least one raw memo, newest-first. Includes
    /// today when today has memos; callers exclude it via `group(...)` when
    /// rendering the timeline separately from the active composer day.
    ///
    /// Backed by `TimelineIndex` (O(1) cached read). The expensive disk scan
    /// lives in `scanAllEntries()` and runs only on index rebuild, not on every
    /// call. `referenceDate` is retained for source-compatibility with existing
    /// call sites; ordering is date-based inside the index.
    @MainActor
    static func entries(referenceDate: Date = Date()) -> [TimelineDayEntry] {
        TimelineIndex.shared.entries()
    }

    /// The actual full scan of `vault/raw/*.md`: reads + parses every day file
    /// and pairs each with its compiled daily-page summary. This is the
    /// expensive O(total memos) operation that `TimelineIndex` caches; it runs
    /// only on rebuild, never on the per-call hot path.
    ///
    /// `nonisolated` so `TimelineIndex` can run it inside `Task.detached` off
    /// the main actor.
    nonisolated static func scanAllEntries() -> [TimelineDayEntry] {
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rawDir, includingPropertiesForKeys: nil) else {
            return []
        }

        let fmt = scanDateFormatter()
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")

        var result: [TimelineDayEntry] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let date = fmt.date(from: stem) else { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let memos = RawStorage.parse(fileContent: content)
            guard !memos.isEmpty else { continue }

            result.append(TimelineDayEntry(
                dateString: stem,
                date: date,
                memoCount: memos.count,
                summary: summary(forDateString: stem, dailyDir: dailyDir)
            ))
        }

        return result.sorted { $0.date > $1.date }
    }

    /// Scans a single day file by `yyyy-MM-dd` stem. Returns nil when the file
    /// is missing or has no parseable memos (the day should be absent from the
    /// timeline). Used by `TimelineIndex` for O(today) incremental updates.
    nonisolated static func scanEntry(forDateString stem: String) -> TimelineDayEntry? {
        let fmt = scanDateFormatter()
        guard let date = fmt.date(from: stem) else { return nil }

        let rawURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(stem).md")
        guard let content = try? String(contentsOf: rawURL, encoding: .utf8) else { return nil }
        let memos = RawStorage.parse(fileContent: content)
        guard !memos.isEmpty else { return nil }

        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")
        return TimelineDayEntry(
            dateString: stem,
            date: date,
            memoCount: memos.count,
            summary: summary(forDateString: stem, dailyDir: dailyDir)
        )
    }

    /// Reads the compiled daily-page `summary:` for a day, if compiled.
    /// Missing file is normal (day not yet AI-compiled) — returns nil silently.
    nonisolated private static func summary(forDateString stem: String, dailyDir: URL) -> String? {
        let dailyURL = dailyDir.appendingPathComponent("\(stem).md")
        guard let dailyContent = try? String(contentsOf: dailyURL, encoding: .utf8) else { return nil }
        return FrontmatterParser.extractField("summary", from: dailyContent)
    }

    nonisolated private static func scanDateFormatter() -> DateFormatter {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = AppSettings.currentTimeZone()
        return fmt
    }

    /// Groups timeline entries into the four bands described above, hiding any
    /// section whose `days` list is empty. The "today" entry is excluded from
    /// every section — the view layer renders today separately at the top.
    ///
    /// User-pinned days bubble up into a leading "📌 PINNED" section and are
    /// removed from their natural time band, so a pin acts as a single source
    /// of truth without producing a duplicate row.
    @MainActor
    static func sections(referenceDate: Date = Date()) -> [TimelineSection] {
        let all = entries(referenceDate: referenceDate)
        let pinned = TimelinePinService.shared.pinned
        return group(entries: all, referenceDate: referenceDate, pinnedDateStrings: pinned)
    }

    /// Loads the raw memos for one timeline day on demand. Returns memos in
    /// the same newest-first + pinned-on-top order as TodayViewModel uses for
    /// today, so an expanded card reads consistently with the active day.
    static func memos(for entry: TimelineDayEntry) -> [Memo] {
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(entry.dateString).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return RawStorage.parse(fileContent: content).sorted { lhs, rhs in
            if lhs.pinnedAt != nil && rhs.pinnedAt == nil { return true }
            if lhs.pinnedAt == nil && rhs.pinnedAt != nil { return false }
            if let lp = lhs.pinnedAt, let rp = rhs.pinnedAt { return lp > rp }
            return lhs.created > rhs.created
        }
    }

    // MARK: - Grouping (testable in isolation)

    /// Pure function: classify pre-loaded entries into sections. Exposed at
    /// internal scope so future unit tests can exercise the boundary math
    /// without touching the file system.
    ///
    /// `pinnedDateStrings` are pulled out into a leading `.pinned` section and
    /// excluded from their natural time band; passing an empty set yields the
    /// original four-band layout for backward-compatible call sites and tests.
    static func group(
        entries: [TimelineDayEntry],
        referenceDate: Date,
        pinnedDateStrings: Set<String> = []
    ) -> [TimelineSection] {
        let cal = systemCalendar()
        let today = cal.startOfDay(for: referenceDate)

        guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart),
              let weekBeforeStart = cal.date(byAdding: .weekOfYear, value: -2, to: thisWeekStart)
        else { return [] }

        var pinned: [TimelineDayEntry] = []
        var thisWeekOthers: [TimelineDayEntry] = []
        var lastWeek: [TimelineDayEntry] = []
        var weekBeforeLast: [TimelineDayEntry] = []
        var byMonth: [Date: [TimelineDayEntry]] = [:]

        for entry in entries {
            let day = cal.startOfDay(for: entry.date)
            if day == today { continue }                  // today rendered separately

            // Pinned days bubble up regardless of their natural time band.
            if pinnedDateStrings.contains(entry.dateString) {
                pinned.append(entry)
                continue
            }

            if day >= thisWeekStart {
                thisWeekOthers.append(entry)
            } else if day >= lastWeekStart {
                lastWeek.append(entry)
            } else if day >= weekBeforeStart {
                weekBeforeLast.append(entry)
            } else {
                // Bucket by first-of-month so two days in the same month share a section.
                let comps = cal.dateComponents([.year, .month], from: day)
                if let monthStart = cal.date(from: comps) {
                    byMonth[monthStart, default: []].append(entry)
                }
            }
        }

        var sections: [TimelineSection] = []
        // Pinned first, newest-first within the section.
        if !pinned.isEmpty {
            sections.append(TimelineSection(kind: .pinned, days: pinned.sorted { $0.date > $1.date }))
        }
        if !thisWeekOthers.isEmpty {
            sections.append(TimelineSection(kind: .thisWeekOthers, days: thisWeekOthers))
        }
        if !lastWeek.isEmpty {
            sections.append(TimelineSection(kind: .lastWeek, days: lastWeek))
        }
        if !weekBeforeLast.isEmpty {
            sections.append(TimelineSection(kind: .weekBeforeLast, days: weekBeforeLast))
        }
        // Months newest-first; days inside each month already newest-first thanks to
        // the source ordering.
        let months = byMonth.keys.sorted(by: >)
        for monthStart in months {
            let days = byMonth[monthStart] ?? []
            sections.append(TimelineSection(kind: .month(monthStart), days: days))
        }
        return sections
    }

    // MARK: - Helpers

    /// Calendar honoring the user's system `firstWeekday` setting. Mirrors
    /// what SwiftUI's date pickers use, so "this week" matches what the user
    /// sees elsewhere in the OS.
    private static func systemCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = Calendar.current.firstWeekday
        cal.timeZone = AppSettings.currentTimeZone()
        return cal
    }

}
