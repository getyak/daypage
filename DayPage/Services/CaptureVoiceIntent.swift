import AppIntents
import Foundation
#if canImport(UIKit) && !EXTENSION
import UIKit
#endif

// MARK: - CaptureVoiceIntent
//
// AlarmKit 全屏闹钟(.loud 提醒)上「记一句」副按钮的落地 intent。
//
// 为什么单独存在、不复用 StartRecordingIntent —— AlarmKit 的 secondaryIntent
// 类型约束是 `(any LiveActivityIntent)?`(逐行核对 iOS 26.4 SDK),必须遵从
// `LiveActivityIntent` 协议;而 StartRecordingIntent 是普通 `AppIntent`,传进
// AlarmConfiguration 编不过。这正是"点闹钟语音按钮没反应"的根因:旧代码
// `secondaryButtonBehavior: .custom` 但 `secondaryIntent: nil`,.custom 行为
// 缺 intent → 运行期静默失效(编译器不拦)。
//
// 落点复用既有深链:openAppWhenRun 前台唤起 app 后 open `daypage://record`,
// 走 DayPageApp.onOpenURL 的 record 分支 → pendingRecordingTrigger → TodayView
// 起录音舱。与 Widget / Siri / 控制中心 / 普通通知的语音 action 同一条轨道。
//
// 归属:app target(DayPage/Services/,与 CaptureReminderService 同 group,
// 因为它只被后者引用且需 open URL,不进 Widget target)。

@available(iOS 26.0, *)
struct CaptureVoiceIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "记一句"

    static var description = IntentDescription(
        "从提醒直接开始语音录音。",
        categoryName: "Capture"
    )

    /// 前台打开 app —— 麦克风访问要求 app 在前台。
    static var openAppWhenRun: Bool { true }

    /// 触发这条 intent 的提醒 id(便于未来埋点/关联,当前仅透传)。
    @Parameter(title: "提醒")
    var reminderID: String

    init() {}

    init(reminderID: String) {
        self.reminderID = reminderID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EXTENSION
        if let url = URL(string: "daypage://record") {
            #if canImport(UIKit)
            await UIApplication.shared.open(url)
            #endif
        }
        #endif
        return .result()
    }
}
