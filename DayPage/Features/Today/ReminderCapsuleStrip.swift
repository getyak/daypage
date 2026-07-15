import SwiftUI

// MARK: - ReminderCapsuleStrip
//
// Today 页的轻量提醒条(vNext,2026-07-15)。横向列出「即将触发」的提醒
// 胶囊(如「今晚 22:00 · 睡前」),点一下进编辑;尾部一个「＋ 提醒我」入口
// 落一次性。设计原则:不抢 Today 主流,空态整条收起(不占高度)。
//
// 复杂的自定义(周几、精确时间)在编辑 sheet 里;更自然语言的调度走「问过去」
// 对话。这条只是 Today 上的可见落点 + 快捷入口。
//
// 数据源:CaptureReminderService.shared(统一调度器)。整条受
// FeatureFlag.captureReminder 门控 —— flag 关时调用方不挂载本视图。

struct ReminderCapsuleStrip: View {
    @ObservedObject var service: CaptureReminderService

    /// 当前时钟(由父视图的 currentTime 传入,让胶囊文案随时间刷新)。
    let now: Date

    /// 点某条提醒 → 打开编辑 sheet。
    var onEdit: (Reminder) -> Void
    /// 点「＋ 提醒我」→ 打开快捷新建。
    var onAdd: () -> Void

    private var upcoming: [Reminder] {
        service.upcoming(limit: 4, now: now)
    }

    var body: some View {
        // 空态:没有即将触发的提醒时,只留一个极简的「＋ 提醒我」入口,
        // 而不是整条消失 —— 给用户一个发现「可以排提醒」的钩子。
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(upcoming) { reminder in
                    capsule(for: reminder)
                }
                addButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("reminder-capsule-strip")
    }

    // MARK: - Capsule

    private func capsule(for reminder: Reminder) -> some View {
        Button {
            Haptics.selection()
            onEdit(reminder)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: reminder.isOneShot ? "clock" : "bell.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DSColor.amberAccent)
                Text(headline(for: reminder))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                if !reminder.label.isEmpty {
                    Text(reminder.label)
                        .font(.system(size: 12))
                        .foregroundColor(DSColor.inkSubtle)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColor.glassLo)
                    .overlay(Capsule(style: .continuous).strokeBorder(DSColor.amberRim, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reminder-capsule-\(reminder.timeString)")
        .accessibilityLabel("\(headline(for: reminder)) \(reminder.label)")
    }

    /// 胶囊主文案:一次性 = 相对日+时间(今晚 22:00);重复 = 重复规则+时间。
    private func headline(for reminder: Reminder) -> String {
        if reminder.isOneShot, let next = reminder.nextFireDate(after: now) {
            return Reminder.relativeDayLabel(for: next, now: now)
        }
        return "\(reminder.repeatDescription) \(reminder.timeString)"
    }

    // MARK: - Add button

    private var addButton: some View {
        Button {
            Haptics.light()
            onAdd()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text(NSLocalizedString("today.reminder.add", value: "提醒我", comment: "Add a capture reminder"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(DSColor.amberAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .strokeBorder(DSColor.amberRim, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reminder-capsule-add")
    }
}
