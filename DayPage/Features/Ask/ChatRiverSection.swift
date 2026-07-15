import SwiftUI
import DayPageServices

// MARK: - ChatRiverModel

/// 「对话长河」的状态载体：封存会话的胶囊层（懒加载窗口）、原位展开
/// 回放、多选导出、删除。历史不进侧边栏、不开独立 sheet——它就是对话
/// 视图上游的沉积层（设计 v2 D4）。
@MainActor
final class ChatRiverModel: ObservableObject {

    /// 胶囊列表（不含当前活跃会话），开始时间降序，展示前按天分组。
    @Published private(set) var summaries: [ChatSessionSummary] = []
    /// 原位展开的会话（只读回放）。同一时刻至多一段。
    @Published private(set) var expanded: LoadedChatSession?
    /// 多选导出模式。
    @Published var selectionMode = false
    @Published var selectedIDs: Set<UUID> = []
    /// 还有更早的日目录未进窗口（驱动「更早的对话」按钮）。
    @Published private(set) var hasMore = false
    /// 待确认删除的会话（confirmationDialog 绑定）。
    @Published var pendingDelete: ChatSessionSummary?
    /// 生成好的导出文件，非 nil 时弹 ShareSheet。
    @Published var shareURLs: [URL]?

    /// 附加过滤（如 MemoChatView 只看锚定到同一条 memo 的会话）。
    var filter: ((ChatSessionSummary) -> Bool)?

    /// 懒加载窗口：首屏近 7 个自然日，「更早」每次扩一个月。
    private var windowDays = 7
    private var excludedSessionID: UUID?

    var enabled: Bool { FeatureFlagStore.shared.isEnabled(.chatHistory) }

    // MARK: Loading

    /// 重扫窗口内的会话。`excluding` 是当前活跃会话——它在河口，不是沉积物。
    func refresh(excluding currentID: UUID?) {
        excludedSessionID = currentID
        guard enabled else {
            summaries = []
            hasMore = false
            return
        }
        var list = ChatSessionStore.listSessions(limitDays: windowDays)
            .filter { $0.id != currentID }
        if let filter { list = list.filter(filter) }
        summaries = list
        hasMore = ChatSessionStore.dayDirectoryCount() > windowDays
        if let expandedID = expanded?.summary.id, !list.contains(where: { $0.id == expandedID }) {
            expanded = nil
        }
    }

    func loadEarlier() {
        windowDays += 31
        refresh(excluding: excludedSessionID)
    }

    // MARK: Expand / collapse

    func toggleExpanded(_ summary: ChatSessionSummary) {
        if expanded?.summary.id == summary.id {
            expanded = nil
        } else {
            expanded = ChatSessionStore.load(summary: summary)
        }
    }

    // MARK: Selection

    func toggleSelected(_ summary: ChatSessionSummary) {
        if selectedIDs.contains(summary.id) {
            selectedIDs.remove(summary.id)
        } else {
            selectedIDs.insert(summary.id)
        }
    }

    func enterSelection(with summary: ChatSessionSummary? = nil) {
        selectionMode = true
        expanded = nil
        selectedIDs = summary.map { [$0.id] } ?? []
    }

    func exitSelection() {
        selectionMode = false
        selectedIDs = []
    }

    // MARK: Delete

    func confirmDelete() {
        guard let summary = pendingDelete else { return }
        pendingDelete = nil
        ChatSessionStore.delete(summary)
        refresh(excluding: excludedSessionID)
    }

    // MARK: Export

    /// 渲染并落地导出文件 → 弹 ShareSheet。多选即多文件（散 md，
    /// Obsidian / Files 里比 zip 好用）；同名撞车追加序号。
    func export(_ targets: [ChatSessionSummary]) {
        let dir = MarkdownExportService.exportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MarkdownExportService.purgeStaleExports()

        var urls: [URL] = []
        for summary in targets.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let loaded = ChatSessionStore.load(summary: summary) else { continue }
            let content = ChatMarkdownRenderer.render(loaded)
            let baseName = ChatMarkdownRenderer.exportFileName(for: summary)
            var url = dir.appendingPathComponent(baseName)
            var attempt = 2
            while urls.contains(url) || FileManager.default.fileExists(atPath: url.path) {
                let stem = (baseName as NSString).deletingPathExtension
                url = dir.appendingPathComponent("\(stem)-\(attempt).md")
                attempt += 1
            }
            guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        shareURLs = urls
    }

    func exportSelected() {
        export(summaries.filter { selectedIDs.contains($0.id) })
        exitSelection()
    }

    // MARK: Grouping

    /// 按天分组，天升序、天内升序——河从上游（更早）流向河口（当前对话）。
    var dayGroups: [(day: String, sessions: [ChatSessionSummary])] {
        let grouped = Dictionary(grouping: summaries, by: { $0.dayString })
        return grouped.keys.sorted().map { day in
            (day, grouped[day]!.sorted { $0.startedAt < $1.startedAt })
        }
    }
}

// MARK: - ChatRiverSection

/// 对话长河的胶囊层。挂在会话 ScrollView 内容的最顶部：
/// 「更早的对话」 → 按天分组的封存胶囊 → （下方）当前对话。
struct ChatRiverSection: View {

    @ObservedObject var river: ChatRiverModel
    /// 续聊回调：把整段回放交还给宿主（宿主负责 `chat.resume` 并刷新河）。
    let onResume: (LoadedChatSession) -> Void

    var body: some View {
        if !river.summaries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if river.hasMore {
                    earlierButton
                }
                ForEach(river.dayGroups, id: \.day) { group in
                    dayMarker(group.day)
                    ForEach(group.sessions) { summary in
                        capsuleRow(summary)
                        if river.expanded?.summary.id == summary.id, let loaded = river.expanded {
                            expandedReplay(loaded)
                        }
                    }
                }
            }
            .confirmationDialog(
                NSLocalizedString("chat.river.delete.confirm.title", value: "删除这段对话？", comment: "Chat river — delete confirm title"),
                isPresented: Binding(
                    get: { river.pendingDelete != nil },
                    set: { if !$0 { river.pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("chat.river.delete", value: "删除", comment: "Chat river — delete action"), role: .destructive) {
                    Haptics.warn()
                    withAnimation(Motion.spring) { river.confirmDelete() }
                }
                Button(NSLocalizedString("settings.common.cancel", value: "取消", comment: ""), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("chat.river.delete.confirm.message", value: "对话文件将从 vault 中移除，不可恢复。", comment: "Chat river — delete confirm message"))
            }
        }
    }

    // MARK: Earlier

    private var earlierButton: some View {
        Button {
            Haptics.soft()
            withAnimation(Motion.spring) { river.loadEarlier() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 12))
                Text(NSLocalizedString("chat.river.earlier", value: "更早的对话", comment: "Chat river — load earlier sessions"))
                    .font(DSType.labelSM)
            }
            .foregroundColor(DSColor.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("chat.river.earlier", value: "更早的对话", comment: ""))
    }

    // MARK: Day marker

    private func dayMarker(_ day: String) -> some View {
        Text("—— \(relativeDayLabel(day)) ——")
            .font(DSType.mono10)
            .tracking(1.5)
            .foregroundColor(DSColor.inkSubtle)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func relativeDayLabel(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        guard let date = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) {
            return NSLocalizedString("chat.river.today", value: "今天", comment: "Chat river — today group")
        }
        if Calendar.current.isDateInYesterday(date) {
            return NSLocalizedString("chat.river.yesterday", value: "昨天", comment: "Chat river — yesterday group")
        }
        return day
    }

    // MARK: Capsule

    @ViewBuilder
    private func capsuleRow(_ summary: ChatSessionSummary) -> some View {
        let isSelected = river.selectedIDs.contains(summary.id)
        let isExpanded = river.expanded?.summary.id == summary.id

        Button {
            if river.selectionMode {
                Haptics.selection()
                river.toggleSelected(summary)
            } else {
                Haptics.soft()
                withAnimation(Motion.spring) { river.toggleExpanded(summary) }
            }
        } label: {
            HStack(spacing: 8) {
                if river.selectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? DSColor.accentOnBg : DSColor.inkSubtle)
                }
                entryBadge(summary)
                Text(summary.title)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: NSLocalizedString("chat.river.turns", value: "%d 轮", comment: "Chat river — turn count"), summary.turnCount))
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkMuted)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.inkSubtle)
                    .opacity(river.selectionMode ? 0 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(DSColor.surfaceContainerHigh.opacity(isSelected ? 0.9 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? DSColor.accentOnBg : DSColor.borderSubtle,
                        style: StrokeStyle(lineWidth: 1, dash: isSelected ? [] : [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !river.selectionMode {
                Button {
                    if let loaded = ChatSessionStore.load(summary: summary) {
                        Haptics.tapConfirm()
                        onResume(loaded)
                    }
                } label: {
                    Label(NSLocalizedString("chat.river.continue", value: "继续这段对话", comment: "Chat river — resume session"), systemImage: "arrow.uturn.down")
                }
                Button {
                    river.export([summary])
                } label: {
                    Label(NSLocalizedString("chat.river.export", value: "导出 (.md)", comment: "Chat river — export one session"), systemImage: "square.and.arrow.up")
                }
                Button {
                    river.enterSelection(with: summary)
                } label: {
                    Label(NSLocalizedString("chat.river.select", value: "选择多段…", comment: "Chat river — enter multi-select"), systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    river.pendingDelete = summary
                } label: {
                    Label(NSLocalizedString("chat.river.delete", value: "删除", comment: ""), systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(ChatMarkdownRenderer.entryLabel(summary.entry))：\(summary.title)")
    }

    private func entryBadge(_ summary: ChatSessionSummary) -> some View {
        let text: String
        switch summary.entry {
        case .ask:
            text = NSLocalizedString("chat.river.badge.ask", value: "问", comment: "Chat river — ask badge")
        case .memo:
            let suffix = summary.anchorMemoDate.map { String($0.suffix(5)) }
            let anchor = NSLocalizedString("chat.river.badge.memo", value: "锚", comment: "Chat river — memo badge")
            text = suffix.map { "\(anchor) \($0)" } ?? anchor
        case .coach:
            text = NSLocalizedString("chat.river.badge.coach", value: "陪写", comment: "Chat river — coach badge")
        }
        return Text(text)
            .font(DSType.mono10)
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DSColor.accentOnBg.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: Expanded replay

    /// 原位展开的只读回放：降一档墨色的紧凑气泡 + 「继续这段对话」。
    private func expandedReplay(_ loaded: LoadedChatSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(loaded.turns) { turn in
                switch turn.role {
                case .user:
                    HStack {
                        Spacer(minLength: 40)
                        Text(turn.text)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(DSColor.surfaceContainerHigh.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                    }
                case .assistant:
                    Text(turn.text)
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button {
                Haptics.tapConfirm()
                onResume(loaded)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(NSLocalizedString("chat.river.continue", value: "继续这段对话", comment: ""))
                        .font(DSType.labelSM)
                }
                .foregroundColor(DSColor.accentOnBg)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .fill(DSColor.surfaceContainerHigh.opacity(0.3))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - ChatRiverSelectionBar

/// 多选模式的底部浮条：已选计数 + 导出。宿主 overlay 在输入栏上方。
struct ChatRiverSelectionBar: View {
    @ObservedObject var river: ChatRiverModel

    var body: some View {
        if river.selectionMode {
            HStack(spacing: 12) {
                Text(String(format: NSLocalizedString("chat.river.selected", value: "已选 %d 段", comment: "Chat river — selection count"), river.selectedIDs.count))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkSecondary)
                Spacer()
                Button {
                    Haptics.soft()
                    withAnimation(Motion.spring) { river.exitSelection() }
                } label: {
                    Text(NSLocalizedString("chat.river.selection.done", value: "完成", comment: "Chat river — exit selection"))
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.inkSecondary)
                }
                .buttonStyle(.plain)
                Button {
                    Haptics.tapConfirm()
                    river.exportSelected()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                        Text(String(format: NSLocalizedString("chat.river.export_n", value: "导出 %d 段", comment: "Chat river — export N sessions"), river.selectedIDs.count))
                            .font(DSType.labelSM)
                    }
                    .foregroundColor(river.selectedIDs.isEmpty ? DSColor.inkSubtle : DSColor.accentOnBg)
                }
                .buttonStyle(.plain)
                .disabled(river.selectedIDs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DSColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
