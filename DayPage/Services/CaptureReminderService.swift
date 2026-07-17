import Foundation
import UserNotifications
import DayPageStorage
import DayPageServices
import SwiftUI
import UIKit
#if canImport(AlarmKit)
import AlarmKit
#endif

// MARK: - CaptureReminderService
//
// 「定时召唤记录」的统一调度器。到配置的时间点,系统发一条本地通知(横幅 +
// 灵动岛落点),用户点一下就落进录音舱 / 文字输入,把当下记进 vault。
//
// vNext(2026-07-15):统一到单一 `Reminder` 模型 —— 一个 `reminders: [Reminder]`
// 集合,一个 `schedule()` 入口,按 `trigger` 分派:
//   • .once(Date)          → UNTimeInterval / AlarmKit .fixed(一次性,触发后剔除)
//   • .daily / .weekdays   → UNCalendar / AlarmKit .relative(重复)
// AI(对话调度)和 UI(Today 胶囊)都只调这一套 API。复杂度收在调度里。
//
// 设计要点:
//   • identifier 稳定 = "daypage.capture.<reminderID>",重排时按前缀全清再重装。
//   • 通知带 category(actions:语音/文字)+ 默认点击,路由到既有 deeplink,
//     不新增录音/输入落地逻辑。
//   • 静音时段(quiet hours)在注册时过滤重复提醒;一次性提醒不受静音影响
//     (用户/AI 明确指定的精确时间,不该被静音吞掉)。
//   • 一次性提醒触发后自动清理(启动 + 每次重排时剔除已过期的 .once)。
//   • 配置存 UserDefaults(JSON reminders + preset + quiet hours),
//     @MainActor singleton 驱动 SwiftUI。
//   • 兼容:旧 `captureReminder.slots`(ReminderSlot 数组)一次性迁移成
//     新 `captureReminder.reminders`(Reminder 数组),用户已配置不丢。
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
    /// 统一提醒集合 —— 重复 + 一次性都在这里。UI/AI 通过下面的 API 增删改。
    @Published private(set) var reminders: [Reminder]
    @Published private(set) var quietHours: QuietHours

    // MARK: UserDefaults keys

    private enum Keys {
        static let preset = "captureReminder.preset"
        /// 旧 key(ReminderSlot 数组)—— 仅用于一次性迁移读取。
        static let legacySlots = "captureReminder.slots"
        /// 新 key(Reminder 数组)。
        static let reminders = "captureReminder.reminders"
        static let quiet = "captureReminder.quietHours"
        static let preferAlarmKit = "captureReminder.preferAlarmKit"
    }

    private let defaults: UserDefaults

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preset = Self.loadPreset(defaults)
        self.reminders = Self.loadReminders(defaults)
        self.quietHours = Self.loadQuietHours(defaults)
        // 启动时清一次过期的一次性提醒(冷启动补账)。
        pruneExpiredOneShots()
    }

    // MARK: - Public API (presets)

    /// 切换预设。`.custom` 保留用户手动编辑的提醒;`.once` / `.thrice` 覆盖
    /// 成对应的默认时间点。仅影响重复提醒;一次性提醒不被预设切换清掉。
    func apply(preset newPreset: ReminderPreset) {
        preset = newPreset
        let oneShots = reminders.filter { $0.isOneShot }
        switch newPreset {
        case .once:
            reminders = Reminder.onceDefaults + oneShots
        case .thrice:
            reminders = Reminder.thriceDefaults + oneShots
        case .custom:
            // 保留现有;custom 只解锁「增删提醒」的 UI。若空了给个默认。
            if reminders.filter({ !$0.isOneShot }).isEmpty {
                reminders = Reminder.onceDefaults + oneShots
            }
        }
        persist()
        refreshSchedule()
    }

    // MARK: - Public API (unified reminder mutations)

    /// 开 / 关单条提醒。
    func setReminder(_ id: UUID, enabled: Bool) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].enabled = enabled
        persist()
        refreshSchedule()
    }

    /// 整体替换某条提醒的 trigger(编辑 sheet 保存时用)。
    func updateReminder(_ id: UUID, trigger: Reminder.Trigger, label: String? = nil) {
        guard let idx = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[idx].trigger = trigger
        if let label { reminders[idx].label = label }
        sortReminders()
        persist()
        refreshSchedule()
    }

    /// 添加一条提醒 —— UI 和 AI 的统一落地入口。返回新建的 Reminder。
    @discardableResult
    func addReminder(_ reminder: Reminder) -> Reminder {
        reminders.append(reminder)
        sortReminders()
        persist()
        refreshSchedule()
        return reminder
    }

    /// 便捷:排一条一次性提醒到精确时间点(AI/Today「稍后」用)。
    /// 传入的 fireDate 已过则不排,返回 nil。
    @discardableResult
    func scheduleOnce(at fireDate: Date, label: String, source: Reminder.Source = .user) -> Reminder? {
        guard fireDate > Date() else { return nil }
        let reminder = Reminder(trigger: .once(fireDate), label: label, source: source)
        return addReminder(reminder)
    }

    /// 便捷:排一条重复提醒(AI/Today 新建重复用)。
    @discardableResult
    func scheduleRepeating(trigger: Reminder.Trigger, label: String, source: Reminder.Source = .user) -> Reminder {
        let reminder = Reminder(trigger: trigger, label: label, source: source)
        return addReminder(reminder)
    }

    /// 删除一条提醒。
    func removeReminder(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        persist()
        refreshSchedule()
    }

    /// 更新静音时段。
    func updateQuietHours(_ hours: QuietHours) {
        quietHours = hours
        persist()
        refreshSchedule()
    }

    // MARK: - Derived queries (Today 胶囊)

    /// 即将触发的提醒,按 nextFireDate 升序。用于 Today 页轻量胶囊行。
    /// 只返回启用且有下次触发的;limit 控制条数。
    func upcoming(limit: Int = 3, now: Date = Date()) -> [Reminder] {
        reminders
            .compactMap { r -> (Reminder, Date)? in
                guard let next = r.nextFireDate(after: now) else { return nil }
                return (r, next)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Onboarding

    /// onboarding 引导「一键开启」用:落地一个预设并请求权限、注册通知。
    /// 返回是否拿到通知授权(供 UI 反馈)。签名保持不变(Onboarding 依赖)。
    @discardableResult
    func enableFromOnboarding(preset onboardPreset: ReminderPreset) async -> Bool {
        if #available(iOS 26.0, *) {
            #if canImport(AlarmKit)
            await requestAlarmKitAuthorization()
            #endif
        }
        let granted = await requestAuthorizationIfNeeded()
        preset = onboardPreset
        let base = onboardPreset == .thrice ? Reminder.thriceDefaults : Reminder.onceDefaults
        // 保留可能已有的一次性提醒。
        reminders = base + reminders.filter { $0.isOneShot }
        persist()
        registerCategoryIfNeeded()
        refreshSchedule()
        return granted
    }

    /// 请求通知授权(AI/Today 首次排提醒前调,确保能真的响)。
    @discardableResult
    func ensureAuthorized() async -> Bool {
        if #available(iOS 26.0, *) {
            #if canImport(AlarmKit)
            await requestAlarmKitAuthorization()
            #endif
        }
        return await requestAuthorizationIfNeeded()
    }

    // MARK: - Scheduling

    /// 幂等重排。先剔除过期一次性,再按两条路径装载:
    ///   • iOS 26+ 且 AlarmKit 已授权 → AlarmKit(真灵动岛),同时清 UNCalendar 侧。
    ///   • 否则 → UN 通知(一次性用 TimeInterval,重复用 Calendar)。
    /// FeatureFlag 关时只清不装(两条路径都清)。
    func refreshSchedule() {
        registerCategoryIfNeeded()
        pruneExpiredOneShots()

        if #available(iOS 26.0, *), useAlarmKit {
            refreshViaAlarmKit()
            return
        }
        refreshViaNotifications()
    }

    /// 剔除已过期的一次性提醒(fireDate < now)。重复提醒不受影响。
    private func pruneExpiredOneShots() {
        let now = Date()
        let before = reminders.count
        reminders.removeAll { r in
            if case .once(let date) = r.trigger { return date <= now }
            return false
        }
        if reminders.count != before { persist() }
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
                self.installActiveReminders(into: center)
            }
        }
    }

    private func installActiveReminders(into center: UNUserNotificationCenter) {
        var scheduled = 0
        for reminder in reminders where reminder.enabled {
            // 一条 Reminder 可能展开成多条 UN request(weekdays:每个周几一条)。
            // sub-identifier 用 "<prefix><id>" 或 "<prefix><id>.w<weekday>",
            // 都以 requestPrefix 打头,重排时被前缀清理统一带走。
            for spec in notificationSpecs(for: reminder) {
                let content = UNMutableNotificationContent()
                content.title = "记录此刻"
                content.body = reminder.promptBody
                content.sound = .default
                content.categoryIdentifier = Self.categoryID
                content.userInfo = ["captureReminderID": reminder.id.uuidString]

                let request = UNNotificationRequest(
                    identifier: spec.identifier,
                    content: content,
                    trigger: spec.trigger
                )
                center.add(request) { error in
                    if let error {
                        DayPageLogger.shared.error("[CaptureReminder] add failed: \(error.localizedDescription)")
                    }
                }
                scheduled += 1
            }
        }
        DayPageLogger.shared.info("[CaptureReminder] scheduled \(scheduled) requests")
    }

    /// 把一条 Reminder 展开成 (identifier, trigger) 列表。
    /// 静音时段只过滤重复提醒;一次性(明确指定)不被静音吞掉。
    /// weekdays 展开成 N 条(UNCalendar 一条只能匹配一个 weekday)。
    private func notificationSpecs(for reminder: Reminder) -> [(identifier: String, trigger: UNNotificationTrigger)] {
        let base = Self.requestPrefix + reminder.id.uuidString
        switch reminder.trigger {
        case .once(let date):
            let interval = date.timeIntervalSinceNow
            guard interval > 0 else { return [] }
            return [(base, UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))]

        case .daily(let h, let m):
            if quietHours.contains(hour: h, minute: m) { return [] }
            var comps = DateComponents()
            comps.hour = h
            comps.minute = m
            return [(base, UNCalendarNotificationTrigger(dateMatching: comps, repeats: true))]

        case .weekdays(let days, let h, let m):
            if quietHours.contains(hour: h, minute: m) { return [] }
            return days.sorted().map { weekday in
                var comps = DateComponents()
                comps.weekday = weekday
                comps.hour = h
                comps.minute = m
                return ("\(base).w\(weekday)", UNCalendarNotificationTrigger(dateMatching: comps, repeats: true))
            }
        }
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
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var merged = existing
            merged.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(merged)
        }
    }

    // MARK: - AlarmKit (iOS 26+ 真灵动岛路径)

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

    @Published private(set) var alarmKitAuthorized = false

    /// AlarmKit 在当前系统上是否可用(iOS 26+)。UI 用它决定是否显示开关。
    var isAlarmKitAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

#if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private var alarmManager: AlarmManager { .shared }

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

    /// Syncs `alarmKitAuthorized` from AlarmKit's *current* state without ever
    /// showing a permission prompt, then re-arms the schedule if that flipped
    /// us onto the AlarmKit path.
    ///
    /// Why this exists (2026-07-15) — the Dynamic Island never appeared:
    /// `alarmKitAuthorized` is in-memory only (unlike `preferAlarmKit`, it has
    /// no UserDefaults key) and starts false on every launch. The only writer
    /// was `requestAlarmKitAuthorization()`, reachable just from onboarding's
    /// one-shot `enableFromOnboarding`. So authorization was true for the
    /// onboarding session and false on every launch after it — `useAlarmKit`
    /// went false, `refreshSchedule()` skipped the AlarmKit branch, and every
    /// reminder silently degraded to a plain UN notification.
    ///
    /// Reading the real state at foreground also picks up permission being
    /// revoked or granted in Settings.app without a relaunch. Prompt-free by
    /// design: `.notDetermined` is left alone here and only requested from the
    /// Settings toggle, where the user has just asked for the feature.
    @available(iOS 26.0, *)
    func refreshAlarmKitAuthorizationState() {
        let authorized = alarmManager.authorizationState == .authorized
        guard authorized != alarmKitAuthorized else { return }
        alarmKitAuthorized = authorized
        DayPageLogger.shared.info("[CaptureReminder] AlarmKit authorization → \(authorized)")
        refreshSchedule()
    }

    /// AlarmKit 重排:清 UNCalendar 侧旧通知 → 取消旧 alarm → 为每条启用的
    /// 提醒排 alarm(一次性 = .fixed;重复 = .relative)。
    @available(iOS 26.0, *)
    private func refreshViaAlarmKit() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }

        Task { @MainActor in
            for reminder in reminders {
                try? await alarmManager.cancel(id: reminder.id)
            }
            guard FeatureFlagStore.shared.isEnabled(.captureReminder) else {
                DayPageLogger.shared.info("[CaptureReminder] flag off — cancelled AlarmKit alarms")
                return
            }
            var scheduled = 0
            for reminder in reminders where reminder.enabled {
                if await scheduleAlarm(for: reminder) { scheduled += 1 }
            }
            DayPageLogger.shared.info("[CaptureReminder] AlarmKit scheduled \(scheduled) alarms")
        }
    }

    /// 为一条 Reminder 排 AlarmKit alarm。返回是否真的排了(静音/过期跳过 = false)。
    @available(iOS 26.0, *)
    @discardableResult
    private func scheduleAlarm(for reminder: Reminder) async -> Bool {
        let schedule: Alarm.Schedule
        switch reminder.trigger {
        case .once(let date):
            guard date > Date() else { return false }
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            schedule = .fixed(Calendar.current.date(from: comps) ?? date)

        case .daily(let h, let m):
            if quietHours.contains(hour: h, minute: m) { return false }
            let time = Alarm.Schedule.Relative.Time(hour: h, minute: m)
            let all: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            schedule = .relative(.init(time: time, repeats: .weekly(all)))

        case .weekdays(let days, let h, let m):
            if quietHours.contains(hour: h, minute: m) { return false }
            let time = Alarm.Schedule.Relative.Time(hour: h, minute: m)
            let weekdays = days.compactMap(Self.localeWeekday(from:))
            guard !weekdays.isEmpty else { return false }
            schedule = .relative(.init(time: time, repeats: .weekly(weekdays)))
        }

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
        let metadata = CaptureAlarmMetadata(prompt: reminder.promptBody, slotID: reminder.id.uuidString)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            // 灵动岛恒黑底 → 取 tokens.json accent 的暗色变体 #C9883A
            // (= DSTokens.Colors.accent dark)。widget 端一律读
            // attributes.tintColor,不再各自硬编码副本(单源防漂移)。
            tintColor: Color(red: 0.788, green: 0.533, blue: 0.227)
        )
        let config = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )
        do {
            _ = try await alarmManager.schedule(id: reminder.id, configuration: config)
            return true
        } catch {
            DayPageLogger.shared.error("[CaptureReminder] AlarmKit schedule failed: \(error.localizedDescription)")
            return false
        }
    }

    #if DEBUG
    /// QA(模拟器专用):起一个 AlarmKit countdown 计时器。countdown 是唯一
    /// 由我们的 widget 渲染灵动岛 compact/expanded 的状态(.alert 态由系统
    /// 钉横幅接管),QA 用它实测自定义岛 UI。生产路径不会走到这里。
    @available(iOS 26.0, *)
    func qaStartCountdownTimer(seconds: TimeInterval) async {
        _ = await requestAlarmKitAuthorization()
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
        let countdown = AlarmPresentation.Countdown(
            title: LocalizedStringResource(stringLiteral: "记录此刻"))
        let presentation = AlarmPresentation(alert: alert, countdown: countdown)
        let metadata = CaptureAlarmMetadata(prompt: "记一句给今天", slotID: UUID().uuidString)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: metadata,
            // 同 scheduleAlarm:tokens accent 暗色变体,widget 读 tintColor 单源。
            tintColor: Color(red: 0.788, green: 0.533, blue: 0.227)
        )
        let config = AlarmManager.AlarmConfiguration.timer(
            duration: seconds, attributes: attributes)
        do {
            _ = try await alarmManager.schedule(id: UUID(), configuration: config)
            DayPageLogger.shared.info("[CaptureReminder] QA countdown timer scheduled (\(Int(seconds))s)")
        } catch {
            DayPageLogger.shared.error("[CaptureReminder] QA timer failed: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: AlarmKit alert lifecycle (2026-07-17)
    //
    // 实测发现的两个灵动岛硬伤:
    //   1. alarm 触发后进入 .alerting,Live Activity 会无限期占住灵动岛 ——
    //      cancel() 只撤未触发的调度,全工程没有任何一处调 stop()。用户点了
    //      「记一句」进 App、录完音回桌面,岛上的黑胶囊还挂着。
    //   2. App 在前台时触发:iOS 会隐藏本 App 自己的灵动岛呈现,而 App 内又
    //      没有任何兜底 UI → 提醒完全不可见,静默被吞。
    // 修法:观察 alarmUpdates;前台触发 → 立即 stop + 重投一条普通 UN 横幅
    // (willPresent 已返回 .banner,category/action/深链全部复用既有轨道);
    // 启动与回前台 → stop 所有 .alerting(用户已经回到 App,提醒完成使命)。

    private var alarmObservationTask: Task<Void, Never>?

    /// 停掉所有正在 alerting 的 alarm,释放灵动岛。重复提醒 stop 后自动
    /// 重新武装到下一次触发;一次性提醒交给 pruneExpiredOneShots 收尾。
    @available(iOS 26.0, *)
    func stopAlertingAlarms() {
        let alerting = ((try? alarmManager.alarms) ?? []).filter { $0.state == .alerting }
        guard !alerting.isEmpty else { return }
        for alarm in alerting {
            try? alarmManager.stop(id: alarm.id)
        }
        DayPageLogger.shared.info("[CaptureReminder] stopped \(alerting.count) alerting alarm(s)")
    }

    /// 常驻观察 alarm 状态。App 处于前台时有 alarm 进入 .alerting →
    /// 立即 stop(灵动岛对前台 App 本就不显示,留着只会在退到桌面后
    /// 变成一个悬挂的黑胶囊)并重投一条前台 UN 横幅作为可见的提醒落点。
    @available(iOS 26.0, *)
    func startAlarmAlertObservation() {
        guard alarmObservationTask == nil else { return }
        alarmObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await alarms in self.alarmManager.alarmUpdates {
                let alerting = alarms.filter { $0.state == .alerting }
                guard !alerting.isEmpty,
                      UIApplication.shared.applicationState == .active else { continue }
                for alarm in alerting {
                    try? self.alarmManager.stop(id: alarm.id)
                    self.postForegroundReminderBanner(alarmID: alarm.id)
                }
                DayPageLogger.shared.info("[CaptureReminder] foreground alert → stopped \(alerting.count), reposted as banner")
                // 一次性提醒触发即过期;重排顺带剔除并让 Today 胶囊同步。
                self.refreshSchedule()
            }
        }
    }

    /// 前台触发的可见落点:一条立即送达的 UN 横幅,复用既有 category
    /// (语音 / 文字 action)与点击路由,与 UN 降级路径行为完全一致。
    private func postForegroundReminderBanner(alarmID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "记录此刻"
        content.body = reminders.first { $0.id == alarmID }?.promptBody ?? "记一句给今天"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["captureReminderID": alarmID.uuidString]
        let request = UNNotificationRequest(
            identifier: Self.requestPrefix + "foreground." + alarmID.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { @MainActor in
                    DayPageLogger.shared.error("[CaptureReminder] foreground banner failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Calendar weekday(1=日…7=六) → AlarmKit Locale.Weekday。
    @available(iOS 26.0, *)
    private static func localeWeekday(from calendarWeekday: Int) -> Locale.Weekday? {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
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

    private func sortReminders() {
        // 一次性按 fireDate,重复按时分;整体一次性在前(临近感)。
        reminders.sort { a, b in
            switch (a.isOneShot, b.isOneShot) {
            case (true, false): return true
            case (false, true): return false
            default:
                let (ah, am) = a.timeComponents
                let (bh, bm) = b.timeComponents
                return (ah, am) < (bh, bm)
            }
        }
    }

    private func persist() {
        defaults.set(preset.rawValue, forKey: Keys.preset)
        if let data = try? JSONEncoder().encode(reminders) {
            defaults.set(data, forKey: Keys.reminders)
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

    /// 加载提醒。优先读新 key;若无但有旧 slots → 迁移;都无 → 默认。
    private static func loadReminders(_ defaults: UserDefaults) -> [Reminder] {
        if let data = defaults.data(forKey: Keys.reminders),
           let list = try? JSONDecoder().decode([Reminder].self, from: data),
           !list.isEmpty {
            return list
        }
        // 迁移:旧 ReminderSlot 数组 → Reminder。
        if let migrated = migrateLegacySlots(defaults) {
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: Keys.reminders)
            }
            defaults.removeObject(forKey: Keys.legacySlots)
            return migrated
        }
        return Reminder.onceDefaults
    }

    /// 旧 ReminderSlot(每日重复)→ Reminder(.daily)。仅在首次升级时跑一次。
    private static func migrateLegacySlots(_ defaults: UserDefaults) -> [Reminder]? {
        guard let data = defaults.data(forKey: Keys.legacySlots),
              let slots = try? JSONDecoder().decode([LegacySlot].self, from: data),
              !slots.isEmpty else {
            return nil
        }
        return slots.map { slot in
            Reminder(
                trigger: .daily(hour: slot.hour, minute: slot.minute),
                label: slot.label,
                enabled: slot.enabled,
                source: .user
            )
        }
    }

    private static func loadQuietHours(_ defaults: UserDefaults) -> QuietHours {
        guard let data = defaults.data(forKey: Keys.quiet),
              let hours = try? JSONDecoder().decode(QuietHours.self, from: data) else {
            return .defaultQuiet
        }
        return hours
    }
}

// MARK: - Legacy migration shape

/// 旧 `ReminderSlot` 的解码用形状 —— 仅供一次性迁移读取旧 UserDefaults。
/// 原类型已删,此处保留最小字段镜像避免破坏已升级用户的数据。
private struct LegacySlot: Codable {
    let id: UUID
    var hour: Int
    var minute: Int
    var label: String
    var enabled: Bool
}

// MARK: - Preset

enum ReminderPreset: String, CaseIterable {
    case once    // 每天一次(晚)
    case thrice  // 早中晚三次
    case custom  // 自定义

    var title: String {
        switch self {
        case .once:   return "每天一次"
        case .thrice: return "早中晚"
        case .custom: return "自定义"
        }
    }
}

// MARK: - QuietHours

/// 静音时段。start/end 用「一天中的分钟数」(0…1439),支持跨午夜(start > end)。
struct QuietHours: Codable, Equatable {
    var enabled: Bool
    var startMinutes: Int
    var endMinutes: Int

    static let defaultQuiet = QuietHours(enabled: true, startMinutes: 23 * 60 + 30, endMinutes: 8 * 60)

    var startString: String { Self.hhmm(startMinutes) }
    var endString: String { Self.hhmm(endMinutes) }

    /// 某时分是否落在静音区间(含跨午夜)。enabled == false 时永远 false。
    func contains(hour: Int, minute: Int) -> Bool {
        guard enabled else { return false }
        let m = hour * 60 + minute
        if startMinutes <= endMinutes {
            return m >= startMinutes && m < endMinutes
        } else {
            return m >= startMinutes || m < endMinutes
        }
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}
