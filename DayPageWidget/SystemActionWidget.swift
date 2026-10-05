import SwiftUI
import WidgetKit

private let systemActionAppGroup = SystemActionSharedSummaryStore.appGroupIdentifier
private let systemActionSnapshotKey = "system-actions.redacted-summaries.v1"

private struct SystemActionWidgetSummary: Codable, Identifiable {
    let id: String
    let redactedTitle: String
    let kind: String
    let state: String
}

private struct SystemActionWidgetSnapshot: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let proposals: [SystemActionWidgetSummary]
}

private struct SystemActionWidgetEntry: TimelineEntry {
    let date: Date
    let proposals: [SystemActionWidgetSummary]
}

private struct SystemActionWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SystemActionWidgetEntry {
        .init(date: Date(), proposals: [
            .init(id: "sample", redactedTitle: "待处理的系统动作", kind: "calendar_event", state: "pending_review")
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemActionWidgetEntry) -> Void) {
        completion(.init(date: Date(), proposals: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemActionWidgetEntry>) -> Void) {
        completion(Timeline(
            entries: [.init(date: Date(), proposals: load())],
            policy: .after(Date().addingTimeInterval(15 * 60))
        ))
    }

    private func load() -> [SystemActionWidgetSummary] {
        guard let defaults = UserDefaults(suiteName: systemActionAppGroup),
              let data = defaults.data(forKey: systemActionSnapshotKey),
              data.count <= 64 * 1_024,
              let snapshot = try? JSONDecoder().decode(SystemActionWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == 1 else { return [] }
        return Array(snapshot.proposals
            .filter { $0.state == "pending_review" || $0.state == "needs_review" }
            .prefix(3))
    }
}

struct SystemActionWidget: Widget {
    let kind = SystemActionSharedSummaryStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SystemActionWidgetProvider()) { entry in
            SystemActionWidgetView(entry: entry)
                .modifier(SystemActionWidgetBackground())
        }
        .configurationDisplayName("DayPage 动作中心")
        .description("查看等待您审批的系统动作，不在锁屏显示私密内容。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct SystemActionWidgetBackground: ViewModifier {
    private var background: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.102, green: 0.094, blue: 0.078, alpha: 1)
                : UIColor(red: 0.980, green: 0.973, blue: 0.965, alpha: 1)
        })
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { background }
        } else {
            content.padding().background(background)
        }
    }
}

private struct SystemActionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SystemActionWidgetEntry

    private let amber = Color(red: 0.659, green: 0.329, blue: 0.106)

    var body: some View {
        Link(destination: URL(string: "daypage://actions")!) {
            if family == .accessoryRectangular {
                accessory
            } else {
                standard
            }
        }
        .accessibilityLabel(widgetAccessibilityLabel)
    }

    private var widgetAccessibilityLabel: String {
        guard !entry.proposals.isEmpty else {
            return NSLocalizedString("DayPage 动作中心，没有待审批动作", comment: "")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("system_action.widget.pending_accessibility", value: "DayPage 动作中心，%lld 条待审批动作", comment: ""),
            entry.proposals.count
        )
    }

    private var accessory: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
            VStack(alignment: .leading, spacing: 1) {
                Text("动作中心").font(.headline)
                Text(accessoryStatus)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("动作中心", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(amber)
                Spacer()
                if !entry.proposals.isEmpty {
                    Text("\(entry.proposals.count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(amber, in: Circle())
                }
            }
            if entry.proposals.isEmpty {
                Spacer()
                Label("都处理好了", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.proposals.prefix(family == .systemSmall ? 1 : 3)) { proposal in
                    HStack(spacing: 7) {
                        Image(systemName: symbol(proposal.kind))
                            .foregroundStyle(amber)
                        Text(proposal.redactedTitle.isEmpty
                            ? NSLocalizedString("待处理的系统动作", comment: "")
                            : proposal.redactedTitle)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 0)
                Text("轻点检查后再执行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "daypage://actions"))
    }

    private var accessoryStatus: String {
        guard !entry.proposals.isEmpty else {
            return NSLocalizedString("没有待审批动作", comment: "")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("system_action.widget.pending_count", value: "%lld 条等待检查", comment: ""),
            entry.proposals.count
        )
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "calendar_event": return "calendar"
        case "reminder": return "checklist"
        case "contact_draft": return "person.crop.circle.badge.plus"
        case "notification": return "bell"
        case "route": return "map"
        case "focus_session": return "timer"
        default: return "wand.and.stars"
        }
    }
}

@available(iOS 18.0, *)
struct SystemActionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.daypage.control.system-actions") {
            ControlWidgetButton(action: OpenSystemActionCenterIntent()) {
                Label("动作中心", systemImage: "checkmark.shield")
            }
        }
        .displayName("DayPage 动作中心")
        .description("查看并审批系统动作提案。")
    }
}

@available(iOS 18.0, *)
struct FocusSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.daypage.control.focus-session") {
            ControlWidgetButton(action: DraftFocusSessionIntent()) {
                Label("准备专注", systemImage: "timer")
            }
        }
        .displayName("DayPage 专注")
        .description("打开一个 25 分钟专注提案；确认后才启动计时。")
    }
}
