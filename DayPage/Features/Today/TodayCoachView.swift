import SwiftUI
import DayPageServices

// MARK: - TodayCoachView

/// Issue #804「今日陪写」sheet——Today 空态 sparkle 和 dock sparkle 的新默认落点。
///
/// 与 `AskPastView` 的边界：
/// - **AskPastView**：Siri intent / 侧边栏「问过去」入口。RAG 语义。
/// - **TodayCoachView**：Today 页所有 sparkle 入口默认打开这里。引导记录语义。
struct TodayCoachView: View {

    let onClose: () -> Void
    /// 用户在 Coach 里把 draft 存进日记后回调——用于 Today 顶层刷新时间线。
    var onDidPinDraft: (() -> Void)? = nil

    @StateObject private var coach: TodayCoachService
    @State private var draft: String = ""
    @State private var pinnedTurnIDs: Set<UUID> = []
    @State private var justPinnedTurnID: UUID? = nil
    @State private var editingDraftTurnID: UUID? = nil
    @State private var editableDraft: String = ""
    @FocusState private var inputFocused: Bool

    init(
        onClose: @escaping () -> Void,
        onDidPinDraft: (() -> Void)? = nil
    ) {
        self.onClose = onClose
        self.onDidPinDraft = onDidPinDraft
        let ctx = TodayCoachContext.snapshotForToday()
        self._coach = StateObject(wrappedValue: TodayCoachService(context: ctx))
    }

    var body: some View {
        // Hand-built header instead of NavigationStack + toolbar: system
        // toolbar items were unreachable in the accessibility tree (VoiceOver
        // users could not close the sheet), and the plain nav bar broke the
        // app's serif + glass-disc language.
        VStack(spacing: 0) {
            header
            conversation
            inputBar
        }
        .background(DSColor.bgWarm.ignoresSafeArea())
        .task {
            if coach.turns.isEmpty {
                inputFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("陪你写今天")
                    .font(DSFonts.serif(size: 17, weight: .semibold, relativeTo: .headline))
                    .tracking(-0.2)
                    .foregroundColor(DSColor.inkPrimary)
                Text("DAYPAGE · COACH")
                    .font(DSFonts.jetBrainsMono(size: 8.5, weight: .semibold, relativeTo: .caption2))
                    .tracking(1.8)
                    .foregroundColor(DSColor.inkMuted)
            }
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .dpGlass(.control, in: Circle())
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("coach-close")

                Spacer()

                Button {
                    coach.reset()
                    pinnedTurnIDs.removeAll()
                    draft = ""
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .dpGlass(.control, in: Circle())
                .disabled(coach.turns.isEmpty)
                .opacity(coach.turns.isEmpty ? 0.45 : 1)
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("coach-new-chat")
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.lg)
        .padding(.bottom, 10)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.lg) {
                    if coach.turns.isEmpty && !coach.isResponding {
                        emptyState
                    }
                    ForEach(coach.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    if coach.isResponding {
                        respondingIndicator.id("responding")
                    }
                    if let err = coach.errorMessage {
                        errorRow(err)
                        // Issue #804: 无 API Key / 网络失败时不能让用户干瞪着 error。
                        // 提示：直接把 draft 存进今日 memo，AI 不可用也能记录。
                        if err.contains("API Key") || err.contains("offline") || err.contains("离线") {
                            offlineFallbackRow
                        }
                    }
                }
                .padding(DSSpacing.lg)
            }
            .onChange(of: coach.turns.count) { _ in
                withAnimation { proxy.scrollTo(coach.turns.last?.id, anchor: .bottom) }
            }
            .onChange(of: coach.isResponding) { responding in
                if responding { withAnimation { proxy.scrollTo("responding", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: CoachTurn) -> some View {
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
                if let draft = turn.memoDraft, !draft.isEmpty {
                    memoDraftBlock(draft, turn: turn)
                }
                assistantActions(for: turn)
            }
        }
    }

    /// draft 引用块——把「AI 想让你存进日记的这句话」显性化。
    private func memoDraftBlock(_ draft: String, turn: CoachTurn) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Rectangle()
                .fill(DSColor.accentOnBg)
                .frame(width: 2)
                .cornerRadius(1)
            if editingDraftTurnID == turn.id {
                TextField("改写成日记…", text: $editableDraft, axis: .vertical)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("coach-draft-edit")
            } else {
                Text(draft)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkSecondary)
                    .italic()
            }
        }
        .padding(.vertical, 6)
    }

    /// 「存入今日 / 继续问我 / 改写成日记」——每条 assistant 回复固定挂着。
    @ViewBuilder
    private func assistantActions(for turn: CoachTurn) -> some View {
        let pinned = pinnedTurnIDs.contains(turn.id)
        let editing = editingDraftTurnID == turn.id
        HStack(spacing: 14) {
            // 1) 存入今日
            Button {
                Haptics.tapConfirm()
                var effectiveTurn = turn
                if editing {
                    effectiveTurn.memoDraft = editableDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    editingDraftTurnID = nil
                }
                let ok = coach.pinDraftToDiary(effectiveTurn)
                if ok {
                    pinnedTurnIDs.insert(turn.id)
                    justPinnedTurnID = turn.id
                    onDidPinDraft?()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if justPinnedTurnID == turn.id { justPinnedTurnID = nil }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pinned ? "checkmark.circle.fill" : "text.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text(pinned ? "已存入" : "存入今日")
                        .font(DSType.labelSM)
                }
                .foregroundColor(pinned ? DSColor.statusSuccess : DSColor.accentOnBg)
            }
            .buttonStyle(.plain)
            .disabled(pinned || (turn.memoDraft ?? "").isEmpty)
            .accessibilityIdentifier("coach-pin")
            .accessibilityLabel(pinned ? "已存入今日日记" : "把这段草稿存入今日日记")

            // 2) 继续问我
            Button {
                Haptics.soft()
                Task { await coach.ask("继续问我一个更具体的问题") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text("继续问我")
                        .font(DSType.labelSM)
                }
                .foregroundColor(DSColor.inkMuted)
            }
            .buttonStyle(.plain)
            .disabled(coach.isResponding)
            .accessibilityIdentifier("coach-continue")

            // 3) 改写成日记
            if let d = turn.memoDraft, !d.isEmpty {
                Button {
                    Haptics.soft()
                    if editing {
                        editingDraftTurnID = nil
                    } else {
                        editableDraft = d
                        editingDraftTurnID = turn.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: editing ? "checkmark" : "pencil")
                            .font(.system(size: 12, weight: .semibold))
                        Text(editing ? "完成改写" : "改写成日记")
                            .font(DSType.labelSM)
                    }
                    .foregroundColor(DSColor.inkMuted)
                }
                .buttonStyle(.plain)
                .disabled(pinned)
                .accessibilityIdentifier("coach-edit")
            }

            if justPinnedTurnID == turn.id {
                Text("✓ 已加入今日 timeline")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                    .transition(.opacity)
            }
        }
        .padding(.top, DSSpacing.xs)
    }

    // MARK: - Empty / loading / error

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("先落下一句就好")
                .font(DSType.serifBody20)
                .foregroundColor(DSColor.inkPrimary)
            Text("不知道写什么也没关系。挑一个开始，或者直接说你此刻的感觉。")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
            ForEach(Self.coachSeeds, id: \.self) { seed in
                Button {
                    Task { await coach.ask(seed) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12))
                            .foregroundColor(DSColor.accentOnBg)
                        Text(seed)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkPrimary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, 13)
                    .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .solidCard(cornerRadius: DSRadius.md)
                .accessibilityIdentifier("coach-seed")
            }
            Text("想查历史？打开左侧「问过去」。")
                .font(DSType.labelSM)
                .foregroundColor(DSColor.inkMuted)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DSSpacing.xl2)
        .accessibilityIdentifier("coach-empty-state")
    }

    /// 加载态改造——不再是「翻看你的记录…」（那是 RAG 语义）。
    private var respondingIndicator: some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView().controlSize(.small)
            Text("正在帮你找一个切入口…")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("coach-responding")
    }

    /// 无 API Key 或离线时的兜底：让用户仍能把输入直接存成 raw memo，
    /// 保证「不知道写什么」的用户不会因 AI 不可用而卡死在 Coach。
    private var offlineFallbackRow: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("AI 暂时不可用——但你写下的这句话可以直接存进今天。")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
            if let lastUser = coach.turns.last(where: { $0.role == .user }) {
                Button {
                    Haptics.tapConfirm()
                    let stub = CoachTurn(role: .assistant, text: "", memoDraft: lastUser.text)
                    _ = coach.pinDraftToDiary(stub)
                    onDidPinDraft?()
                    justPinnedTurnID = stub.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("直接存入今日")
                            .font(DSType.labelSM)
                    }
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.sm)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("coach-offline-pin")
            }
        }
        .padding(.top, DSSpacing.xs)
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(DSType.bodySM)
            .foregroundColor(DSColor.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .background(DSColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    // MARK: - Input bar

    /// STREAM-dock language: one glass capsule holding the field + an amber
    /// send orb, floating over the warm canvas — mirrors InputBarV4 so the
    /// coach reads as part of the same capture family.
    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("说说此刻…", text: $draft, axis: .vertical)
                .font(DSType.bodySM)
                .focused($inputFocused)
                .lineLimit(1...4)
                .padding(.leading, DSSpacing.lg)
                .padding(.vertical, 11)
                .onSubmit(submit)
                .accessibilityIdentifier("coach-input")

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DSColor.onAmber)
                    .frame(width: 42, height: 34)
                    .background(
                        Capsule().fill(canSend ? DSColor.amberDeep : DSColor.inkSubtle.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 5)
            .disabled(!canSend)
            .animation(Motion.fade, value: canSend)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("coach-send")
        }
        .dpGlass(.control, in: Capsule())
        // Coach input capsule lift → DSElevation.glass (dark-mode adaptive),
        // replacing the hardcoded warm-ink shadow that sank in dark mode.
        .elevation(.glass)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.sm)
        .padding(.bottom, DSSpacing.md)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coach.isResponding
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !coach.isResponding else { return }
        draft = ""

        // Reminder vNext：「提醒我…」在 IntentRouter 之前拦截，直接落统一
        // 调度器 —— 排提醒是高频小意图，零 LLM 往返。解析出时间就排 +
        // 确认；有提醒动词但时间模糊则追问，绝不猜时间。
        if FeatureFlagStore.shared.isEnabled(.captureReminder) {
            if let parsed = ReminderIntentParser.parse(text) {
                let reminder = CaptureReminderService.shared.addReminder(
                    Reminder(trigger: parsed.trigger, label: parsed.label, source: .ai)
                )
                coach.turns.append(CoachTurn(role: .user, text: text))
                coach.turns.append(CoachTurn(
                    role: .assistant,
                    text: Self.reminderConfirmation(for: reminder)
                ))
                Haptics.success()
                return
            }
            if ReminderIntentParser.containsReminderVerb(text) {
                coach.turns.append(CoachTurn(role: .user, text: text))
                coach.turns.append(CoachTurn(
                    role: .assistant,
                    text: NSLocalizedString(
                        "coach.reminder.clarify",
                        value: "好——几点提醒你？可以说「今晚」「明早」「一小时后」，或者给个具体时间，比如「明天 15:00」；重复的话说「每天 22:00」「周一三五 9 点」。",
                        comment: "Coach follow-up when a reminder request lacks a parseable time"
                    )
                ))
                return
            }
        }

        // IntentRouter：只有明确历史意图才提示切换到「问过去」；其余走 Coach。
        let intent = IntentRouter.classify(text, hasHistoryHints: false)
        if intent == .askPast {
            let userTurn = CoachTurn(role: .user, text: text)
            let hintTurn = CoachTurn(
                role: .assistant,
                text: "这个问题更像是查历史——去左侧「问过去」入口，会调用你的所有记录来回答。",
                memoDraft: "刚刚想问的：\(text)"
            )
            coach.turns.append(userTurn)
            coach.turns.append(hintTurn)
            return
        }
        Task { await coach.ask(text) }
    }

    /// 排好后的确认文案：一次性 = 「今晚 20:00」；重复 = 「每天 22:00」。
    /// 落点提示指向 Today 胶囊条 —— AI 排的提醒在那里可见、可改、可删。
    static func reminderConfirmation(for reminder: Reminder) -> String {
        let when: String
        if case .once(let date) = reminder.trigger {
            // relativeDayLabel 已含时间(「今天 13:29」),不再拼 timeString。
            when = Reminder.relativeDayLabel(for: date)
        } else {
            when = "\(reminder.repeatDescription) \(reminder.timeString)"
        }
        let labelPart = reminder.label.isEmpty ? "" : "「\(reminder.label)」"
        return String(
            format: NSLocalizedString(
                "coach.reminder.confirmed",
                value: "已排好：%@ %@。到点我会来敲你——在 Today 顶部的提醒条里随时可改可删。",
                comment: "Coach confirmation after scheduling a reminder (1: when, 2: label)"
            ),
            when, labelPart
        )
    }

    // MARK: - Static

    static let coachSeeds = [
        "此刻更像是身体累、脑子乱，还是事情太多？",
        "先不用想目标——只写一个你此刻最想逃开的东西。",
        "如果只能记一句话，会是什么？"
    ]
}
