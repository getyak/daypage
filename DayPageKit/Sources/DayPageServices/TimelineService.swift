import Foundation
import DayPageModels
import DayPageStorage

// MARK: - TimelineDayEntry

/// One day in the Today timeline. Carries enough metadata to render the
/// collapsed card (date + summary + memo count) without re-reading the file;
/// a bounded preview payload is derived during the index scan, so an opening
/// cold scroll doesn't reopen and parse every historical day.
public struct TimelineDayEntry: Identifiable, Equatable, Sendable {

    /// `yyyy-MM-dd`. Stable id (at most one entry per date). Also the
    /// canonical Gregorian civil identity of the owning file
    /// (`vault/raw/YYYY-MM-DD.md`) — grouping and display must derive from
    /// this key, never from `date`.
    public let dateString: String

    /// Derived scan artifact: the scan's zone-local midnight of the day. It
    /// is NOT a memo timestamp and NOT stable across preferred-zone switches
    /// (a warm cache keeps values from the zone it was scanned in). Never
    /// reinterpret it under another zone; classification and labels use
    /// `dateString` instead.
    public let date: Date

    /// Number of raw memos parsed from the day file.
    public let memoCount: Int

    /// Frontmatter `summary:` from `vault/wiki/daily/{date}.md`, if compiled.
    /// nil/empty when the day has not been AI-compiled yet.
    public let summary: String?

    /// First non-empty line of the day's earliest memo. Gives an
    /// uncompiled day a content scent in the timeline row instead of a
    /// serif date that would duplicate the nameplate. nil when the day's
    /// memos carry no text (e.g. photo-only captures).
    public let excerpt: String?

    /// Up to three short memo lines for the context-menu preview. These are
    /// derived during the index scan so merely scrolling historical rows never
    /// reopens and reparses the underlying Markdown file.
    public let previewLines: [String]

    public var id: String { dateString }

    /// Deterministic construction point used by the scanner and by tests that
    /// build warm caches carrying deliberately stale `date` values.
    public init(dateString: String, date: Date, memoCount: Int, summary: String?,
                excerpt: String?, previewLines: [String]) {
        self.dateString = dateString
        self.date = date
        self.memoCount = memoCount
        self.summary = summary
        self.excerpt = excerpt
        self.previewLines = previewLines
    }

    public static func == (lhs: TimelineDayEntry, rhs: TimelineDayEntry) -> Bool {
        lhs.dateString == rhs.dateString &&
        lhs.memoCount == rhs.memoCount &&
        lhs.summary == rhs.summary &&
        lhs.excerpt == rhs.excerpt &&
        lhs.previewLines == rhs.previewLines
    }
}

// MARK: - TimelineSectionKind

/// Identifies which time band a section represents. The view layer maps this
/// to a localized title; the service stays locale-agnostic.
public enum TimelineSectionKind: Hashable {
    /// User-pinned days, surfaced at the very top of the timeline. Days in
    /// this section are *removed* from their natural time-band section so the
    /// pin acts as a single source of truth — no duplicate rows.
    case pinned
    case thisWeekOthers
    case lastWeek
    case weekBeforeLast
    /// Month bucket for entries older than three weeks back. Carries the
    /// owning civil month's first day as a timezone-neutral Gregorian instant
    /// (see `TimelineDayKey.startOfMonth`) so label formatting (e.g.
    /// "2026-04-01" → "April 2026") can never shift into the previous month
    /// under a negative-offset system zone.
    case month(Date)
}

// MARK: - TimelineSection

public struct TimelineSection: Identifiable, Equatable {

    public let kind: TimelineSectionKind

    /// Newest-first within a section.
    public let days: [TimelineDayEntry]

    public init(kind: TimelineSectionKind, days: [TimelineDayEntry]) {
        self.kind = kind
        self.days = days
    }

    public var id: String {
        switch kind {
        case .pinned: return "pinned"
        case .thisWeekOthers: return "thisWeekOthers"
        case .lastWeek: return "lastWeek"
        case .weekBeforeLast: return "weekBeforeLast"
        case .month(let date):
            // The payload is the owning civil month's first day in the neutral
            // calendar; read the civil month back through the same neutral
            // calendar so the id stays stable across zone switches.
            let comps = TimelineDayKey.neutralCalendar().dateComponents([.year, .month], from: date)
            return String(format: "month-%04d-%02d", comps.year ?? 0, comps.month ?? 0)
        }
    }

    public static func == (lhs: TimelineSection, rhs: TimelineSection) -> Bool {
        lhs.kind == rhs.kind && lhs.days == rhs.days
    }
}

// MARK: - TimelineDayKey

/// Strict canonical `yyyy-MM-dd` day-key handling for the timeline.
///
/// A canonical day key is the Gregorian civil identity of the owning raw file
/// (`vault/raw/YYYY-MM-DD.md`) — not a timestamp and not a zone-local
/// midnight. All parsing and arithmetic here therefore run through a
/// timezone-neutral (fixed UTC offset) Gregorian calendar:
///
///  - Parsing is strict and fails closed on malformed or impossible keys
///    (`2026-02-30`, `2025-02-29`, `2026-13-01`, `2026-10-3`, …).
///  - Classification never re-derives the owning day through a zone-local
///    midnight parse, so a civil day skipped by some zone's local midnight
///    (Pacific/Apia skipped 2011-12-30) still owns a valid file day.
///  - Month payloads are civil month starts, so a negative-offset display
///    zone can never render the previous month for a month-first instant.
public enum TimelineDayKey {

    /// Gregorian year/month/day of one owning civil day.
    public struct Day: Hashable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    /// Fixed UTC-offset zone used only as a neutral carrier for civil
    /// arithmetic — never as a display or reference boundary zone. The API is
    /// optional-typed; the fallback chain keeps production force-unwrap-free
    /// while remaining constant in practice.
    public static let neutralTimeZone: TimeZone =
        TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC") ?? TimeZone.current

    /// Neutral Gregorian calendar for civil key math. `firstWeekday` is
    /// injectable so week-band boundaries honor the user's calendar setting
    /// without reading global state inside the pure arithmetic.
    public static func neutralCalendar(firstWeekday: Int? = nil) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = neutralTimeZone
        if let firstWeekday { cal.firstWeekday = firstWeekday }
        return cal
    }

    /// Strict `yyyy-MM-dd` parse. Fails closed on anything non-canonical,
    /// including calendar-impossible dates like 2026-02-30.
    public static func day(fromKey key: String) -> Day? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = decimalValue(parts[0]),
              let month = decimalValue(parts[1]),
              let day = decimalValue(parts[2]) else { return nil }
        // Round-trip through the neutral calendar so DateComponents overflow
        // (Feb 30 → Mar 2) cannot sneak past the canonical form check.
        let cal = neutralCalendar()
        guard let anchor = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let roundTrip = cal.dateComponents([.year, .month, .day], from: anchor)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return Day(year: year, month: month, day: day)
    }

    /// The owning civil day of an absolute instant in `timeZone`. Used only to
    /// project the reference "today" boundary — never to reinterpret a cached
    /// entry key.
    public static func day(for instant: Date, in timeZone: TimeZone) -> Day {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: instant)
        return Day(year: comps.year ?? 0, month: comps.month ?? 1, day: comps.day ?? 1)
    }

    /// Neutral midnight of a civil day (classification anchor).
    public static func startOfDay(for day: Day) -> Date? {
        neutralCalendar().date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    /// Neutral first-of-month of the owning civil month (`.month` payload).
    public static func startOfMonth(for day: Day) -> Date? {
        neutralCalendar().date(from: DateComponents(year: day.year, month: day.month))
    }

    private static func decimalValue(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(digits)
    }
}

// MARK: - TimelineService

/// Scans `vault/raw/*.md` and produces the Today timeline grouped into
/// time bands: this-week-others / last week / week-before-last / older
/// buckets by calendar month.
///
/// The service is intentionally nonisolated and stateless — all heavy I/O
/// happens off the main actor. Week bands follow an injectable
/// `firstWeekday` (default: the user's system `Calendar.current.firstWeekday`,
/// per CLAUDE.md guidance) and classify strictly by canonical `dateString`
/// (see `TimelineDayKey`).
public enum TimelineService {

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
    public static func entries(referenceDate: Date = Date()) -> [TimelineDayEntry] {
        TimelineIndex.shared.entries()
    }

    /// The actual full scan of `vault/raw/*.md`: reads + parses every day file
    /// and pairs each with its compiled daily-page summary. This is the
    /// expensive O(total memos) operation that `TimelineIndex` caches; it runs
    /// only on rebuild, never on the per-call hot path.
    ///
    /// `nonisolated` so `TimelineIndex` can run it inside `Task.detached` off
    /// the main actor.
    public nonisolated static func scanAllEntries() -> [TimelineDayEntry] {
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
                summary: summary(forDateString: stem, dailyDir: dailyDir),
                excerpt: excerpt(from: memos),
                previewLines: previewLines(from: memos)
            ))
        }

        return result.sorted { $0.date > $1.date }
    }

    /// Scans a single day file by `yyyy-MM-dd` stem. Returns nil when the file
    /// is missing or has no parseable memos (the day should be absent from the
    /// timeline). Used by `TimelineIndex` for O(today) incremental updates.
    public nonisolated static func scanEntry(forDateString stem: String) -> TimelineDayEntry? {
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
            summary: summary(forDateString: stem, dailyDir: dailyDir),
            excerpt: excerpt(from: memos),
            previewLines: previewLines(from: memos)
        )
    }

    /// First non-empty line of the day's earliest memo, capped so the index
    /// stays lightweight. Used by the timeline row as the lede for days that
    /// have no compiled summary yet.
    nonisolated private static func excerpt(from memos: [Memo]) -> String? {
        guard let earliest = memos.min(by: { $0.created < $1.created }) else { return nil }
        let line = earliest.body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(120))
    }

    /// Lightweight preview payload, newest-first and capped by both item count
    /// and character count. Keeping it in the metadata index preserves the old
    /// long-press preview without a per-row disk read on scroll.
    nonisolated private static func previewLines(from memos: [Memo]) -> [String] {
        let lines = memos
            .sorted { lhs, rhs in
                if lhs.pinnedAt != nil && rhs.pinnedAt == nil { return true }
                if lhs.pinnedAt == nil && rhs.pinnedAt != nil { return false }
                if let leftPin = lhs.pinnedAt, let rightPin = rhs.pinnedAt {
                    return leftPin > rightPin
                }
                return lhs.created > rhs.created
            }
            .compactMap { memo -> String? in
                let line = memo.body
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                guard let line else { return nil }
                return String(line.prefix(180))
            }
        return Array(lines.prefix(3))
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
    public static func sections(referenceDate: Date = Date()) -> [TimelineSection] {
        let all = entries(referenceDate: referenceDate)
        let pinned = TimelinePinService.shared.pinned
        return group(entries: all, referenceDate: referenceDate, pinnedDateStrings: pinned)
    }

    /// Loads the raw memos for one timeline day on demand. Returns memos in
    /// the same newest-first + pinned-on-top order as TodayViewModel uses for
    /// today, so an expanded card reads consistently with the active day.
    public static func memos(for entry: TimelineDayEntry) -> [Memo] {
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
    /// Semantics (canonical-date repair):
    ///  - Every entry is classified STRICTLY by its canonical `yyyy-MM-dd`
    ///    `dateString` (Gregorian civil file identity). The scan-derived
    ///    `date` is never read, so warm caches carrying stale zone-midnight
    ///    values classify identically after a preferred-zone switch.
    ///  - Malformed keys fail closed: the entry is dropped, never guessed.
    ///  - The reference instant is projected to "today" with one per-call
    ///    `timeZone` snapshot (default: the completed preferred zone at call
    ///    time); the week bands follow `firstWeekday` (default:
    ///    `Calendar.current.firstWeekday`).
    ///  - All civil math runs in `TimelineDayKey`'s timezone-neutral Gregorian
    ///    calendar, so a zone-skipped local midnight still owns its file day
    ///    and the `.month` payload is the owning civil month's first day.
    ///  - The exact current canonical day is excluded (rendered separately);
    ///    pinned days surface newest-first by canonical key and leave their
    ///    natural band.
    ///
    /// `pinnedDateStrings` are pulled out into a leading `.pinned` section and
    /// excluded from their natural time band; passing an empty set yields the
    /// original four-band layout for backward-compatible call sites and tests.
    public static func group(
        entries: [TimelineDayEntry],
        referenceDate: Date,
        pinnedDateStrings: Set<String> = [],
        timeZone: TimeZone? = nil,
        firstWeekday: Int? = nil
    ) -> [TimelineSection] {
        // One explicit per-call zone snapshot drives the reference day only;
        // cached entries never get re-projected through it.
        let boundaryZone = timeZone ?? AppSettings.currentTimeZone()
        let cal = TimelineDayKey.neutralCalendar(
            firstWeekday: firstWeekday ?? Calendar.current.firstWeekday
        )

        let today = TimelineDayKey.day(for: referenceDate, in: boundaryZone)
        guard let todayStart = TimelineDayKey.startOfDay(for: today),
              let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: todayStart)?.start,
              let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart),
              let weekBeforeStart = cal.date(byAdding: .weekOfYear, value: -2, to: thisWeekStart)
        else { return [] }

        var pinned: [TimelineDayEntry] = []
        var thisWeekOthers: [TimelineDayEntry] = []
        var lastWeek: [TimelineDayEntry] = []
        var weekBeforeLast: [TimelineDayEntry] = []
        var byMonth: [Date: [TimelineDayEntry]] = [:]

        for entry in entries {
            // Fail closed on malformed keys — never guess an owning day.
            guard let key = TimelineDayKey.day(fromKey: entry.dateString),
                  let dayStart = TimelineDayKey.startOfDay(for: key) else { continue }
            if key == today { continue }                  // today rendered separately

            // Pinned days bubble up regardless of their natural time band.
            if pinnedDateStrings.contains(entry.dateString) {
                pinned.append(entry)
                continue
            }

            if dayStart >= thisWeekStart {
                thisWeekOthers.append(entry)
            } else if dayStart >= lastWeekStart {
                lastWeek.append(entry)
            } else if dayStart >= weekBeforeStart {
                weekBeforeLast.append(entry)
            } else {
                // Bucket by owning civil month so two days in the same month
                // share a section and the payload stays civil-month exact.
                if let monthStart = TimelineDayKey.startOfMonth(for: key) {
                    byMonth[monthStart, default: []].append(entry)
                }
            }
        }

        // Newest-first by canonical key inside every section — ordering must
        // not depend on the stale scan-derived `date` either.
        func newestFirst(_ list: [TimelineDayEntry]) -> [TimelineDayEntry] {
            list.sorted { $0.dateString > $1.dateString }
        }

        var sections: [TimelineSection] = []
        // Pinned first, newest-first within the section.
        if !pinned.isEmpty {
            sections.append(TimelineSection(kind: .pinned, days: newestFirst(pinned)))
        }
        if !thisWeekOthers.isEmpty {
            sections.append(TimelineSection(kind: .thisWeekOthers, days: newestFirst(thisWeekOthers)))
        }
        if !lastWeek.isEmpty {
            sections.append(TimelineSection(kind: .lastWeek, days: newestFirst(lastWeek)))
        }
        if !weekBeforeLast.isEmpty {
            sections.append(TimelineSection(kind: .weekBeforeLast, days: newestFirst(weekBeforeLast)))
        }
        // Months newest-first (the neutral payload orders chronologically).
        let months = byMonth.keys.sorted(by: >)
        for monthStart in months {
            let days = byMonth[monthStart] ?? []
            sections.append(TimelineSection(kind: .month(monthStart), days: newestFirst(days)))
        }
        return sections
    }

}
