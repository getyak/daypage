import AppIntents
import Foundation
#if canImport(UIKit) && !EXTENSION
import UIKit
import DayPageStorage
import DayPageServices
#endif

// MARK: - OpenDailyPageIntent
//
// AppIntent for "open the diary for <date>" surfaces:
//
//   • Siri ("打开 DayPage 昨天的日记")
//   • Shortcuts.app (date parameter picker)
//   • Spotlight follow-ups, Action Button parameterised shortcuts
//
// The vault layout (see CLAUDE.md) keys each day's file by calendar day in
// the user's preferred time zone — `vault/raw/YYYY-MM-DD.md`. We mirror that
// by formatting the chosen `Date` with `AppSettings.currentTimeZone()` and a
// fixed POSIX locale so the string is stable across locales.
//
// Routing: opens `daypage://daily?date=YYYY-MM-DD`. `DayPageApp.onOpenURL`
// validates the format, switches to the Archive tab, and asks ArchiveView
// to present DayDetailView for that date (via `navModel.openArchive(at:)`).

@available(iOS 16.0, *)
struct OpenDailyPageIntent: AppIntent {

    static var title: LocalizedStringResource = "打开某天的日记"

    static var description = IntentDescription(
        "在 DayPage 中打开指定日期的日记页。",
        categoryName: "Browse",
        searchKeywords: [
            "open", "diary", "daily", "page", "archive",
            "打开", "日记", "某天", "归档", "daypage"
        ]
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: "日期") var date: Date

    /// Format a `Date` as the vault filename style ("YYYY-MM-DD") using the
    /// user's preferred time zone (the same TZ RawStorage uses to bucket
    /// memos into calendar days). Exposed as a static helper for tests.
    static func formattedDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Builds the deep-link URL for a `YYYY-MM-DD` date string.
    static func buildURL(dateString: String) -> URL? {
        let encoded = dateString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dateString
        return URL(string: "daypage://daily?date=\(encoded)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let dateString = Self.formattedDate(date, timeZone: AppSettings.currentTimeZone())
        #if !EXTENSION
        if let url = Self.buildURL(dateString: dateString) {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}
