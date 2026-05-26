import SwiftUI

// MARK: - L10n

enum L10n {
    enum Empty {
        // Today Blank
        static let todayBlankTitle      = LocalizedStringKey("empty.today.blank.title")
        static let todayBlankSubtitle   = NSLocalizedString("empty.today.blank.subtitle", comment: "")
        static let todayBlankCta        = NSLocalizedString("empty.today.blank.cta", comment: "")

        // Today No Signals
        static let todayNoSignalsTitle    = LocalizedStringKey("empty.today.no_signals.title")
        static let todayNoSignalsSubtitle = NSLocalizedString("empty.today.no_signals.subtitle", comment: "")

        // Compile Locked
        static let compileLockedTitle = LocalizedStringKey("empty.compile_locked.title")
        static func compileLockedSubtitle(count: Int) -> String {
            String(format: NSLocalizedString("empty.compile_locked.subtitle", comment: ""), count)
        }

        /// Compact dock hint shown above the input bar when memos < 3.
        static func compileDockLocked(current: Int, remaining: Int) -> String {
            String(format: NSLocalizedString("compile.dock.locked", comment: ""), current, remaining)
        }

        /// VoiceOver announcement spoken once when the 3rd memo unlocks compilation.
        static let compileDockUnlocked = NSLocalizedString("compile.dock.unlocked", comment: "")

        // Archive Day Empty
        static let archiveDayTitle    = LocalizedStringKey("empty.archive_day.title")
        static let archiveDaySubtitle = NSLocalizedString("empty.archive_day.subtitle", comment: "")
        static let archiveDayCta      = NSLocalizedString("empty.archive_day.cta", comment: "")

        // Archive Month Empty
        static let archiveMonthEmptyTitle    = LocalizedStringKey("empty.archive_month.title")
        static let archiveMonthEmptySubtitle = NSLocalizedString("empty.archive_month.subtitle", comment: "")
        static let archiveMonthEmptyCta      = NSLocalizedString("empty.archive_month.cta", comment: "")

        // Mic Permission Denied
        static let micDeniedTitle    = LocalizedStringKey("empty.mic_denied.title")
        static let micDeniedSubtitle = NSLocalizedString("empty.mic_denied.subtitle", comment: "")
        static let micDeniedCta      = NSLocalizedString("empty.mic_denied.cta", comment: "")
    }

    enum Error {
        static let compileTitle    = LocalizedStringKey("error.compile.title")
        static let compileSubtitle = LocalizedStringKey("error.compile.subtitle")
        static let compileRetry    = NSLocalizedString("error.compile.retry", comment: "")

        static let whisperTitle    = LocalizedStringKey("error.whisper.title")
        static let whisperSubtitle = LocalizedStringKey("error.whisper.subtitle")

        static let micDeniedTitle    = LocalizedStringKey("error.mic_denied.title")
        static let micDeniedSubtitle = LocalizedStringKey("error.mic_denied.subtitle")
        static let micDeniedCta      = NSLocalizedString("error.mic_denied.cta", comment: "")

        static let locationDeniedTitle    = LocalizedStringKey("error.location_denied.title")
        static let locationDeniedSubtitle = LocalizedStringKey("error.location_denied.subtitle")
        static let locationDeniedCta      = NSLocalizedString("error.location_denied.cta", comment: "")
    }
}
