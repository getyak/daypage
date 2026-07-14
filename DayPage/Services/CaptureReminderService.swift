import Foundation
import UserNotifications
import DayPageStorage
import DayPageServices
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

// MARK: - CaptureReminderService
//
// 「定时召唤记录」的定时引擎。到配置的时间点,系统发一条本地通知(横幅 + 灵动岛
// Live Activity 的落点),用户点一下就落进录音舱 / 文字输入,把当下记进 vault。
//
// 设计要点:
//   • 每个启用的时间点(ReminderSlot)注册一条 UNCalendarNotificationTrigger
//     (repeats: true),identifier 稳定 = "daypage.capture.<slotID>",
//     重排时先按前缀全部移除再重装,避免残留。
//   • 通知带一个 category(kCategoryID),两个 action:「语音」「文字」+ 默认点击。
//     长按/下拉通知 → 展开 action;action 与默认点击都路由到既有 deeplink
//     (daypage://record / daypage://memo/new),复用 DayPageApp.onOpenURL,
//     不新增录音 / 输入落地逻辑。
//   • 静音时段(quiet hours)在注册时过滤:落在静音区间内的时间点直接跳过,
//     不打扰用户。
//   • 全部配置存 UserDefaults(JSON slots + preset + quiet hours),
//     @MainActor singleton 驱动 SwiftUI。
//
// 与 FeatureFlag.captureReminder 联动:flag 关 → refreshSchedule 清空所有
// 已注册的提醒(kill switch,无需 hot-fix)。

@MainActor
final class CaptureReminderService: ObservableObject {

    static let shared = CaptureReminderService()

    // MARK: Notification identifiers

    /// 提醒通知的 category — action 按钮(语音 / 文字)挂在这上面。
    static let categoryID = "daypage.capture.reminder"
    /// 每条已注册提醒的 identifier 前缀,重排时按此前缀清理。
    static let requestPrefix = "daypage.capture."

    static let actionVoice = "daypage.capture.action.voice"
    static let actionText  = "daypage.capture.action.text"

    // MARK: Deep links (复用既有 onOpenURL 分支)

    /// 语音:落进录音舱就绪态(= Widget/Siri 走的同一条路径)。
    static let voiceURL = "daypage://record"
    /// 文字:落进 Today 草稿输入(text 留空 = 只聚焦输入框)。
    static let textURL = "daypage://memo/new?text="

    // MARK: Published config

    @Published private(set) var preset: ReminderPreset
    @Published private(set) var slots: [ReminderSlot]
    @Published private(set) var quietHours: QuietHours

    // MARK: UserDefaults keys

    private enum Keys {
        static let preset = "captureReminder.preset"
        static let slots = "captureReminder.slots"
        static let quiet = "captureReminder.quietHours"
        static let preferAlarmKit = "captureReminder.preferAlarmKit"
    }

    private let defaults: UserDefaults

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preset = Self.loadPreset(defaults)
        self.slots = Self.loadSlots(defaults)
        self.quietHours = Self.loadQuietHours(defaults)
    }

    // MARK: - Public API

    /// 切换预设。`.custom` 保留用户手动编辑的 slots;`.once` / `.thrice` 覆盖
    /// 成对应的默认时间点(晚 21:00 / 早中晚 09:00·13:00·21:00)。
    func apply(preset newPreset: ReminderPreset) {
        preset = newPreset
        switch newPreset {
        case .once:
            slots = ReminderSlot.onceDefaults
        case .thrice:
            slots = ReminderSlot.thriceDefaults
        case .custom:
            // 保留现有 slots;custom 只解锁「添加 / 删除时间点」的 UI。
            if slots.isEmpty { slots = ReminderSlot.onceDefaults }
        }
        persist()
        refreshSchedule()
    }

    /// 开 / 关单个时间点。
    func setSlot(_ id: UUID, enabled: Bool) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[idx].enabled = enabled
        persist()
        refreshSchedule()
    }

    /// 编辑某个时间点的时分。
    func updateSlot(_ id: UUID, hour: Int, minute: Int) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[idx].hour = max(0, min(23, hour))
        slots[idx].minute = max(0, min(59, minute))
        persist()
        refreshSchedule()
    }

    /// 添加一个自定义时间点(仅 `.custom` 预设下 UI 可达)。
    func addSlot(hour: Int, minute: Int, label: String) {
        let slot = ReminderSlot(hour: max(0, min(23, hour)),
                                minute: max(0, min(59, minute)),
                                label: label,
                                enabled: true)
        slots.append(slot)
        slots.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        persist()
        refreshSchedule()
    }

    /// 删除一个时间点。
    func removeSlot(_ id: UUID) {
        slots.removeAll { $0.id == id }
        persist()
        refreshSchedule()
    }

    /// 更新静音时段。
    func updateQuietHours(_ hours: QuietHours) {
        quietHours = hours
        persist()
        refreshSchedule()
    }

    /// onboarding 引导「一键开启」用:落地一个预设并请求权限、注册通知。
    /// 返回是否拿到通知授权(供 UI 反馈)。
    @discardableResult
    func enableFromOnboarding(preset onboardPreset: ReminderPreset) async -> Bool {
        // iOS 26+ 优先请求 AlarmKit 授权(真灵动岛);拿不到再退普通通知权限。
        // 两个都请求:AlarmKit 走灵动岛,普通通知是 16.1–25 / AlarmKit 被拒时的回退。
        if #available(iOS 26.0, *) {
            #if canImport(AlarmKit)
            await requestAlarmKitAuthorization()
            #endif
        }
        let granted = await requestAuthorizationIfNeeded()
        preset = onboardPreset
        slots = onboardPreset == .thrice ? ReminderSlot.thriceDefaults : ReminderSlot.onceDefaults
        persist()
        registerCategoryIfNeeded()
        refreshSchedule()
        return granted
    }

    // MARK: - Scheduling

    /// 幂等重排。两条路径:
    ///   • iOS 26+ 且 AlarmKit 已授权 → 用 AlarmKit 排系统级灵动岛/锁屏定时提醒
    ///     (真·灵动岛),同时清掉 UNCalendar 侧的旧通知避免重复提醒。
    ///   • iOS 16.1–25(或 AlarmKit 未授权)→ 回退 UNCalendarNotificationTrigger
    ///     本地通知(通知到达时在灵动岛机型上也会短暂进灵动岛区域)。
    /// FeatureFlag 关时只清不装(两条路径都清)。
    func refreshSchedule() {
        registerCategoryIfNeeded()

        if #available(iOS 26.0, *), useAlarmKit {
            refreshViaAlarmKit()
            return
        }
        refreshViaNotifications()
    }

    private func refreshViaNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.requestPrefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }

            Task { @MainActor in
                guard FeatureFlagStore.shared.isEnabled(.captureReminder) else {
                    DayPageLogger.shared.info("[CaptureReminder] flag off — cleared \(stale.count) reminders")
                    return
                }
                self.installActiveSlots(into: center)
            }
        }
    }

    private func installActiveSlots(into center: UNUserNotificationCenter) {
        let active = slots.filter { $0.enabled && !quietHours.contains(hour: $0.hour, minute: $0.minute) }
        for slot in active {
            var comps = DateComponents()
            comps.hour = slot.hour
            comps.minute = slot.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

            let content = UNMutableNotificationContent()
            content.title = "记录此刻"
            content.body = slot.promptBody
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["captureReminderSlot": slot.id.uuidString]

            let request = UNNotificationRequest(
                identifier: Self.requestPrefix + slot.id.uuidString,
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error {
                    DayPageLogger.shared.error("[CaptureReminder] add failed: \(error.localizedDescription)")
                }
            }
        }
        DayPageLogger.shared.info("[CaptureReminder] scheduled \(active.count) reminders")
    }

    // MARK: - Category (long-press actions)

    private var categoryRegistered = false

    /// 注册通知 category —— 长按 / 下拉通知时露出「语音」「文字」两个 action。
    /// 默认点击(不选 action)也走 voice URL。
    private func registerCategoryIfNeeded() {
        guard !categoryRegistered else { return }
        categoryRegistered = true

        let voice = UNNotificationAction(
            identifier: Self.actionVoice,
            title: "语音",
            options: [.foreground]
        )
        let text = UNNotificationAction(
            identifier: Self.actionText,
            title: "文字",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [voice, text],
            intentIdentifiers: [],
            options: []
        )
        // 合并已有 category,避免覆盖别处注册的(如未来其他通知类型)。
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var merged = existing
            merged.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(merged)
        }
    }

    // MARK: - AlarmKit (iOS 26+ 真灵动岛路径)

    /// 是否走 AlarmKit。仅当运行在 iOS 26+、flag 开、且 AlarmKit 已授权时为真。
    /// 用户可通过设置里的「系统灵动岛」开关关掉,回退到普通通知。
    private var useAlarmKit: Bool {
        guard FeatureFlagStore.shared.isEnabled(.captureReminder) else { return false }
        guard preferAlarmKit else { return false }
        if #available(iOS 26.0, *) {
            return alarmKitAuthorized
        }
        return false
    }

    /// 用户偏好:iOS 26+ 上是否用 AlarmKit 系统灵动岛(默认 on)。存 UserDefaults。
    var preferAlarmKit: Bool {
        get {
            let v = defaults.object(forKey: Keys.preferAlarmKit)
            return v == nil ? true : defaults.bool(forKey: Keys.preferAlarmKit)
        }
        set {
            defaults.set(newValue, forKey: Keys.preferAlarmKit)
            refreshSchedule()
        }
    }

    /// AlarmKit 是否已授权 —— 由 requestAlarmKitAuthorization 更新。
    @Published private(set) var alarmKitAuthorized = false

    /// AlarmKit 在当前系统上是否可用(iOS 26+)。UI 用它决定是否显示「系统灵动岛」开关。
    var isAlarmKitAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

#if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private var alarmManager: AlarmManager { .shared }

    /// 请求 AlarmKit 授权(onboarding「开启提醒」时,若在 iOS 26+ 上顺带请求)。
    @available(iOS 26.0, *)
    @discardableResult
    func requestAlarmKitAuthorization() async -> Bool {
        let state = alarmManager.authorizationState
        switch state {
        case .authorized:
            alarmKitAuthorized = true
            return true
        case .denied:
            alarmKitAuthorized = false
            return false
        case .notDetermined:
            let granted = ((try? await alarmManager.requestAuthorization()) ?? .denied) == .authorized
            alarmKitAuthorized = granted
            return granted
        @unknown default:
            alarmKitAuthorized = false
            return false
        }
    }

    /// AlarmKit 重排:取消所有本 app 排的 alarm,清掉 UNCalendar 侧旧通知(避免
    /// 双重提醒),再为每个「启用且不在静音时段」的 slot 排一条 weekly-repeat alarm。
    @available(iOS 26.0, *)
    private func refreshViaAlarmKit() {
        // 先清 UNCalendar 侧,避免与 AlarmKit 重复提醒。
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }

        Task { @MainActor in
            // 取消旧 alarm。cancelAll 不存在,逐个 cancel 已知 slot id。
            for slot in slots {
                try? await alarmManager.cancel(id: slot.id)
            }
            guard FeatureFlagStore.shared.isEnabled(.captureReminder) else {
                DayPageLogger.shared.info("[CaptureReminder] flag off — cancelled AlarmKit alarms")
                return
            }
            let active = slots.filter { $0.enabled && !quietHours.contains(hour: $0.hour, minute: $0.minute) }
            for slot in active {
                await scheduleAlarm(for: slot)
            }
            DayPageLogger.shared.info("[CaptureReminder] AlarmKit scheduled \(active.count) alarms")
        }
    }

    @available(iOS 26.0, *)
    private func scheduleAlarm(for slot: ReminderSlot) async {
        let time = Alarm.Schedule.Relative.Time(hour: slot.hour, minute: slot.minute)
        // 每天重复。weekly 全 7 天 = 每天。
        let allWeekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        let schedule = Alarm.Schedule.relative(.init(time: time, repeats: .weekly(allWeekdays)))

        // 「记录此刻」的 alert:主按钮「知道了」停止,次按钮「记一句」打开 app 录音。
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: "记录此刻"),
            stopButton: AlarmButton(
                text: LocalizedStringResource(stringLiteral: "稍后"),
                textColor: .white,
                systemImageName: "xmark"
            ),
            secondaryButton: AlarmButton(
                text: LocalizedStringResource(stringLiteral: "记一句"),
                textColor: .white,
                systemImageName: "mic.fill"
            ),
            secondaryButtonBehavior: .custom
        )
        let presentation = AlarmPresentation(alert: alert)
        let metadata = CaptureAlarmMetadata(prompt: slot.promptBody, slotID: slot.id.uuidString)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            tintColor: Color(red: 0.74, green: 0.49, blue: 0.14) // 琥珀 amber,呼应品牌
        )

        // 次按钮打开 app → 走既有 daypage://record 录音路径。
        let config = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )

        do {
            _ = try await alarmManager.schedule(id: slot.id, configuration: config)
        } catch {
            DayPageLogger.shared.error("[CaptureReminder] AlarmKit schedule failed: \(error.localizedDescription)")
        }
    }
#endif

    private func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted
        @unknown default:
            return false
        }
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(preset.rawValue, forKey: Keys.preset)
        if let data = try? JSONEncoder().encode(slots) {
            defaults.set(data, forKey: Keys.slots)
        }
        if let data = try? JSONEncoder().encode(quietHours) {
            defaults.set(data, forKey: Keys.quiet)
        }
    }

    private static func loadPreset(_ defaults: UserDefaults) -> ReminderPreset {
        guard let raw = defaults.string(forKey: Keys.preset),
              let preset = ReminderPreset(rawValue: raw) else {
            return .once
        }
        return preset
    }

    private static func loadSlots(_ defaults: UserDefaults) -> [ReminderSlot] {
        guard let data = defaults.data(forKey: Keys.slots),
              let slots = try? JSONDecoder().decode([ReminderSlot].self, from: data),
              !slots.isEmpty else {
            return ReminderSlot.onceDefaults
        }
        return slots
    }

    private static func loadQuietHours(_ defaults: UserDefaults) -> QuietHours {
        guard let data = defaults.data(forKey: Keys.quiet),
              let hours = try? JSONDecoder().decode(QuietHours.self, from: data) else {
            return .defaultQuiet
        }
        return hours
    }
}

// MARK: - Models

enum ReminderPreset: String, CaseIterable {
    case once    // 每天一次(晚)
    case thrice  // 早中晚三次
    case custom  // 自定义时间点

    var title: String {
        switch self {
        case .once:   return "每天一次"
        case .thrice: return "早中晚"
        case .custom: return "自定义"
        }
    }
}

struct ReminderSlot: Codable, Identifiable, Equatable {
    let id: UUID
    var hour: Int
    var minute: Int
    var label: String
    var enabled: Bool

    init(id: UUID = UUID(), hour: Int, minute: Int, label: String, enabled: Bool) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.label = label
        self.enabled = enabled
    }

    /// "HH:mm" 展示用。
    var timeString: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// 通知正文 —— 随时段给一句轻的提示,不用命令式。
    var promptBody: String {
        switch hour {
        case 5..<11:  return "早上好 · 记一句此刻在想什么"
        case 11..<15: return "间隙里 · 留一条给今天"
        case 15..<19: return "下午了 · 有什么值得记下的"
        default:      return "睡前 · 把今天收进一句话"
        }
    }

    // 预设默认时间点。id 固定生成,但预设切换时整组替换,不复用旧 id。
    static var onceDefaults: [ReminderSlot] {
        [ReminderSlot(hour: 21, minute: 0, label: "睡前", enabled: true)]
    }

    static var thriceDefaults: [ReminderSlot] {
        [
            ReminderSlot(hour: 9,  minute: 0, label: "早", enabled: true),
            ReminderSlot(hour: 13, minute: 0, label: "午", enabled: true),
            ReminderSlot(hour: 21, minute: 0, label: "晚", enabled: true)
        ]
    }
}

/// 静音时段。start/end 用「一天中的分钟数」(0…1439),支持跨午夜(start > end)。
struct QuietHours: Codable, Equatable {
    var enabled: Bool
    var startMinutes: Int  // 例:23:30 → 1410
    var endMinutes: Int    // 例:08:00 → 480

    static let defaultQuiet = QuietHours(enabled: true, startMinutes: 23 * 60 + 30, endMinutes: 8 * 60)

    var startString: String { Self.hhmm(startMinutes) }
    var endString: String { Self.hhmm(endMinutes) }

    /// 某时分是否落在静音区间(含跨午夜)。enabled == false 时永远 false。
    func contains(hour: Int, minute: Int) -> Bool {
        guard enabled else { return false }
        let m = hour * 60 + minute
        if startMinutes <= endMinutes {
            // 同日区间,如 01:00–06:00
            return m >= startMinutes && m < endMinutes
        } else {
            // 跨午夜,如 23:30–08:00
            return m >= startMinutes || m < endMinutes
        }
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}
