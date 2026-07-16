import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - SettingsRemindersView

/// "提醒与通知" — capture reminders (frequency, quiet hours, AlarmKit) and
/// the nightly compile-complete notification, merged into one page. These
/// used to be two unrelated sections ("通知" and "记录提醒").
@MainActor
struct SettingsRemindersView: View {

    // Issue #20: 2am 编译完成本地通知开关。Default true.
    @AppStorage(AppSettings.Keys.notifyCompile) private var notifyCompile: Bool = true

    @StateObject private var reminderService = CaptureReminderService.shared
    @StateObject private var flagStore = FeatureFlagStore.shared

    var body: some View {
        List {
            Group {
                if flagStore.isEnabled(.captureReminder) {
                    captureReminderSection
                }
                notificationsSection
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.bgWarm.ignoresSafeArea())
        .tint(DSColor.primary)
        .navigationTitle(NSLocalizedString("settings.hub.reminders", comment: "Reminders & notifications page title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Capture reminders

    private var captureReminderSection: some View {
        Section {
            Picker(
                NSLocalizedString("settings.reminder.frequency", value: "提醒频率", comment: "Capture reminder frequency preset"),
                selection: Binding(
                    get: { reminderService.preset },
                    set: { newValue in
                        Haptics.selection()
                        reminderService.apply(preset: newValue)
                    }
                )
            ) {
                ForEach(ReminderPreset.allCases, id: \.rawValue) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            // 已配置提醒的只读摘要 —— 具体增删改在 Today 页胶囊 & AI 对话。
            HStack {
                SettingsLabel(
                    title: NSLocalizedString("settings.reminder.active", value: "已启用提醒", comment: "Active reminders summary"),
                    systemImage: "bell.badge"
                )
                Spacer()
                let count = reminderService.reminders.filter { $0.enabled }.count
                Text(String(format: NSLocalizedString("settings.reminder.count", value: "%d 条", comment: "N reminders count"), count))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .accessibilityIdentifier("reminder-active-count")

            Toggle(isOn: Binding(
                get: { reminderService.quietHours.enabled },
                set: { enabled in
                    var hours = reminderService.quietHours
                    hours.enabled = enabled
                    reminderService.updateQuietHours(hours)
                }
            )) {
                HStack {
                    SettingsLabel(
                        title: NSLocalizedString("settings.reminder.quiet", value: "静音时段", comment: "Quiet hours toggle"),
                        systemImage: "moon.zzz"
                    )
                    Spacer()
                    if reminderService.quietHours.enabled {
                        Text("\(reminderService.quietHours.startString)–\(reminderService.quietHours.endString)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
            }
            .accessibilityIdentifier("reminder-quiet-hours")

            // 仅 iOS 26+：系统灵动岛(AlarmKit)。开偏好时必须真的请求授权 —
            // useAlarmKit 同时要求 alarmKitAuthorized（见 2026-07-15 备注）。
            if reminderService.isAlarmKitAvailable {
                Toggle(isOn: Binding(
                    get: { reminderService.preferAlarmKit },
                    set: { enabled in
                        reminderService.preferAlarmKit = enabled
                        guard enabled, #available(iOS 26.0, *) else { return }
                        Task { await reminderService.requestAlarmKitAuthorization() }
                    }
                )) {
                    SettingsLabel(
                        title: NSLocalizedString("settings.reminder.alarmkit", value: "系统灵动岛提醒", comment: "Use AlarmKit system Live Activity"),
                        systemImage: "bell.badge.waveform"
                    )
                }
                .accessibilityIdentifier("reminder-prefer-alarmkit")

                if reminderService.preferAlarmKit && !reminderService.alarmKitAuthorized {
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
                    .accessibilityIdentifier("reminder-alarmkit-denied-hint")
                }
            }
        } header: {
            Text(NSLocalizedString("settings.reminder.section", value: "记录提醒", comment: "Capture reminder section title"))
        } footer: {
            Text(NSLocalizedString(
                "settings.reminder.footer",
                value: "到点时会发一条本地通知(灵动岛落点)召唤你记一句。长按通知可选「语音」或「文字」。\n在 Today 页可增删提醒;也可在「问过去」里直接说「每天晚上 10 点提醒我」或「一小时后叫我」,让 AI 帮你排。静音时段内的重复提醒会自动跳过。",
                comment: "Footer explaining capture reminders"
            ))
            .font(.caption)
        }
    }

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $notifyCompile) {
                SettingsLabel(
                    title: NSLocalizedString(
                        "settings.notifications.compile",
                        value: "整理完成通知",
                        comment: "Toggle: send a local notification once nightly Daily Page compile finishes"
                    ),
                    systemImage: "bell.badge"
                )
            }
        } header: {
            Text(NSLocalizedString(
                "settings.notifications.section_title",
                value: "通知",
                comment: "Settings section title for local-notification controls"
            ))
        } footer: {
            Text(NSLocalizedString(
                "settings.notifications.footer",
                value: "凌晨 2:00 后台自动整理完成时，会发本地通知到锁屏。",
                comment: "Footer explaining when the compile-complete notification fires"
            ))
            .font(.caption)
        }
    }
}

#Preview {
    NavigationStack { SettingsRemindersView() }
}
