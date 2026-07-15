// CaptureReminderServiceTests.swift — 「定时召唤记录」统一调度器
//
// 覆盖纯逻辑(不碰真实 UNUserNotificationCenter):
//   * QuietHours.contains — 同日区间 + 跨午夜 + disabled 短路
//   * 预设切换 apply(preset:) — once/thrice 覆盖重复提醒,custom 保留,一次性不被清
//   * Reminder CRUD + 持久化 round-trip(注入独立 UserDefaults 隔离)
//   * 一次性提醒过期剔除
//   * 旧 ReminderSlot(captureReminder.slots)→ 新 Reminder 迁移
//   * Reminder 派生:timeString / repeatDescription / nextFireDate / weekdayLabel
//   * RelativeTimeResolver 相对时间解析
//
// service 是 @MainActor singleton,但 init(defaults:) 允许注入独立 suite,
// 测试造独立实例、不污染 .standard / singleton。

import Testing
import Foundation
@testable import DayPage

@MainActor
@Suite(.serialized)
struct CaptureReminderServiceTests {

    private func makeService(suite: String = "captureReminder.test.\(UUID().uuidString)") -> (CaptureReminderService, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CaptureReminderService(defaults: defaults), defaults)
    }

    // MARK: - QuietHours

    @Test func quietHoursSameDayRange() {
        let q = QuietHours(enabled: true, startMinutes: 60, endMinutes: 360)
        #expect(q.contains(hour: 0, minute: 30) == false)
        #expect(q.contains(hour: 1, minute: 0) == true)
        #expect(q.contains(hour: 3, minute: 0) == true)
        #expect(q.contains(hour: 6, minute: 0) == false)
        #expect(q.contains(hour: 9, minute: 0) == false)
    }

    @Test func quietHoursOvernightRange() {
        let q = QuietHours.defaultQuiet
        #expect(q.contains(hour: 23, minute: 30) == true)
        #expect(q.contains(hour: 0, minute: 0) == true)
        #expect(q.contains(hour: 7, minute: 59) == true)
        #expect(q.contains(hour: 8, minute: 0) == false)
        #expect(q.contains(hour: 21, minute: 0) == false)
    }

    @Test func quietHoursDisabledNeverContains() {
        let q = QuietHours(enabled: false, startMinutes: 0, endMinutes: 1439)
        #expect(q.contains(hour: 3, minute: 0) == false)
        #expect(q.contains(hour: 12, minute: 0) == false)
    }

    // MARK: - Preset switching

    @Test func presetOnceProducesSingleEveningReminder() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        #expect(service.preset == .once)
        let repeating = service.reminders.filter { !$0.isOneShot }
        #expect(repeating.count == 1)
        #expect(repeating.first?.timeComponents.hour == 21)
    }

    @Test func presetThriceProducesThreeReminders() {
        let (service, _) = makeService()
        service.apply(preset: .thrice)
        #expect(service.preset == .thrice)
        let repeating = service.reminders.filter { !$0.isOneShot }
        #expect(repeating.count == 3)
        #expect(repeating.map { $0.timeComponents.hour }.sorted() == [9, 13, 21])
    }

    @Test func presetCustomKeepsExistingReminders() {
        let (service, _) = makeService()
        service.apply(preset: .thrice)
        service.apply(preset: .custom)
        #expect(service.preset == .custom)
        #expect(service.reminders.filter { !$0.isOneShot }.count == 3)
    }

    @Test func presetSwitchKeepsOneShots() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        // 排一条未来的一次性。
        let future = Date().addingTimeInterval(3600)
        service.scheduleOnce(at: future, label: "一小时后")
        #expect(service.reminders.contains { $0.isOneShot })
        // 切预设不应清掉一次性。
        service.apply(preset: .thrice)
        #expect(service.reminders.contains { $0.isOneShot })
    }

    // MARK: - Reminder CRUD

    @Test func addAndRemoveReminder() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        service.apply(preset: .custom)
        let added = service.addReminder(
            Reminder(trigger: .daily(hour: 7, minute: 30), label: "晨跑后"))
        #expect(service.reminders.filter { !$0.isOneShot }.count == 2)
        service.removeReminder(added.id)
        #expect(service.reminders.filter { !$0.isOneShot }.count == 1)
    }

    @Test func scheduleOnceRejectsPastTime() {
        let (service, _) = makeService()
        let past = Date().addingTimeInterval(-60)
        let result = service.scheduleOnce(at: past, label: "过去")
        #expect(result == nil)
    }

    @Test func setReminderEnabledToggles() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        let id = service.reminders.first!.id
        service.setReminder(id, enabled: false)
        #expect(service.reminders.first?.enabled == false)
    }

    @Test func updateReminderReplacesTrigger() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        let id = service.reminders.first!.id
        service.updateReminder(id, trigger: .weekdays(days: [2, 4, 6], hour: 8, minute: 0), label: "隔天早")
        let updated = service.reminders.first { $0.id == id }
        #expect(updated?.repeatDescription == "周一、三、五")
        #expect(updated?.label == "隔天早")
    }

    // MARK: - Expiry pruning

    @Test func expiredOneShotPrunedOnReload() {
        let suite = "captureReminder.test.expire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // 手写一条已过期的一次性 + 一条重复,直接进 UserDefaults。
        let expired = Reminder(trigger: .once(Date().addingTimeInterval(-60)), label: "过期")
        let daily = Reminder(trigger: .daily(hour: 21, minute: 0), label: "睡前")
        let data = try! JSONEncoder().encode([expired, daily])
        defaults.set(data, forKey: "captureReminder.reminders")
        // 重新造实例 → init 里 pruneExpiredOneShots 应剔除过期一次性。
        let service = CaptureReminderService(defaults: defaults)
        #expect(service.reminders.count == 1)
        #expect(service.reminders.first?.isOneShot == false)
    }

    // MARK: - Legacy migration

    @Test func legacySlotsMigrateToReminders() {
        let suite = "captureReminder.test.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // 造旧 ReminderSlot 形状的 JSON(id/hour/minute/label/enabled)。
        let legacy: [[String: Any]] = [
            ["id": UUID().uuidString, "hour": 8, "minute": 30, "label": "晨间", "enabled": true],
            ["id": UUID().uuidString, "hour": 22, "minute": 0, "label": "睡前", "enabled": false]
        ]
        // Codable 的 UUID 编码为字符串,与 JSONSerialization 兼容。
        let data = try! JSONSerialization.data(withJSONObject: legacy)
        defaults.set(data, forKey: "captureReminder.slots")

        let service = CaptureReminderService(defaults: defaults)
        let repeating = service.reminders.filter { !$0.isOneShot }
        #expect(repeating.count == 2)
        #expect(repeating.contains { $0.timeComponents == (8, 30) && $0.enabled })
        #expect(repeating.contains { $0.timeComponents == (22, 0) && !$0.enabled })
        // 迁移后旧 key 应被清除,新 key 应写入。
        #expect(defaults.data(forKey: "captureReminder.slots") == nil)
        #expect(defaults.data(forKey: "captureReminder.reminders") != nil)
    }

    @Test func configPersistsAcrossReload() {
        let suite = "captureReminder.test.persist.\(UUID().uuidString)"
        let (service, _) = makeService(suite: suite)
        service.apply(preset: .thrice)
        let midID = service.reminders.filter { !$0.isOneShot }[1].id
        service.setReminder(midID, enabled: false)

        let reloaded = CaptureReminderService(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.preset == .thrice)
        let repeating = reloaded.reminders.filter { !$0.isOneShot }
        #expect(repeating.count == 3)
        #expect(repeating.contains { !$0.enabled })
    }

    // MARK: - Reminder presentation

    @Test func reminderTimeStringPadsZeros() {
        let r = Reminder(trigger: .daily(hour: 9, minute: 5), label: "早")
        #expect(r.timeString == "09:05")
    }

    @Test func reminderPromptBodyVariesByTimeOfDay() {
        let morning = Reminder(trigger: .daily(hour: 9, minute: 0), label: "早")
        let evening = Reminder(trigger: .daily(hour: 21, minute: 0), label: "晚")
        #expect(morning.promptBody != evening.promptBody)
        #expect(morning.promptBody.contains("早上"))
    }

    @Test func weekdayLabelKnownGroups() {
        #expect(Reminder.weekdayLabel(for: [1, 2, 3, 4, 5, 6, 7]) == "每天")
        #expect(Reminder.weekdayLabel(for: [2, 3, 4, 5, 6]) == "工作日")
        #expect(Reminder.weekdayLabel(for: [1, 7]) == "周末")
        #expect(Reminder.weekdayLabel(for: [2, 4, 6]) == "周一、三、五")
    }

    @Test func nextFireDateDailyRollsToTomorrowWhenPast() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // now = 2026-07-15 22:00,提醒 21:00 → 应滚到明天 21:00。
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 22, minute: 0))!
        let r = Reminder(trigger: .daily(hour: 21, minute: 0), label: "睡前")
        let next = r.nextFireDate(after: now, calendar: cal)
        let comps = cal.dateComponents([.day, .hour], from: next!)
        #expect(comps.day == 16)
        #expect(comps.hour == 21)
    }

    @Test func nextFireDateDisabledReturnsNil() {
        let r = Reminder(trigger: .daily(hour: 21, minute: 0), label: "睡前", enabled: false)
        #expect(r.nextFireDate() == nil)
    }

    @Test func nextFireDateOncePastReturnsNil() {
        let r = Reminder(trigger: .once(Date().addingTimeInterval(-60)), label: "过去")
        #expect(r.nextFireDate() == nil)
    }

    // MARK: - Upcoming query (Today capsule)

    @Test func upcomingSortsByNextFire() {
        let (service, _) = makeService()
        service.apply(preset: .custom)
        // 清掉默认,精确造两条重复。
        for r in service.reminders { service.removeReminder(r.id) }
        service.addReminder(Reminder(trigger: .daily(hour: 23, minute: 0), label: "晚"))
        service.addReminder(Reminder(trigger: .daily(hour: 6, minute: 0), label: "早"))
        let upcoming = service.upcoming(limit: 5)
        #expect(upcoming.count == 2)
        // 无论当前几点,两条下次触发时间点先后关系稳定可比。
        let firstNext = upcoming[0].nextFireDate()!
        let secondNext = upcoming[1].nextFireDate()!
        #expect(firstNext <= secondNext)
    }

    // MARK: - RelativeTimeResolver

    @Test func resolverAfterSeconds() {
        let now = Date()
        let resolved = RelativeTimeResolver.resolve(.afterSeconds(3600), now: now)
        #expect(abs(resolved!.timeIntervalSince(now) - 3600) < 1)
    }

    @Test func resolverTonightIsEvening() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 14, minute: 0))!
        let resolved = RelativeTimeResolver.resolve(.tonight, now: now, calendar: cal)!
        let comps = cal.dateComponents([.day, .hour], from: resolved)
        #expect(comps.day == 15)
        #expect(comps.hour == RelativeTimeResolver.eveningHour)
    }

    @Test func resolverTomorrowMorning() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 23, minute: 0))!
        let resolved = RelativeTimeResolver.resolve(.tomorrowMorning, now: now, calendar: cal)!
        let comps = cal.dateComponents([.day, .hour], from: resolved)
        #expect(comps.day == 16)
        #expect(comps.hour == RelativeTimeResolver.morningHour)
    }

    @Test func resolverAtRollsToTomorrowWhenPast() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 15, minute: 0))!
        // 说「10 点」但现在 15 点 → 明天 10 点。
        let resolved = RelativeTimeResolver.resolve(.at(hour: 10, minute: 0), now: now, calendar: cal)!
        let comps = cal.dateComponents([.day, .hour], from: resolved)
        #expect(comps.day == 16)
        #expect(comps.hour == 10)
    }

    // MARK: - AlarmKit 授权态(灵动岛路径)
    //
    // 2026-07-15:灵动岛「没生效」的根因是授权态只活在内存里 —— 用户在
    // onboarding 授过权,但 alarmKitAuthorized 不落盘,下次冷启动重置回 false,
    // useAlarmKit 随之恒 false,提醒静默退化成普通 UN 通知。修法是每次前台
    // 从 AlarmKit 读真实 authorizationState 回填,而不是把它记在 UserDefaults
    // 里 —— 权限的真源是系统,缓存必然会和「用户去设置里关掉」脱节。

    /// preferAlarmKit 是用户偏好,必须跨实例(≈冷启动)存活。
    @Test func preferAlarmKitSurvivesRelaunch() {
        let suite = "captureReminder.test.\(UUID().uuidString)"
        let (service, defaults) = makeService(suite: suite)
        #expect(service.preferAlarmKit == true) // 默认 on

        service.preferAlarmKit = false
        // 同一 suite 造新实例 = 冷启动重读。
        let relaunched = CaptureReminderService(defaults: defaults)
        #expect(relaunched.preferAlarmKit == false)
    }

    /// 授权态绝不能被偏好或持久化「推断」成 true —— 它只能来自系统。
    /// 冷启动默认 false,直到 refreshAlarmKitAuthorizationState() 去问 AlarmKit。
    @Test func alarmKitAuthorizationIsNeverAssumedFromPreference() {
        let (service, _) = makeService()
        service.preferAlarmKit = true
        // 偏好开着不代表系统授了权:两者是独立的与条件。
        #expect(service.alarmKitAuthorized == false)
    }
}
