// CaptureReminderServiceTests.swift — 「定时召唤记录」定时引擎
//
// 覆盖三块纯逻辑(不碰真实 UNUserNotificationCenter):
//   * QuietHours.contains — 同日区间 + 跨午夜区间 + disabled 短路
//   * 预设切换 apply(preset:) — once/thrice 覆盖 slots,custom 保留
//   * slot 增删改 + 持久化 round-trip(注入独立 UserDefaults 隔离)
//
// service 是 @MainActor singleton,但 init(defaults:) 允许注入独立的
// UserDefaults suite,所以测试造独立实例、不污染 .standard / singleton。

import Testing
import Foundation
@testable import DayPage

@MainActor
@Suite(.serialized)
struct CaptureReminderServiceTests {

    /// 造一个用独立 UserDefaults suite 的 service,测试互不干扰。
    private func makeService(suite: String = "captureReminder.test.\(UUID().uuidString)") -> (CaptureReminderService, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CaptureReminderService(defaults: defaults), defaults)
    }

    // MARK: - QuietHours

    @Test func quietHoursSameDayRange() {
        // 01:00–06:00 静音。
        let q = QuietHours(enabled: true, startMinutes: 60, endMinutes: 360)
        #expect(q.contains(hour: 0, minute: 30) == false)  // 00:30 区间外
        #expect(q.contains(hour: 1, minute: 0) == true)    // 01:00 起点(含)
        #expect(q.contains(hour: 3, minute: 0) == true)    // 03:00 区间内
        #expect(q.contains(hour: 6, minute: 0) == false)   // 06:00 终点(不含)
        #expect(q.contains(hour: 9, minute: 0) == false)   // 09:00 区间外
    }

    @Test func quietHoursOvernightRange() {
        // 23:30–08:00 跨午夜静音(默认值)。
        let q = QuietHours.defaultQuiet
        #expect(q.contains(hour: 23, minute: 30) == true)  // 起点(含)
        #expect(q.contains(hour: 23, minute: 45) == true)  // 午夜前
        #expect(q.contains(hour: 0, minute: 0) == true)    // 午夜
        #expect(q.contains(hour: 7, minute: 59) == true)   // 08:00 前
        #expect(q.contains(hour: 8, minute: 0) == false)   // 终点(不含)
        #expect(q.contains(hour: 21, minute: 0) == false)  // 晚上 21:00 区间外
    }

    @Test func quietHoursDisabledNeverContains() {
        let q = QuietHours(enabled: false, startMinutes: 0, endMinutes: 1439)
        // 即使区间覆盖几乎全天,disabled 时永远 false。
        #expect(q.contains(hour: 3, minute: 0) == false)
        #expect(q.contains(hour: 12, minute: 0) == false)
    }

    // MARK: - Preset switching

    @Test func presetOnceProducesSingleEveningSlot() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        #expect(service.preset == .once)
        #expect(service.slots.count == 1)
        #expect(service.slots.first?.hour == 21)
    }

    @Test func presetThriceProducesThreeSlots() {
        let (service, _) = makeService()
        service.apply(preset: .thrice)
        #expect(service.preset == .thrice)
        #expect(service.slots.count == 3)
        #expect(service.slots.map(\.hour) == [9, 13, 21])
    }

    @Test func presetCustomKeepsExistingSlots() {
        let (service, _) = makeService()
        service.apply(preset: .thrice)          // 先有 3 个
        service.apply(preset: .custom)          // 切 custom
        // custom 保留现有 slots,不清空。
        #expect(service.preset == .custom)
        #expect(service.slots.count == 3)
    }

    // MARK: - Slot CRUD + persistence

    @Test func addAndRemoveSlot() {
        let (service, _) = makeService()
        service.apply(preset: .once)            // 1 个
        service.apply(preset: .custom)
        service.addSlot(hour: 7, minute: 30, label: "晨跑后")
        #expect(service.slots.count == 2)
        // 新增后按时间排序:07:30 应排在 21:00 前。
        #expect(service.slots.first?.hour == 7)

        let toRemove = service.slots.first!.id
        service.removeSlot(toRemove)
        #expect(service.slots.count == 1)
        #expect(service.slots.first?.hour == 21)
    }

    @Test func updateSlotTimeClampsToValidRange() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        let id = service.slots.first!.id
        service.updateSlot(id, hour: 99, minute: 99)  // 越界
        #expect(service.slots.first?.hour == 23)       // clamp 到 23
        #expect(service.slots.first?.minute == 59)     // clamp 到 59
    }

    @Test func setSlotEnabledToggles() {
        let (service, _) = makeService()
        service.apply(preset: .once)
        let id = service.slots.first!.id
        service.setSlot(id, enabled: false)
        #expect(service.slots.first?.enabled == false)
    }

    @Test func configPersistsAcrossReload() {
        let suite = "captureReminder.test.persist.\(UUID().uuidString)"
        let (service, _) = makeService(suite: suite)
        service.apply(preset: .thrice)
        service.setSlot(service.slots[1].id, enabled: false)  // 关掉午

        // 用同一个 suite 重新造实例 → 应从 UserDefaults 还原。
        let reloaded = CaptureReminderService(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.preset == .thrice)
        #expect(reloaded.slots.count == 3)
        #expect(reloaded.slots[1].enabled == false)
    }

    // MARK: - ReminderSlot presentation

    @Test func slotTimeStringPadsZeros() {
        let slot = ReminderSlot(hour: 9, minute: 5, label: "早", enabled: true)
        #expect(slot.timeString == "09:05")
    }

    @Test func slotPromptBodyVariesByTimeOfDay() {
        let morning = ReminderSlot(hour: 9, minute: 0, label: "早", enabled: true)
        let evening = ReminderSlot(hour: 21, minute: 0, label: "晚", enabled: true)
        #expect(morning.promptBody != evening.promptBody)
        #expect(morning.promptBody.contains("早上"))
    }
}
