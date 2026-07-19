import SwiftUI
import DayPageServices

// MARK: - ScheduleHubView
//
// "调度中心" — the single, fully editable home for capture reminders. Where
// SettingsRemindersView.swift shows a read-only summary, this page is the
// canonical CRUD surface: every reminder (user- or AI-authored) can be added,
// edited, toggled, re-leveled, and deleted here.
//
// Structure (top → bottom, "museum" ladder):
//   1. Reminder list — one row per reminder, sorted by next fire time, with a
//      tappable level chip (quiet ⇄ loud) + enable toggle + swipe-to-delete.
//   2. Global config — frequency preset, quiet hours (toggle + times), and the
//      iOS 26 AlarmKit switch (mirrors SettingsRemindersView's logic).
//
// Presentation: pushed inside a NavigationStack from the sidebar sheet. All
// mutations route through CaptureReminderService's unified API.

@MainActor
struct ScheduleHubView: View {

    @StateObject private var service = CaptureReminderService.shared
    @State private var sheetTarget: ReminderSheetTarget?

    var body: some View {
        List {
            reminderSection
            frequencySection
            quietHoursSection
            alarmKitSection
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.primary)
        .navigationTitle(NSLocalizedString("schedule.hub.title", value: "调度", comment: "Schedule hub page title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.light()
                    sheetTarget = ReminderSheetTarget(reminder: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(NSLocalizedString("schedule.add", value: "新建提醒", comment: "Add reminder"))
                .accessibilityIdentifier("schedule-add-reminder")
            }
        }
        .sheet(item: $sheetTarget) { target in
            ReminderEditSheet(service: service, editing: target.reminder)
        }
    }

    // MARK: - Reminder List Section

    /// One row per reminder, sorted so the soonest-to-fire sits on top (disabled
    /// reminders — which have no next fire — settle at the bottom by label).
    private var reminderSection: some View {
        Section {
            if sortedReminders.isEmpty {
                emptyRow
            } else {
                ForEach(sortedReminders) { reminder in
                    ReminderHubRow(
                        reminder: reminder,
                        onTap: {
                            Haptics.light()
                            sheetTarget = ReminderSheetTarget(reminder: reminder)
                        },
                        onToggle: { enabled in
                            service.setReminder(reminder.id, enabled: enabled)
                        },
                        onCycleLevel: {
                            Haptics.selection()
                            service.setLevel(reminder.id, reminder.level == .quiet ? .loud : .quiet)
                        }
                    )
                    .listRowBackground(DSColor.surfaceWhite)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Haptics.light()
                            service.removeReminder(reminder.id)
                        } label: {
                            Label(
                                NSLocalizedString("schedule.delete", value: "删除", comment: "Delete reminder swipe"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("schedule.section.reminders", value: "提醒", comment: "Reminders list section title"))
        } footer: {
            Text(NSLocalizedString(
                "schedule.section.reminders.footer",
                value: "点一条编辑;右滑删除;点级别芯片在「安静 / 重要」间切换。到点会发一条本地通知(灵动岛落点)召唤你记一句。",
                comment: "Reminders section footer"
            ))
            .font(.caption)
        }
    }

    /// Sorted for display: enabled reminders first (by soonest next fire), then
    /// disabled ones grouped at the end sorted by label so the list is stable.
    private var sortedReminders: [Reminder] {
        service.reminders.sorted { lhs, rhs in
            switch (lhs.nextFireDate(), rhs.nextFireDate()) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.label < rhs.label
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: "bell.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DSColor.inkSubtle)
            Text(NSLocalizedString(
                "schedule.empty",
                value: "还没有提醒。点右上角「＋」排一条,或在「问过去」里让 AI 帮你排。",
                comment: "Empty reminders hint"
            ))
            .font(DSType.bodySM)
            .foregroundColor(DSColor.inkMuted)
        }
        .padding(.vertical, DSSpacing.xs)
        .listRowBackground(DSColor.surfaceWhite)
        .accessibilityIdentifier("schedule-empty")
    }

    // MARK: - Frequency Section

    private var frequencySection: some View {
        Section {
            Picker(
                NSLocalizedString("settings.reminder.frequency", value: "提醒频率", comment: "Capture reminder frequency preset"),
                selection: Binding(
                    get: { service.preset },
                    set: { newValue in
                        Haptics.selection()
                        service.apply(preset: newValue)
                    }
                )
            ) {
                ForEach(ReminderPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .listRowBackground(DSColor.surfaceWhite)
        } header: {
            Text(NSLocalizedString("schedule.section.frequency", value: "频率", comment: "Frequency section title"))
        } footer: {
            Text(NSLocalizedString(
                "schedule.section.frequency.footer",
                value: "切换预设会替换上面的重复提醒。「自定义」保留你手动排的每一条。",
                comment: "Frequency footer"
            ))
            .font(.caption)
        }
    }

    // MARK: - Quiet Hours Section

    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { service.quietHours.enabled },
                set: { enabled in
                    var hours = service.quietHours
                    hours.enabled = enabled
                    service.updateQuietHours(hours)
                }
            )) {
                SettingsLabel(
                    title: NSLocalizedString("settings.reminder.quiet", value: "静音时段", comment: "Quiet hours toggle"),
                    systemImage: "moon.zzz"
                )
            }
            .listRowBackground(DSColor.surfaceWhite)
            .accessibilityIdentifier("schedule-quiet-hours")

            if service.quietHours.enabled {
                quietTimeRow(
                    titleKey: "schedule.quiet.start",
                    fallback: "开始",
                    minutes: service.quietHours.startMinutes,
                    onChange: { newMinutes in
                        var hours = service.quietHours
                        hours.startMinutes = newMinutes
                        service.updateQuietHours(hours)
                    }
                )
                .listRowBackground(DSColor.surfaceWhite)

                quietTimeRow(
                    titleKey: "schedule.quiet.end",
                    fallback: "结束",
                    minutes: service.quietHours.endMinutes,
                    onChange: { newMinutes in
                        var hours = service.quietHours
                        hours.endMinutes = newMinutes
                        service.updateQuietHours(hours)
                    }
                )
                .listRowBackground(DSColor.surfaceWhite)
            }
        } header: {
            Text(NSLocalizedString("schedule.section.quiet", value: "静音", comment: "Quiet hours section title"))
        } footer: {
            Text(NSLocalizedString(
                "schedule.section.quiet.footer",
                value: "静音时段内的重复提醒会自动跳过。跨午夜也支持(如 23:30–08:00)。",
                comment: "Quiet hours footer"
            ))
            .font(.caption)
        }
    }

    /// A single quiet-hours time picker row. Bridges the service's
    /// "minutes since midnight" model to a `.hourAndMinute` DatePicker.
    private func quietTimeRow(titleKey: String, fallback: String, minutes: Int, onChange: @escaping (Int) -> Void) -> some View {
        DatePicker(
            NSLocalizedString(titleKey, value: fallback, comment: "Quiet hours time"),
            selection: Binding(
                get: { Self.dateFrom(minutes: minutes) },
                set: { onChange(Self.minutes(from: $0)) }
            ),
            displayedComponents: [.hourAndMinute]
        )
        .foregroundColor(DSColor.inkPrimary)
    }

    // MARK: - AlarmKit Section (iOS 26+)

    @ViewBuilder
    private var alarmKitSection: some View {
        // Only iOS 26+ exposes the system Live Activity (AlarmKit) path.
        if service.isAlarmKitAvailable {
            Section {
                Toggle(isOn: Binding(
                    get: { service.preferAlarmKit },
                    set: { enabled in
                        service.preferAlarmKit = enabled
                        guard enabled, #available(iOS 26.0, *) else { return }
                        Task { await service.requestAlarmKitAuthorization() }
                    }
                )) {
                    SettingsLabel(
                        title: NSLocalizedString("settings.reminder.alarmkit", value: "系统灵动岛提醒", comment: "Use AlarmKit system Live Activity"),
                        systemImage: "bell.badge.waveform"
                    )
                }
                .listRowBackground(DSColor.surfaceWhite)
                .accessibilityIdentifier("schedule-prefer-alarmkit")

                if service.preferAlarmKit && !service.alarmKitAuthorized {
                    Label(
                        NSLocalizedString(
                            "settings.reminder.alarmkit.denied",
                            value: "系统未授权提醒,灵动岛不会出现 —— 前往「设置 › DayPage」开启。",
                            comment: "AlarmKit permission missing hint"
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundColor(DSColor.warnAmber)
                    .listRowBackground(DSColor.surfaceWhite)
                    .accessibilityIdentifier("schedule-alarmkit-denied-hint")
                }
            } header: {
                Text(NSLocalizedString("schedule.section.alarmkit", value: "系统提醒", comment: "AlarmKit section title"))
            }
        }
    }

    // MARK: - Minutes ⇄ Date helpers

    /// Anchor a "minutes since midnight" value onto today's date so a
    /// `.hourAndMinute` DatePicker can bind to it.
    private static func dateFrom(minutes: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = (minutes / 60) % 24
        comps.minute = minutes % 60
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

// MARK: - ReminderHubRow

/// One reminder row: leading icon (clock for one-shot, bell for repeating),
/// primary line + label, an "AI" source badge, a tappable level chip, and the
/// enable toggle. Kept as a standalone view so `body` stays readable.
private struct ReminderHubRow: View {
    let reminder: Reminder
    let onTap: () -> Void
    let onToggle: (Bool) -> Void
    let onCycleLevel: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            leadingIcon

            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(primaryLine)
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if !reminder.label.isEmpty {
                            Text(reminder.label)
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.inkMuted)
                                .lineLimit(1)
                        }
                        if reminder.source == .ai {
                            aiBadge
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            levelChip

            Toggle("", isOn: Binding(
                get: { reminder.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .accessibilityLabel(NSLocalizedString("schedule.row.enabled", value: "启用", comment: "Reminder enabled toggle"))
        }
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    // MARK: Subviews

    private var leadingIcon: some View {
        Image(systemName: reminder.isOneShot ? "clock" : "bell")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(reminder.enabled ? DSColor.accentOnBg : DSColor.inkSubtle)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(reminder.enabled ? DSColor.amberSoft : Color.clear)
            )
    }

    private var aiBadge: some View {
        Text("AI")
            .font(DSType.mono9)
            .tracking(0.5)
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(DSColor.amberSoft, in: Capsule())
            .accessibilityLabel(NSLocalizedString("schedule.badge.ai", value: "AI 排的提醒", comment: "AI-authored reminder badge"))
    }

    /// Tappable pill communicating the presentation level. Quiet = soft green
    /// (calm, floats), loud = terracotta (alarm). Tapping cycles between them.
    private var levelChip: some View {
        let isQuiet = reminder.level == .quiet
        let tint = isQuiet ? DSColor.statusSuccess : DSColor.statusError
        return Button(action: onCycleLevel) {
            Text(isQuiet
                ? NSLocalizedString("reminder.level.quiet", value: "安静", comment: "Quiet reminder level")
                : NSLocalizedString("reminder.level.loud", value: "重要", comment: "Loud reminder level"))
                .font(DSType.labelSM)
                .foregroundColor(tint)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, 3)
                .background(tint.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isQuiet
            ? NSLocalizedString("schedule.level.a11y.quiet", value: "级别:安静,点按切换为重要", comment: "Quiet level chip a11y")
            : NSLocalizedString("schedule.level.a11y.loud", value: "级别:重要,点按切换为安静", comment: "Loud level chip a11y"))
        .accessibilityIdentifier("schedule-level-chip")
    }

    /// One-shot → relative day label; repeating → "每天 21:00" style line.
    private var primaryLine: String {
        if reminder.isOneShot {
            return reminder.repeatDescription
        }
        return "\(reminder.repeatDescription) \(reminder.timeString)"
    }
}

#Preview {
    NavigationStack { ScheduleHubView() }
}
