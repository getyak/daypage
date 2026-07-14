import Foundation
#if canImport(AlarmKit)
import AlarmKit

// MARK: - CaptureAlarmMetadata
//
// AlarmKit(iOS 26+)提醒的 metadata。app 端调 AlarmManager.schedule 时写入,
// Widget 端的 ActivityConfiguration 读它渲染灵动岛 —— 所以此类型必须同时属于
// DayPage(app)和 DayPageWidget 两个 target。
//
// 承载「这条提醒对应哪个记录节奏」的一句轻提示(promptBody),灵动岛/锁屏
// 展开时显示,呼应 P1 通知的文案语气。
//
// AlarmKit 是 iOS 26 才有的框架,用 #if canImport 包住,让 16.1 主 target
// 也能编过(旧系统上此文件整体为空,不影响回退到 UNCalendar 路径)。

@available(iOS 26.0, *)
struct CaptureAlarmMetadata: AlarmMetadata {
    /// 灵动岛/锁屏展开时的一句轻提示(如「睡前 · 把今天收进一句话」)。
    let prompt: String
    /// 对应 ReminderSlot 的 id,用于点击后路由 & 取消对账。
    let slotID: String

    init(prompt: String, slotID: String) {
        self.prompt = prompt
        self.slotID = slotID
    }
}
#endif
