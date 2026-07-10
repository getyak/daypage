import Foundation
import DayPageStorage

// MARK: - DateFormatters

/// Centralized DateFormatter cache for DayPage.
///
/// Before this file existed, ~88 call sites across Today/Archive/Daily/Sidebar
/// each constructed their own `DateFormatter` with `Locale(identifier: "en_US_POSIX")`
/// and a hand-typed `dateFormat`. Beyond the boilerplate, each instance is
/// allocated on every call — DateFormatter construction is non-trivial.
///
/// All formatters here are POSIX-locale, calendar-independent, and safe to
/// reuse across threads (DateFormatter is Sendable in practice once configured
/// and never mutated). Use these when the output is a stable machine string
/// (filenames, frontmatter, sorting keys). For user-facing localized text,
/// prefer `RelativeTimeFormatter` or `Date.formatted(_:)`.
public enum DateFormatters {

    // MARK: ISO date — "yyyy-MM-dd"

    /// "2026-06-19" — the canonical vault filename / frontmatter date format.
    /// Used by RawStorage, GraphRetriever, Sidebar heatmap, Archive, search.
    public static let isoDate: DateFormatter = posix("yyyy-MM-dd")

    // MARK: Clock time — "HH:mm"

    /// "14:23" — 24h clock used inside daily pages and memo timestamps.
    public static let timeHHmm: DateFormatter = posix("HH:mm")

    // MARK: Weekday / month-day variants

    /// "Mon" / "Fri" — short English weekday for heat-map labels.
    public static let weekdayShort: DateFormatter = posix("EEE")

    /// "Monday" — long English weekday for daily-page header.
    public static let weekdayLong: DateFormatter = posix("EEEE")

    /// "Jun 19" — short month-day for relative time fallbacks.
    public static let monthDay: DateFormatter = posix("MMM d")

    /// "05.30" — dotted month-day for the timeline row nameplate (mirrors web's
    /// `item.date`). Cached here so the Today history timeline stops allocating
    /// a fresh DateFormatter per visible row per scroll frame.
    public static let monthDayDotted: DateFormatter = posix("MM.dd")

    /// "2026-06" — year-month key for monthly archive grouping.
    public static let yearMonth: DateFormatter = posix("yyyy-MM")

    // MARK: Asset filenames — "yyyyMMdd_HHmmss"

    /// "20260619_142312" — collision-resistant stamp for asset filenames
    /// (voice_*.m4a, IMG_*.jpg, feedback bundles). Device-current time zone.
    public static let assetTimestamp: DateFormatter = posix("yyyyMMdd_HHmmss")

    // MARK: - Helpers

    /// Build a POSIX-locale DateFormatter with the given format pattern.
    /// Centralised so locale/timezone defaults stay consistent.
    private static func posix(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

// MARK: - Convenience on Date

public extension Date {
    /// "2026-06-19" — POSIX ISO short date used as vault filename.
    public var isoDateString: String { DateFormatters.isoDate.string(from: self) }
}

// MARK: - Convenience on String

public extension String {
    /// Parse a "yyyy-MM-dd" string into Date using the shared POSIX formatter.
    public var asISODate: Date? { DateFormatters.isoDate.date(from: self) }
}
