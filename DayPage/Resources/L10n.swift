import SwiftUI
import DayPageServices

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

        // Graph Empty
        static let graphEmptyTitle    = LocalizedStringKey("empty.graph.title")
        static let graphEmptySubtitle = NSLocalizedString("empty.graph.subtitle", comment: "")
        static let graphEmptyCta      = NSLocalizedString("empty.graph.cta", comment: "")

        // Graph Not Connected (has dailies but no wikilinks)
        static let graphNotConnectedTitle    = LocalizedStringKey("empty.graph.not_connected.title")
        static let graphNotConnectedSubtitle = NSLocalizedString("empty.graph.not_connected.subtitle", comment: "")
        static let graphNotConnectedCta      = NSLocalizedString("empty.graph.not_connected.cta", comment: "")

        // Graph No Matches
        static let graphNoMatchesTitle    = LocalizedStringKey("empty.graph.no_matches.title")
        static let graphNoMatchesSubtitle = NSLocalizedString("empty.graph.no_matches.subtitle", comment: "")
        static let graphClearFilters      = NSLocalizedString("empty.graph.clear_filters", comment: "")
    }

    enum Recording {
        // Visible labels
        static let cancel               = LocalizedStringKey("recording.cancel")
        static let transcribe           = LocalizedStringKey("recording.transcribe")
        static let save                 = LocalizedStringKey("recording.save")
        static let releaseToCancel      = LocalizedStringKey("recording.release_to_cancel")
        static let releaseToTranscribe  = LocalizedStringKey("recording.release_to_transcribe")
        static let listening            = LocalizedStringKey("recording.listening")
        static let transcribing         = LocalizedStringKey("recording.transcribing")

        // Status strings (non-LocalizedStringKey for use in computed String props)
        static let listeningString          = NSLocalizedString("recording.listening", comment: "Recording status: actively listening")
        static let transcribingString       = NSLocalizedString("recording.transcribing", comment: "Recording status: Whisper transcription in flight")
        static let releaseToCancelString    = NSLocalizedString("recording.release_to_cancel", comment: "Recording status: drag-up cancel armed")
        static let releaseToTranscribeString = NSLocalizedString("recording.release_to_transcribe", comment: "Recording status: drag-left transcribe armed")

        // VoiceOver labels & hints
        static let cancelA11yLabel      = NSLocalizedString("recording.cancel.a11y.label", comment: "VoiceOver label for cancel-recording button")
        static let cancelA11yHint       = NSLocalizedString("recording.cancel.a11y.hint", comment: "VoiceOver hint for cancel-recording button")
        static let saveA11yLabel        = NSLocalizedString("recording.save.a11y.label", comment: "VoiceOver label for save-recording button")
        static let saveA11yHint         = NSLocalizedString("recording.save.a11y.hint", comment: "VoiceOver hint for save-recording button")
        static let transcribeA11yLabel  = NSLocalizedString("recording.transcribe.a11y.label", comment: "VoiceOver label for transcribe-recording button")
        static let transcribeA11yHint   = NSLocalizedString("recording.transcribe.a11y.hint", comment: "VoiceOver hint for transcribe-recording button")
        static let cancelHintA11yLabel  = NSLocalizedString("recording.cancel_hint.a11y.label", comment: "VoiceOver label for cancel directional hint")
        static let transcribeHintA11yLabel = NSLocalizedString("recording.transcribe_hint.a11y.label", comment: "VoiceOver label for transcribe directional hint")

        // Press-to-talk mic button (PressToTalkButton) VoiceOver
        static let micButtonA11yLabel   = Text("recording.mic_button.a11y.label")
        static let micButtonA11yHint    = Text("recording.mic_button.a11y.hint")
    }

    enum Error {
        static let compileTitle    = LocalizedStringKey("error.compile.title")
        static let compileSubtitle = LocalizedStringKey("error.compile.subtitle")
        static let compileRetry    = NSLocalizedString("error.compile.retry", comment: "")

        static let micDeniedTitle    = LocalizedStringKey("error.mic_denied.title")
        static let micDeniedSubtitle = LocalizedStringKey("error.mic_denied.subtitle")
        static let micDeniedCta      = NSLocalizedString("error.mic_denied.cta", comment: "")

        static let locationDeniedTitle    = LocalizedStringKey("error.location_denied.title")
        static let locationDeniedSubtitle = LocalizedStringKey("error.location_denied.subtitle")
        static let locationDeniedCta      = NSLocalizedString("error.location_denied.cta", comment: "")
    }

    enum Settings {
        // Brand name — funnelled through NSLocalizedString so any future
        // localized override can ship without touching source.
        static let iCloudDrive = NSLocalizedString("settings.icloud_drive", comment: "iCloud Drive feature name")
    }

    enum Archive {
        // Heat-map density legend labels rendered on each day cell.
        static let densityEmpty  = NSLocalizedString("archive.density.empty", comment: "Archive heat-map label: no memos")
        static let densityLow    = NSLocalizedString("archive.density.low", comment: "Archive heat-map label: few memos")
        static let densityMedium = NSLocalizedString("archive.density.medium", comment: "Archive heat-map label: some memos")
        static let densityHigh   = NSLocalizedString("archive.density.high", comment: "Archive heat-map label: many memos")

        // Monthly summary filter chip labels.
        static let filterAll         = NSLocalizedString("archive.filter.all", comment: "Monthly summary filter: show all days")
        static let filterHasLocation = NSLocalizedString("archive.filter.has_location", comment: "Monthly summary filter: days with a location")
        static let filterHasPhoto    = NSLocalizedString("archive.filter.has_photo", comment: "Monthly summary filter: days with a photo")

    }

    enum Banner {
        // VoiceOver label for the banner dismiss button.
        static let closeA11y = NSLocalizedString("banner.close.a11y", comment: "VoiceOver label for the banner close button")
    }
}
