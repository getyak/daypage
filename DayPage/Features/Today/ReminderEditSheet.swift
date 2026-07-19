import SwiftUI

// MARK: - ReminderSheetTarget

/// `.sheet(item:)` 的 Identifiable 包装：`reminder == nil` 表示新建。
/// id 取 reminder 的稳定 id（新建用随机 UUID），编辑不同条目时 sheet 会
/// 正确重建而不是复用旧编辑态。
struct ReminderSheetTarget: Identifiable {
    let reminder: Reminder?
    var id: UUID { reminder?.id ?? Self.newItemID }
    /// 新建场景的固定 id —— 连续点两次「＋」不会重复弹 sheet。
    private static let newItemID = UUID()
}

// MARK: - ReminderEditSheet
//
// 提醒的编辑 / 新建 sheet(vNext,2026-07-15)。仿滴答清单的时间自定义:
//   • 顶部分段:一次性 / 每天 / 指定周几
//   • 时间轮盘(DatePicker .wheel .hourAndMinute)
//   • 「指定周几」时露出周几 chips(每天/工作日/周末快捷 + 单独一~日)
//   • 「一次性」时露出快捷 chips(1 小时后 / 今晚 / 明早)直接落时间
//   • 标签输入(可空)
//
// 保存/删除都走 CaptureReminderService 统一 API。这是「设置页简化、复杂
// 度藏调度」里 UI 侧的复杂落点 —— 但仍是可选路径,自然语言走 AI 对话。

struct ReminderEditSheet: View {
    @ObservedObject var service: CaptureReminderService
    @Environment(\.dismiss) private var dismiss

    /// 非 nil = 编辑现有;nil = 新建。
    let editing: Reminder?

    // MARK: Local edit state

    private enum Kind: String, CaseIterable {
        case once, daily, weekdays
        var title: String {
            switch self {
            case .once:     return NSLocalizedString("reminder.kind.once", value: "一次", comment: "One-shot reminder")
            case .daily:    return NSLocalizedString("reminder.kind.daily", value: "每天", comment: "Daily reminder")
            case .weekdays: return NSLocalizedString("reminder.kind.weekdays", value: "周几", comment: "Weekday reminder")
            }
        }
    }

    @State private var kind: Kind
    @State private var time: Date
    @State private var selectedDays: Set<Int>
    @State private var label: String
    /// 呈现级别 —— 安静(灵动岛/横幅悬浮)/ 重要(闹钟)。默认安静。
    @State private var level: Reminder.Level

    // MARK: Init

    init(service: CaptureReminderService, editing: Reminder?) {
        self.service = service
        self.editing = editing

        // 从现有 reminder 还原编辑态,或给合理默认(今天此刻的下一个整点)。
        if let r = editing {
            switch r.trigger {
            case .once(let date):
                _kind = State(initialValue: .once)
                _time = State(initialValue: date)
                _selectedDays = State(initialValue: [2, 3, 4, 5, 6])
            case .daily(let h, let m):
                _kind = State(initialValue: .daily)
                _time = State(initialValue: Self.dateAt(hour: h, minute: m))
                _selectedDays = State(initialValue: [2, 3, 4, 5, 6])
            case .weekdays(let days, let h, let m):
                _kind = State(initialValue: .weekdays)
                _time = State(initialValue: Self.dateAt(hour: h, minute: m))
                _selectedDays = State(initialValue: days)
            }
            _label = State(initialValue: r.label)
            _level = State(initialValue: r.level)
        } else {
            _kind = State(initialValue: .once)
            _time = State(initialValue: Self.defaultOnceTime())
            _selectedDays = State(initialValue: [2, 3, 4, 5, 6])
            _label = State(initialValue: "")
            _level = State(initialValue: .quiet)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 类型分段。
                Section {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases, id: \.rawValue) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reminder-kind-picker")
                }

                // 呈现级别 —— 安静(默认,灵动岛/横幅悬浮不吵)/ 重要(闹钟+声音)。
                // vNext 分层的落点:先答"这条有多重要",再定时间。
                Section {
                    Picker("", selection: $level) {
                        Text(NSLocalizedString("reminder.level.quiet", value: "安静", comment: "Quiet reminder level"))
                            .tag(Reminder.Level.quiet)
                        Text(NSLocalizedString("reminder.level.loud", value: "重要", comment: "Loud reminder level"))
                            .tag(Reminder.Level.loud)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reminder-level-picker")
                } header: {
                    Text(NSLocalizedString("reminder.level.section", value: "提醒方式", comment: "Reminder presentation level"))
                } footer: {
                    Text(level == .quiet
                        ? NSLocalizedString("reminder.level.quiet.hint", value: "到点在灵动岛 / 锁屏优雅悬浮,不响、不夺屏。", comment: "Quiet level footer")
                        : NSLocalizedString("reminder.level.loud.hint", value: "到点全屏闹钟 + 声音。留给不能错过的事。", comment: "Loud level footer"))
                        .font(.caption)
                }

                // 一次性快捷 chips —— 直接落一个绝对时间点到轮盘。
                if kind == .once {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(RelativeTimeResolver.quickChips.indices, id: \.self) { i in
                                    let chip = RelativeTimeResolver.quickChips[i]
                                    quickChip(title: chip.title, token: chip.token)
                                }
                            }
                        }
                    } header: {
                        Text(NSLocalizedString("reminder.quick", value: "快捷", comment: "Quick relative times"))
                    }
                }

                // 时间轮盘。
                Section {
                    DatePicker(
                        NSLocalizedString("reminder.time", value: "时间", comment: "Reminder time"),
                        selection: $time,
                        displayedComponents: kind == .once ? [.date, .hourAndMinute] : [.hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("reminder-time-picker")
                }

                // 周几选择(仅 .weekdays)。
                if kind == .weekdays {
                    Section {
                        weekdayPresetRow
                        weekdayGrid
                    } header: {
                        Text(NSLocalizedString("reminder.weekdays", value: "重复", comment: "Weekday repeat"))
                    }
                }

                // 标签。
                Section {
                    TextField(
                        NSLocalizedString("reminder.label.placeholder", value: "标签(可空)", comment: "Reminder label placeholder"),
                        text: $label
                    )
                    .accessibilityIdentifier("reminder-label-field")
                }

                // 删除(仅编辑态)。
                if let editing {
                    Section {
                        Button(role: .destructive) {
                            Haptics.light()
                            service.removeReminder(editing.id)
                            dismiss()
                        } label: {
                            Text(NSLocalizedString("reminder.delete", value: "删除提醒", comment: "Delete reminder"))
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("reminder-delete")
                    }
                }
            }
            .navigationTitle(editing == nil
                ? NSLocalizedString("reminder.new.title", value: "新提醒", comment: "New reminder title")
                : NSLocalizedString("reminder.edit.title", value: "编辑提醒", comment: "Edit reminder title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", value: "取消", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", value: "保存", comment: "Save")) { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("reminder-save")
                }
            }
        }
    }

    // MARK: - Weekday UI

    private var weekdayPresetRow: some View {
        HStack(spacing: 8) {
            presetChip("每天", days: [1, 2, 3, 4, 5, 6, 7])
            presetChip("工作日", days: [2, 3, 4, 5, 6])
            presetChip("周末", days: [1, 7])
        }
    }

    private func presetChip(_ title: String, days: Set<Int>) -> some View {
        Button {
            Haptics.selection()
            selectedDays = days
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selectedDays == days ? .white : DSColor.amberAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selectedDays == days ? DSColor.amberAccent : DSColor.amberSoft)
                )
        }
        .buttonStyle(.plain)
    }

    private var weekdayGrid: some View {
        // 周一…周日(把周日排最后,符合中文直觉)。
        let order = [2, 3, 4, 5, 6, 7, 1]
        let names = ["", "日", "一", "二", "三", "四", "五", "六"]
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let on = selectedDays.contains(day)
                Button {
                    Haptics.selection()
                    if on { selectedDays.remove(day) } else { selectedDays.insert(day) }
                } label: {
                    Text(names[day])
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(on ? .white : DSColor.inkMuted)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(on ? DSColor.amberAccent : DSColor.glassLo)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reminder-weekday-\(day)")
            }
        }
    }

    // MARK: - Quick chip (once)

    private func quickChip(title: String, token: RelativeTimeResolver.Token) -> some View {
        Button {
            Haptics.selection()
            if let resolved = RelativeTimeResolver.resolve(token) {
                time = resolved
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DSColor.amberAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(DSColor.amberSoft))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    private var canSave: Bool {
        switch kind {
        case .once:
            return time > Date()
        case .daily:
            return true
        case .weekdays:
            return !selectedDays.isEmpty
        }
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let h = comps.hour ?? 21
        let m = comps.minute ?? 0
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

        let trigger: Reminder.Trigger
        switch kind {
        case .once:      trigger = .once(time)
        case .daily:     trigger = .daily(hour: h, minute: m)
        case .weekdays:  trigger = .weekdays(days: selectedDays, hour: h, minute: m)
        }

        if let editing {
            service.updateReminder(editing.id, trigger: trigger, label: trimmedLabel, level: level)
        } else {
            let fallbackLabel = trimmedLabel.isEmpty ? defaultLabel(for: kind) : trimmedLabel
            service.addReminder(Reminder(trigger: trigger, label: fallbackLabel, source: .user, level: level))
        }
        Haptics.success()
        dismiss()
    }

    private func defaultLabel(for kind: Kind) -> String {
        switch kind {
        case .once:     return NSLocalizedString("reminder.default.once", value: "稍后", comment: "Default one-shot label")
        case .daily:    return NSLocalizedString("reminder.default.daily", value: "每日记录", comment: "Default daily label")
        case .weekdays: return NSLocalizedString("reminder.default.weekdays", value: "定期记录", comment: "Default weekday label")
        }
    }

    // MARK: - Helpers

    private static func dateAt(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// 新建一次性的默认时间:下一个整点(至少 +1 小时)。
    private static func defaultOnceTime() -> Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: next)
        comps.minute = 0
        return cal.date(from: comps) ?? next
    }
}
