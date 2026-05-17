import AppIntents

// MARK: - DayPageShortcuts
//
// Registers Siri / Spotlight / Shortcuts.app phrases that all resolve to
// `StartRecordingIntent`. iOS picks up `AppShortcutsProvider` automatically;
// no Info.plist entry is required.
//
// Phrases include "DayPage" so Siri can disambiguate the app — Apple requires
// at least one phrase per shortcut to mention the app name.

@available(iOS 16.0, *)
struct DayPageShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "在 \(.applicationName) 里记一条",
                "用 \(.applicationName) 录音",
                "\(.applicationName) 快速记录",
                "记一条到 \(.applicationName)",
                "Record a memo in \(.applicationName)",
                "New \(.applicationName) memo"
            ],
            shortTitle: "记一条",
            systemImageName: "mic.fill"
        )
    }
}
