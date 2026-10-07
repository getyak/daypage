import SwiftUI
import DayPageModels
import DayPageServices

// MARK: - MemoChatEntryMode

/// How the memo-anchored chat sheet was opened (flomo-native refinement).
///
/// - `.insight`: the swipe's 「洞察」 action — the sheet opens with the
///   insight-lens (「洞察视角」) chooser expanded. Nothing is sent until the
///   user taps 「开始洞察」.
/// - `.related`: the swipe's 「相关记录」 action — the sheet opens with a
///   suggested question prefilled into the input. It is NEVER auto-submitted:
///   no fabricated results, no silent cloud calls.
enum MemoChatEntryMode: Equatable {
    case insight
    case related(question: String)
}

// MARK: - MemoChatSheetRequest

/// Identifiable anchor for `.sheet(item:)` presentation of ``MemoChatView``
/// from a memo row (TimelineRow), so the chat is always anchored to the exact
/// memo that was swiped.
struct MemoChatSheetRequest: Identifiable {
    let id = UUID()
    let memo: Memo
    let mode: MemoChatEntryMode
    var entityDisplayNames: [String: String] = [:]
}

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
    /// Optional entry mode (flomo-native refinement). nil keeps the plain
    /// free-chat entry used by MemoDetailView.
    var initialMode: MemoChatEntryMode? = nil

    @StateObject private var chat = MemoryChatService()
    /// 洞察视角的本地偏好存储（注入式 UserDefaults；只存 title +
    /// instructions + 选择 ID，永不存 memo 正文/证据/凭据）。
    @StateObject private var insightStore = InsightStrategyStore()
    /// 这条 memo 的过往对话（长河的锚定支流）：只显示锚定到同一条
    /// memo 的封存会话——全量历史在 AskPastView 的主河里。
    @StateObject private var river = ChatRiverModel()
    @State private var draft: String = ""
    @State private var retrievalTopic: String = ""
    @State private var didAttach = false
    @State private var pinnedTurnIDs: Set<UUID> = []
    @State private var caretVisible = true
    /// 洞察视角选择器的展开状态（默认紧凑收起）。
    @State private var insightExpanded = false
    /// 自定义策略编辑器（新建 / 编辑），`nil` = 关闭。
    @State private var insightEditor: InsightStrategyEditorTarget?
    /// 当前 in-flight 聊天任务句柄：sheet 关闭 / 消失时 cancel，确保被丢弃
    /// 的对话绝不会迟到触发云端调用或落盘隐藏结果。
    @State private var chatTask: Task<Void, Never>? = nil
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            if initialMode != nil, chat.attachedMemo != nil {
                retrievalTopicEditor
            }
            inputBar
        }
        .background(DSColor.bgWarm.ignoresSafeArea())
        .animation(reduceMotion ? nil : Motion.spring, value: chat.attachedMemo == nil)
        .task {
            guard !didAttach else { return }
            didAttach = true
            chat.attach(memo: memo, clues: clues)
            if initialMode == .insight { insightExpanded = true }
            if initialMode != nil {
                let topic = await chat.suggestedRetrievalQuery()
                guard !Task.isCancelled else { return }
                if retrievalTopic.isEmpty { retrievalTopic = topic }
            }
            // --continue：同一天再次打开同一条 memo 的对话，接上原会话
            // 而不是碎片化成多段。
            //
            // 例外（review P1）：.insight 入口不 resume——已有的历史回合会
            // 隐藏空对话里的「洞察视角」选择器。原会话仍沉在下面的长河里；
            // 普通自由提问保持原有 resume 行为。
            if initialMode != .insight {
                chat.resumeTodaySession()
            }
            river.filter = { [memoID = memo.id] summary in
                summary.entry == .memo && summary.anchorMemoID == memoID
            }
            river.refresh(excluding: chat.sessionRef?.id)
            // 入口模式（均不会自动发起任何 AI 调用）：
            // - .insight → 展开「洞察视角」选择器，等用户点「开始洞察」；
            //   **不**自动弹键盘，否则选择器被键盘遮住。
            // - .related → 预填建议问题到输入框，绝不自动提交。
            switch initialMode {
            case .insight:
                withAnimation(Motion.respectReduceMotion(Motion.expand)) {
                    insightExpanded = true
                }
            case .related(let question):
                draft = question
                inputFocused = true
            case nil:
                inputFocused = true
            }
        }
        .onDisappear {
            // Sheet dismissal cancels any in-flight ask/retry/insight run.
            chatTask?.cancel()
            chatTask = nil
        }
        .sheet(item: $insightEditor) { target in
            InsightStrategyEditor(
                store: insightStore,
                target: target,
                onClose: { insightEditor = nil }
            )
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

    private var entryTitle: String {
        switch initialMode {
        case .insight:
            return NSLocalizedString("memo.chat.insight.title", value: "Insight into this memory", comment: "Insight entry title")
        case .related:
            return NSLocalizedString("memo.chat.related.title", value: "Related memories", comment: "Related entry title")
        case nil:
            return NSLocalizedString("memo.chat.title", value: "Ask this memory", comment: "Memo chat title")
        }
    }

    /// A suggested local keyword is visible and editable; it never changes the lens.
    private var retrievalTopicEditor: some View {
        HStack(spacing: 10) {
            Text(NSLocalizedString("memo.chat.topic.label", value: "Keyword", comment: "Editable retrieval keyword"))
                .font(DSType.labelSM)
                .foregroundColor(DSColor.inkMuted)
            TextField(NSLocalizedString("memo.chat.topic.placeholder", value: "e.g. attention", comment: "Keyword placeholder"), text: $retrievalTopic)
                .font(DSType.bodySM)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .disabled(chat.isResponding)
                .accessibilityLabel(NSLocalizedString("memo.chat.topic.label", value: "Keyword", comment: "Editable retrieval keyword"))
                .accessibilityHint(NSLocalizedString("memo.chat.topic.hint", value: "Exact keyword matching, up to 40 characters", comment: "Keyword field hint"))
                .accessibilityIdentifier("memo-chat-retrieval-topic")
                .onChange(of: retrievalTopic) { value in
                    if value.count > 40 { retrievalTopic = String(value.prefix(40)) }
                }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
    }

    private func askFromEntry(_ question: String) async {
        if initialMode != nil, chat.attachedMemo != nil {
            let topic = retrievalTopic.trimmingCharacters(in: .whitespacesAndNewlines)
            let query: String
            if topic.isEmpty { query = await chat.suggestedRetrievalQuery() }
            else { query = topic }
            guard !Task.isCancelled else { return }
            await chat.ask(question, retrievalQuery: query)
        } else {
            await chat.ask(question)
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
                Text(entryTitle)
                .font(DSType.serifBody20)
                .foregroundColor(DSColor.inkPrimary)
            }
            Spacer()
            Button {
                Haptics.soft()
                chatTask?.cancel()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 30, height: 30)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
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
                        withAnimation(Motion.respectReduceMotion(Motion.spring)) {
                            chatTask?.cancel()
                            chatTask = nil
                            chat.resume(loaded)
                            river.exitSelection()
                            river.refresh(excluding: loaded.summary.id)
                        }
                    }
                    if chat.turns.isEmpty && !chat.isResponding {
                        if chat.attachedMemo != nil { insightChooser }
                        if initialMode != .insight || chat.attachedMemo == nil { suggestions }
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
                if reduceMotion {
                    caretVisible = true
                } else {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        caretVisible.toggle()
                    }
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
                    runChat { await askFromEntry(q) }
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

    // MARK: - Insight lens (洞察视角)

    /// 紧凑可展开的「洞察视角」选择器——只在空对话时出现。
    ///
    /// 契约（flomo-native refinement）：
    /// - 默认收起，只露当前视角一行。
    /// - 3 个内置视角（重复模式 / 挑战假设 / 下一小步）+ 自定义视角的
    ///   新建 / 编辑 / 删除。
    /// - 选择 / 编辑 / 删除视角都只是本地偏好操作，**不发起任何 AI 调用**；
    ///   唯一的出口是显式的「开始洞察」按钮。
    private var insightChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.soft()
                withAnimation(Motion.respectReduceMotion(Motion.expand)) {
                    insightExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DSColor.accentOnBg)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString(
                            "insight.chooser.title",
                            value: "洞察视角",
                            comment: "Insight lens chooser — section title"
                        ))
                        .font(DSType.mono10)
                        .tracking(1.0)
                        .foregroundColor(DSColor.inkMuted)
                        Text(insightStore.selectedStrategy.title)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                        .rotationEffect(.degrees(insightExpanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(DSColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString(
                "insight.chooser.title",
                value: "洞察视角",
                comment: "Insight lens chooser — section title"
            ))
            .accessibilityValue(insightStore.selectedStrategy.title)
            .accessibilityHint(insightExpanded
                ? NSLocalizedString("a11y.expanded", comment: "Disclosure expanded state")
                : NSLocalizedString("a11y.collapsed", comment: "Disclosure collapsed state"))

            if insightExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(insightStore.allStrategies) { strategy in
                        insightRow(strategy)
                    }

                    Button {
                        Haptics.soft()
                        insightEditor = InsightStrategyEditorTarget(
                            id: nil, title: "", instructions: "")
                    } label: {
                        Label(
                            NSLocalizedString(
                                "insight.strategy.new",
                                value: "新建视角",
                                comment: "Create a custom insight strategy"
                            ),
                            systemImage: "plus"
                        )
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.accentOnBg)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.tapConfirm()
                        let strategy = insightStore.selectedStrategy
                        runChat { await chat.ask(insight: strategy, retrievalTopic: retrievalTopic) }
                    } label: {
                        Text(NSLocalizedString(
                            "insight.start",
                            value: "开始洞察",
                            comment: "Explicit action: run the selected insight lens on the anchored memo"
                        ))
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.onAmber)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(DSColor.amberDeep, in: RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.isResponding)
                    .accessibilityHint(NSLocalizedString(
                        "insight.start.hint",
                        value: "用所选视角分析这条记录；不会自动发送",
                        comment: "Insight start button hint"
                    ))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

    /// One strategy row: tap selects (local only), trailing controls edit /
    /// delete custom strategies. Builtin rows carry no edit affordance.
    private func insightRow(_ strategy: InsightStrategy) -> some View {
        let isSelected = insightStore.selectedID == strategy.id
        return HStack(spacing: 8) {
            Button {
                Haptics.soft()
                insightStore.select(strategy.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? DSColor.accentOnBg : DSColor.inkSubtle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strategy.title)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkPrimary)
                            .lineLimit(1)
                        Text(strategy.instructions)
                            .font(DSType.caption)
                            .foregroundColor(DSColor.inkMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(strategy.title)
            .accessibilityValue(isSelected
                ? NSLocalizedString("common.selected", comment: "Selection state")
                : NSLocalizedString("common.not_selected", comment: "Selection state"))
            .accessibilityHint(NSLocalizedString(
                "insight.strategy.select.hint",
                value: "选择这个洞察视角（仅本地，不会发送）",
                comment: "Insight strategy row select hint"
            ))

            if strategy.kind == .custom {
                Button {
                    Haptics.soft()
                    insightEditor = InsightStrategyEditorTarget(
                        id: strategy.id,
                        title: strategy.title,
                        instructions: strategy.instructions
                    )
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(NSLocalizedString(
                    "insight.strategy.edit",
                    value: "编辑视角",
                    comment: "Edit a custom insight strategy"
                ))

                Button {
                    Haptics.warn()
                    insightStore.deleteCustom(id: strategy.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DSColor.errorRed)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(NSLocalizedString(
                    "insight.strategy.delete",
                    value: "删除视角",
                    comment: "Delete a custom insight strategy"
                ))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                .fill(isSelected ? DSColor.amberSoft : Color.clear)
        )
    }

    // MARK: - Error

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
            Button {
                Haptics.soft()
                runChat { await chat.retryLast() }
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
                Text(MemoMarkdown.plainText(for: memo).replacingOccurrences(of: "\n", with: " "))
                    .font(DSFonts.serif(size: 13, weight: .regular, relativeTo: .footnote))
                    .foregroundColor(DSColor.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                Haptics.soft()
                withAnimation(Motion.respectReduceMotion(Motion.spring)) { chat.detachMemo() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 22, height: 22)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
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
        runChat { await askFromEntry(question) }
    }

    // MARK: - In-flight chat task

    /// Runs one chat operation (ask / retry / insight) under a retained Task
    /// handle. Closing the sheet or `.onDisappear` cancels it, so a dismissed
    /// conversation never fires a late cloud call or persists hidden output
    /// (MemoryChatService additionally gates on cancellation + run generation).
    private func runChat(_ operation: @escaping @MainActor () async -> Void) {
        chatTask?.cancel()
        chatTask = Task { await operation() }
    }

    // MARK: - Navigation out

    /// 来源 chip → 跳到那一天。与 MemoDetailView.openEcho 同款
    /// dismiss-then-post 模式：先收 sheet（与详情页一起让位），再发通知。
    private func openArchive(at dateString: String) {
        Haptics.soft()
        chatTask?.cancel()
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

// MARK: - InsightStrategyEditorTarget

/// Editing target for ``InsightStrategyEditor``. `id == nil` creates a new
/// custom strategy; non-nil edits the custom strategy with that ID.
private struct InsightStrategyEditorTarget: Identifiable {
    let id: String?
    let title: String
    let instructions: String

    var isEditing: Bool { id != nil }
}

// MARK: - InsightStrategyEditor

/// Create / edit / delete sheet for one custom insight strategy.
///
/// Validation is the shared `InsightStrategyDraft.validated` rule (trim,
/// non-empty, length caps) so the UI can never persist a lens the service
/// layer would reject. Only title + instructions are stored — the editor
/// deliberately has nowhere to put memo text, evidence, or credentials.
private struct InsightStrategyEditor: View {

    @ObservedObject var store: InsightStrategyStore
    let target: InsightStrategyEditorTarget
    let onClose: () -> Void

    @State private var title: String
    @State private var instructions: String
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(
        store: InsightStrategyStore,
        target: InsightStrategyEditorTarget,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.target = target
        self.onClose = onClose
        _title = State(initialValue: target.title)
        _instructions = State(initialValue: target.instructions)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        NSLocalizedString(
                            "insight.editor.field.title",
                            value: "视角名称",
                            comment: "Insight strategy editor — title field label"
                        ),
                        text: $title
                    )
                    .focused($titleFocused)
                    .accessibilityLabel(NSLocalizedString(
                        "insight.editor.field.title",
                        value: "视角名称",
                        comment: "Insight strategy editor — title field label"
                    ))
                }
                Section {
                    TextField(
                        NSLocalizedString(
                            "insight.editor.field.instructions",
                            value: "想让我怎么看待这条记录？",
                            comment: "Insight strategy editor — instructions field placeholder"
                        ),
                        text: $instructions,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .accessibilityLabel(NSLocalizedString(
                        "insight.editor.field.instructions",
                        value: "想让我怎么看待这条记录？",
                        comment: "Insight strategy editor — instructions field label"
                    ))
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(DSType.caption)
                            .foregroundColor(DSColor.errorRed)
                    }
                }
                if target.isEditing {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warn()
                            if let id = target.id { store.deleteCustom(id: id) }
                            onClose()
                        } label: {
                            Text(NSLocalizedString(
                                "insight.editor.delete",
                                value: "删除视角",
                                comment: "Insight strategy editor — delete button"
                            ))
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString(
                target.isEditing ? "insight.editor.title.edit" : "insight.editor.title.new",
                value: target.isEditing ? "编辑视角" : "新建视角",
                comment: "Insight strategy editor — sheet title"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString(
                        "insight.editor.cancel",
                        value: "取消",
                        comment: "Insight strategy editor — cancel button"
                    )) {
                        onClose()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString(
                        "insight.editor.save",
                        value: "保存",
                        comment: "Insight strategy editor — save button"
                    )) {
                        save()
                    }
                    .bold()
                }
            }
        }
        .onAppear { titleFocused = true }
    }

    private func save() {
        do {
            _ = try store.saveCustom(id: target.id, title: title, instructions: instructions)
            Haptics.tapConfirm()
            onClose()
        } catch let error as InsightStrategyValidationError {
            errorMessage = message(for: error)
            Haptics.warn()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.warn()
        }
    }

    private func message(for error: InsightStrategyValidationError) -> String {
        switch error {
        case .emptyTitle:
            return NSLocalizedString(
                "insight.error.emptyTitle",
                value: "请给视角起个名字",
                comment: "Insight strategy validation — empty title"
            )
        case .emptyInstructions:
            return NSLocalizedString(
                "insight.error.emptyInstructions",
                value: "请写下想让我怎么看待这条记录",
                comment: "Insight strategy validation — empty instructions"
            )
        case .titleTooLong:
            return String(format: NSLocalizedString(
                "insight.error.titleTooLong",
                value: "视角名称最多 %d 个字符",
                comment: "Insight strategy validation — title too long; %d = limit"
            ), InsightStrategy.maxTitleLength)
        case .instructionsTooLong:
            return String(format: NSLocalizedString(
                "insight.error.instructionsTooLong",
                value: "指令最多 %d 个字符",
                comment: "Insight strategy validation — instructions too long; %d = limit"
            ), InsightStrategy.maxInstructionsLength)
        }
    }
}
