import SwiftUI
import DayPageModels
import DayPageServices

// MARK: - MemoChatView

/// Memo 锚定的 AI 对话 sheet（issue #837）。
///
/// 与 `AskPastView` 的边界：
/// - **AskPastView**：通用「问过去」——侧边栏 / Siri intent 入口，无锚点。
/// - **MemoChatView**：一条具体记录被「拽进对话框」——记录以「记忆芯片」
///   形式挂在输入框上，全程作为一等上下文注入，可摘除退化为通用对话。
///
/// Agent loop 可视化：`MemoryChatService.AgentPhase` 驱动一行状态文案
/// （重读 → 沿实体翻找 → 找到 N 条 → 逐字作答），流式回答实时渲染。
struct MemoChatView: View {

    let memo: Memo
    /// slug → 实体显示名（由 MemoDetailView 已解析的 wiki `name:`），
    /// 喂给 `.retrieving` 阶段文案与建议问题。
    let entityDisplayNames: [String: String]
    let onClose: () -> Void

    @StateObject private var chat = MemoryChatService()
    /// 这条 memo 的过往对话（长河的锚定支流）：只显示锚定到同一条
    /// memo 的封存会话——全量历史在 AskPastView 的主河里。
    @StateObject private var river = ChatRiverModel()
    @State private var draft: String = ""
    @State private var didAttach = false
    @State private var pinnedTurnIDs: Set<UUID> = []
    @State private var caretVisible = true
    @FocusState private var inputFocused: Bool

    private var memoDateString: String {
        DateFormatters.isoDate.string(from: memo.created)
    }

    private var clues: [String] {
        memo.entityMentions.compactMap { entityDisplayNames[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            ChatRiverSelectionBar(river: river)
            Divider().background(DSColor.borderSubtle)
            if chat.attachedMemo != nil {
                memoryChip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            inputBar
        }
        .background(DSColor.bgWarm.ignoresSafeArea())
        .animation(Motion.spring, value: chat.attachedMemo == nil)
        .task {
            guard !didAttach else { return }
            didAttach = true
            chat.attach(memo: memo, clues: clues)
            // --continue：同一天再次打开同一条 memo 的对话，接上原会话
            // 而不是碎片化成多段。
            chat.resumeTodaySession()
            river.filter = { [memoID = memo.id] summary in
                summary.entry == .memo && summary.anchorMemoID == memoID
            }
            river.refresh(excluding: chat.sessionRef?.id)
            inputFocused = true
        }
        .sheet(isPresented: Binding(
            get: { river.shareURLs != nil },
            set: { if !$0 { river.shareURLs = nil } }
        )) {
            if let urls = river.shareURLs {
                ShareSheet(activityItems: urls)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DSColor.accentOnBg)
            VStack(alignment: .leading, spacing: 2) {
                Text("ASK · \(memoDateString)")
                    .font(DSType.mono10)
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkMuted)
                Text(NSLocalizedString(
                    "memo.chat.title",
                    value: "Ask this memory",
                    comment: "Memo chat — sheet title"
                ))
                .font(DSType.serifBody20)
                .foregroundColor(DSColor.inkPrimary)
            }
            Spacer()
            Button {
                Haptics.soft()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 30, height: 30)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Circle())
            }
            .accessibilityLabel(NSLocalizedString(
                "memo.chat.a11y.close",
                value: "关闭对话",
                comment: "Memo chat — close button VoiceOver label"
            ))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // 这条 memo 的过往对话——沉在当前对话上游。
                    ChatRiverSection(river: river) { loaded in
                        withAnimation(Motion.spring) {
                            chat.resume(loaded)
                            river.exitSelection()
                            river.refresh(excluding: loaded.summary.id)
                        }
                    }
                    if chat.turns.isEmpty && !chat.isResponding {
                        suggestions
                    }
                    ForEach(chat.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    if chat.isResponding {
                        agentStatusRow.id("agent-status")
                    }
                    if let err = chat.errorMessage {
                        errorRow(err)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .onChange(of: chat.turns.count) { _ in
                withAnimation { proxy.scrollTo(chat.turns.last?.id, anchor: .bottom) }
            }
            .onChange(of: chat.streamingText) { _ in
                proxy.scrollTo("agent-status", anchor: .bottom)
            }
            .onChange(of: chat.isResponding) { responding in
                if responding {
                    withAnimation { proxy.scrollTo("agent-status", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Agent loop status / streaming

    /// Agent 检索循环的可视区：非流式阶段渲染一行状态，流式阶段渲染
    /// 增量回答 + 琥珀光标。
    @ViewBuilder
    private var agentStatusRow: some View {
        switch chat.phase {
        case .streaming:
            streamingBubble
        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusText(for: chat.phase))
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkSecondary)
                    .animation(.easeInOut(duration: 0.2), value: chat.phase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    private func statusText(for phase: MemoryChatService.AgentPhase) -> String {
        switch phase {
        case .reading:
            return NSLocalizedString(
                "memo.chat.status.reading",
                value: "Rereading this memory…",
                comment: "Memo chat — agent phase: rereading the anchored memo"
            )
        case .retrieving(let names) where !names.isEmpty:
            return String(
                format: NSLocalizedString(
                    "memo.chat.status.retrieving.along",
                    value: "Tracing “%@” through your records…",
                    comment: "Memo chat — agent phase: tracing entities; %@ is entity names"
                ),
                names.prefix(2).joined(separator: NSLocalizedString(
                    "memo.chat.status.retrieving.sep",
                    value: "”, “",
                    comment: "Memo chat — separator between entity names inside the retrieving status quotes"
                ))
            )
        case .retrieving:
            return NSLocalizedString(
                "memo.chat.status.retrieving",
                value: "Searching related records…",
                comment: "Memo chat — agent phase: keyword retrieval"
            )
        case .thinking(let found) where found > 0:
            return String(
                format: NSLocalizedString(
                    "memo.chat.status.found",
                    value: "Found %d related records, thinking…",
                    comment: "Memo chat — agent phase: retrieval done; %d is record count"
                ),
                found
            )
        default:
            return NSLocalizedString(
                "memo.chat.status.thinking",
                value: "Thinking…",
                comment: "Memo chat — agent phase: waiting for the model"
            )
        }
    }

    /// 流式回答气泡：serif 正文 + 尾随琥珀光标（呼吸闪烁）。
    private var streamingBubble: some View {
        (Text(chat.streamingText)
            .font(DSType.serifBody16)
            .foregroundColor(DSColor.inkPrimary)
        + Text("▍")
            .font(DSType.serifBody16)
            .foregroundColor(DSColor.amberAccent.opacity(caretVisible ? 0.8 : 0.15)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    caretVisible.toggle()
                }
            }
    }

    // MARK: - Turn rows

    @ViewBuilder
    private func turnRow(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                Text(turn.text)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let context = turn.context, !context.memoHits.isEmpty {
                    sourceRow(context)
                }
                assistantActions(for: turn)
            }
        }
    }

    /// 来源「依据」区：命中的日期渲染为可点 chip → 跳到那一天。
    /// SOURCES 是 chrome，保持英文 mono（FINDING-010 惯例）。
    private func sourceRow(_ context: RetrievedContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCES")
                .font(DSType.mono10)
                .tracking(1.2)
                .foregroundColor(DSColor.inkMuted)
            let dates = Array(Array(Set(context.memoHits.map { $0.dateString })).sorted(by: >).prefix(4))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(stride(from: 0, to: dates.count, by: 2)), id: \.self) { i in
                    HStack(spacing: 6) {
                        ForEach(dates[i..<min(i + 2, dates.count)], id: \.self) { date in
                            sourceChip(date)
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func sourceChip(_ dateString: String) -> some View {
        Button {
            openArchive(at: dateString)
        } label: {
            HStack(spacing: 4) {
                Text(dateString)
                    .font(DSType.mono10)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DSColor.amberSoft)
            .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(
            format: NSLocalizedString(
                "memo.chat.a11y.source",
                value: "查看 %@ 的记录",
                comment: "Memo chat — source chip VoiceOver label; %@ is a date"
            ),
            dateString
        ))
    }

    @ViewBuilder
    private func assistantActions(for turn: ChatTurn) -> some View {
        let pinned = pinnedTurnIDs.contains(turn.id)
        Button {
            Haptics.tapConfirm()
            if chat.pinTurnToDiary(turn) {
                pinnedTurnIDs.insert(turn.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pinned ? "checkmark.circle.fill" : "text.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                Text(pinned
                     ? NSLocalizedString("memo.chat.pin.done", value: "Saved to today", comment: "Memo chat — pin action done state")
                     : NSLocalizedString("memo.chat.pin", value: "Save to today", comment: "Memo chat — pin answer into today's diary"))
                    .font(DSType.labelSM)
            }
            .foregroundColor(pinned ? DSColor.successGreen : DSColor.accentOnBg)
        }
        .buttonStyle(.plain)
        .disabled(pinned)
        .padding(.top, 2)
    }

    // MARK: - Suggestions (empty state)

    /// 实体感知的建议问题：围绕这条记录能问出「时间跨度」价值的问法。
    private var suggestedQuestions: [String] {
        var out: [String] = [
            NSLocalizedString(
                "memo.chat.suggest.why",
                value: "Why did I think this at the time?",
                comment: "Memo chat — suggested question 1"
            )
        ]
        if let firstClue = clues.first {
            out.append(String(
                format: NSLocalizedString(
                    "memo.chat.suggest.entity",
                    value: "What else have I said about “%@”?",
                    comment: "Memo chat — suggested question 2; %@ is an entity name"
                ),
                firstClue
            ))
        }
        out.append(NSLocalizedString(
            "memo.chat.suggest.changed",
            value: "Has this thought changed since?",
            comment: "Memo chat — suggested question 3"
        ))
        return out
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestedQuestions, id: \.self) { q in
                Button {
                    Haptics.soft()
                    Task { await chat.ask(q) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11))
                            .foregroundColor(DSColor.accentOnBg)
                        Text(q)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Error

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
            Button {
                Haptics.soft()
                Task { await chat.retryLast() }
            } label: {
                Text(NSLocalizedString(
                    "memo.chat.retry",
                    value: "Retry",
                    comment: "Memo chat — retry failed answer"
                ))
                .font(DSType.labelSM)
                .foregroundColor(DSColor.accentOnBg)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DSColor.surfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    // MARK: - Memory chip

    /// 「记忆芯片」——被拽进对话框的那条记录。左侧琥珀细杆呼应详情页
    /// 眉批的设计语言；× 摘除后对话退化为通用问过去。
    private var memoryChip: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(DSColor.amberRim)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(memoDateString.uppercased())
                    .font(DSType.mono9)
                    .tracking(1.0)
                    .foregroundColor(DSColor.inkMuted)
                Text(memo.body.replacingOccurrences(of: "\n", with: " "))
                    .font(DSFonts.serif(size: 13, weight: .regular, relativeTo: .footnote))
                    .foregroundColor(DSColor.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                Haptics.soft()
                withAnimation(Motion.spring) { chat.detachMemo() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 22, height: 22)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Circle())
            }
            .accessibilityLabel(NSLocalizedString(
                "memo.chat.a11y.detach",
                value: "摘除这条记忆",
                comment: "Memo chat — detach memory chip VoiceOver label"
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(DSColor.amberSoft)
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md)
                .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(
                NSLocalizedString(
                    "memo.chat.input.placeholder",
                    value: "Ask about this memory…",
                    comment: "Memo chat — input placeholder"
                ),
                text: $draft,
                axis: .vertical
            )
            .font(DSType.bodySM)
            .focused($inputFocused)
            .lineLimit(1...4)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(DSColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(canSend ? DSColor.accentOnBg : DSColor.inkSubtle)
            }
            .disabled(!canSend)
            .accessibilityLabel(NSLocalizedString(
                "memo.chat.a11y.send",
                value: "发送",
                comment: "Memo chat — send button VoiceOver label"
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isResponding
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.isResponding else { return }
        draft = ""
        Task { await chat.ask(question) }
    }

    // MARK: - Navigation out

    /// 来源 chip → 跳到那一天。与 MemoDetailView.openEcho 同款
    /// dismiss-then-post 模式：先收 sheet（与详情页一起让位），再发通知。
    private func openArchive(at dateString: String) {
        Haptics.soft()
        onClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(
                name: .openArchiveAt,
                object: nil,
                userInfo: ["date": dateString]
            )
        }
    }
}
