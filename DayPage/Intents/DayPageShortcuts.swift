import AppIntents
import DayPageServices

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
        AppShortcut(
            intent: QuickCaptureTextIntent(),
            phrases: [
                "用 \(.applicationName) 记一笔",
                "记一条文本到 \(.applicationName)",
                "\(.applicationName) 记文字",
                "Quick capture to \(.applicationName)",
                "New text memo in \(.applicationName)"
            ],
            shortTitle: "记一条文本",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SaveScreenshotIntent(),
            phrases: [
                "保存截图到 \(.applicationName)",
                "用 \(.applicationName) 保存这张截图",
                "Save screenshot to \(.applicationName)",
                "Capture screen to \(.applicationName)"
            ],
            shortTitle: "保存截图",
            systemImageName: "rectangle.on.rectangle"
        )
        // Note: AppShortcut phrase parameterization for `Date` is brittle —
        // Shortcuts.app surfaces the date picker for the `date` parameter
        // when run from the Shortcuts UI, so we keep phrases parameter-free
        // here and let users pick the day in the system flow.
        AppShortcut(
            intent: OpenDailyPageIntent(),
            phrases: [
                "打开 \(.applicationName) 某天",
                "查看 \(.applicationName) 的某天",
                "Open daily page in \(.applicationName)",
                "Show \(.applicationName) day"
            ],
            shortTitle: "打开某天",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: AskTodayIntent(),
            phrases: [
                "问问 \(.applicationName)",
                "在 \(.applicationName) 里搜索",
                "\(.applicationName) 找一下",
                "Ask \(.applicationName)",
                "Search \(.applicationName)"
            ],
            shortTitle: "问问今天",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenSystemActionCenterIntent(),
            phrases: [
                "打开 \(.applicationName) 动作中心",
                "查看 \(.applicationName) 待审批动作",
                "Review actions in \(.applicationName)"
            ],
            shortTitle: "动作中心",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: DraftSystemActionIntent(),
            phrases: [
                "用 \(.applicationName) 起草系统动作",
                "在 \(.applicationName) 准备一个动作",
                "Draft an action in \(.applicationName)"
            ],
            shortTitle: "起草动作",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: DraftFocusSessionIntent(),
            phrases: [
                "用 \(.applicationName) 准备专注",
                "在 \(.applicationName) 开始专注",
                "Prepare focus in \(.applicationName)"
            ],
            shortTitle: "准备专注",
            systemImageName: "timer"
        )
    }
}
