import SwiftUI
import DayPageServices

// MARK: - AskPastView

/// D1「和你的过去对话」对话界面（研究文档 §3 D1）。
///
/// 用户通过 Siri/快捷指令（`AskTodayIntent` → `daypage://ask`）或 app 内入口
/// 提问，本视图驱动 `MemoryChatService` 做图谱增强检索（D2）+ LLM 回答，
/// 并把「引用了哪些记录」作为来源 chip 显式呈现——让"连"的价值被用户感知
/// （研究文档 §5 风险 4：把图谱价值显性化）。
struct AskPastView: View {

    /// 初始问题（来自 deep-link）；为空则展示空态引导。
    let seedQuestion: String?
    let onClose: () -> Void

    @StateObject private var chat = MemoryChatService()
    @StateObject private var voiceService = VoiceService.shared
    /// 对话长河：封存会话的胶囊层，沉在当前对话上游（设计 v2 D4）。
    @StateObject private var river = ChatRiverModel()
    @State private var draft: String = ""
    @State private var didSeed = false
    @State private var isRecordingVoice: Bool = false
    /// Assistant turns the user has already pinned into today's diary this
    /// session. Purely UI state — used to switch the pin button to a
    /// "已存入" checkmark and disable further taps.
    @State private var pinnedTurnIDs: Set<UUID> = []
    /// Turn ID that just got pinned — drives a 1.5s success toast without
    /// having to plumb a Banner through the chat view.
    @State private var justPinnedTurnID: UUID? = nil
    /// 初始落点只执行一次：河口（底部）。之后「更早的对话」扩窗
    /// 不允许再把用户拽回底部。
    @State private var didInitialLanding = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                ChatRiverSelectionBar(river: river)
                Divider().background(DSColor.borderSubtle)
                inputBar
            }
            .background(DSColor.bgWarm.ignoresSafeArea())
            .navigationTitle("和过去对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // /clear 语义：封口当前会话——它以胶囊形态沉入长河，
                    // 输入框归零。spring 让「封存」这件事被看见。
                    Button {
                        Haptics.soft()
                        withAnimation(Motion.spring) {
                            chat.reset()
                            river.refresh(excluding: nil)
                        }
                        draft = ""
                    } label: { Image(systemName: "square.and.pencil") }
                        .disabled(chat.turns.isEmpty)
                        .accessibilityLabel("新对话")
                }
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
        .task {
            guard !didSeed else { return }
            didSeed = true
            // D1: --continue 语义 —— 接上今天最近一段未封口会话，
            // 让回访用户看到先前轮次而不是空态。
            chat.resumeTodaySession()
            river.refresh(excluding: chat.sessionRef?.id)
            if let seed = seedQuestion?.trimmingCharacters(in: .whitespacesAndNewlines), !seed.isEmpty {
                await chat.ask(seed)
            } else if chat.turns.isEmpty {
                inputFocused = true
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // 长河：封存会话的沉积层。上滑即历史；点开原位回放，
                    // 「继续这段对话」把整段交还给活跃会话。
                    ChatRiverSection(river: river) { loaded in
                        withAnimation(Motion.spring) {
                            chat.resume(loaded)
                            river.exitSelection()
                            river.refresh(excluding: loaded.summary.id)
                        }
                    }
                    if !river.summaries.isEmpty && !chat.turns.isEmpty {
                        currentSessionMarker
                    }
                    if chat.turns.isEmpty && !chat.isResponding {
                        emptyState
                    }
                    ForEach(chat.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    if chat.isResponding {
                        respondingIndicator.id("responding")
                    }
                    if let err = chat.errorMessage {
                        errorRow(err)
                    }
                    Color.clear.frame(height: 1).id("river-mouth")
                }
                .padding(16)
            }
            .onAppear {
                // 河从上游流向河口——初始落点必须在河口（底部），
                // 历史靠上滑发现。
                proxy.scrollTo("river-mouth", anchor: .bottom)
            }
            .onChange(of: river.summaries.count) { _ in
                // 胶囊层在 .task 里异步落地；若此刻还没有活跃对话
                // （turns 的 onChange 不会兜底），补一次落底。
                guard !didInitialLanding, chat.turns.isEmpty else { return }
                didInitialLanding = true
                proxy.scrollTo("river-mouth", anchor: .bottom)
            }
            .onChange(of: chat.turns.count) { _ in
                didInitialLanding = true
                withAnimation { proxy.scrollTo(chat.turns.last?.id, anchor: .bottom) }
            }
            .onChange(of: chat.isResponding) { responding in
                if responding { withAnimation { proxy.scrollTo("responding", anchor: .bottom) } }
            }
        }
    }

    /// 长河与活跃对话的分界拍：「· · 当前对话 HH:mm · ·」。
    private var currentSessionMarker: some View {
        let timeLabel: String = {
            guard let first = chat.turns.first else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            f.timeZone = TimeZone.current
            return f.string(from: first.createdAt)
        }()
        return Text("· · \(NSLocalizedString("chat.river.current_marker", value: "当前对话", comment: "Chat river — current conversation divider")) \(timeLabel) · ·")
            .font(DSType.mono10)
            .tracking(1.5)
            .foregroundColor(DSColor.inkSubtle)
            .frame(maxWidth: .infinity)
    }

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
                if let context = turn.context, !context.isEmpty {
                    sourceChips(context)
                }
                assistantActions(for: turn)
            }
        }
    }

    /// Row of actions under an assistant turn — currently just "存入今日日记",
    /// but scoped as a HStack so future additions (copy, share) land cleanly.
    @ViewBuilder
    private func assistantActions(for turn: ChatTurn) -> some View {
        let pinned = pinnedTurnIDs.contains(turn.id)
        HStack(spacing: 12) {
            Button {
                Haptics.tapConfirm()
                let ok = chat.pinTurnToDiary(turn)
                if ok {
                    pinnedTurnIDs.insert(turn.id)
                    justPinnedTurnID = turn.id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if justPinnedTurnID == turn.id { justPinnedTurnID = nil }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pinned ? "checkmark.circle.fill" : "text.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text(pinned ? "已存入今日" : "存入今日日记")
                        .font(DSType.labelSM)
                }
                .foregroundColor(pinned ? DSColor.successGreen : DSColor.accentOnBg)
            }
            .buttonStyle(.plain)
            .disabled(pinned)
            .accessibilityLabel(pinned ? "已存入今日日记" : "把这条回答存入今日日记")

            if justPinnedTurnID == turn.id {
                Text("✓ 已加入今日 timeline")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                    .transition(.opacity)
            }
        }
        .padding(.top, 4)
    }

    /// 引用来源 chips：把检索到的 memo 日期与实体显式呈现。
    private func sourceChips(_ context: RetrievedContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("依据")
                .font(DSType.labelSM)
                .foregroundColor(DSColor.inkMuted)
            FlowChips(items: chipLabels(from: context))
        }
        .padding(.top, 2)
    }

    private func chipLabels(from context: RetrievedContext) -> [String] {
        var labels: [String] = []
        let dates = Array(Set(context.memoHits.map { $0.dateString })).sorted(by: >)
        labels.append(contentsOf: dates.prefix(4))
        labels.append(contentsOf: context.entityHits.prefix(3).map { $0.displayName })
        return labels
    }

    // MARK: - Empty / loading / error

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("问问你的过去")
                .font(DSType.serifBody20)
                .foregroundColor(DSColor.inkPrimary)
            Text("基于你记录过的内容回答，并标注依据来源。试试：")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
            ForEach(Self.examplePrompts, id: \.self) { example in
                Button {
                    Task { await chat.ask(example) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 12))
                            .foregroundColor(DSColor.accentOnBg)
                        Text(example)
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkPrimary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(DSColor.surfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var respondingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在翻看你的记录…")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(DSType.bodySM)
            .foregroundColor(DSColor.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(DSColor.surfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("问问你的过去…", text: $draft, axis: .vertical)
                .font(DSType.bodySM)
                .focused($inputFocused)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DSColor.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .onSubmit(submit)

            // Voice input — mirrors Today composer semantics: tap to start
            // recording, tap again to stop + transcribe. The transcript is
            // dropped into `draft` so the user can review before sending.
            Button {
                Haptics.soft()
                Task { await toggleVoiceRecording() }
            } label: {
                Image(systemName: isRecordingVoice ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 26))
                    .foregroundColor(isRecordingVoice ? DSColor.error : DSColor.inkMuted)
                    // Simple recording pulse — matches the composer's mic
                    // affordance without depending on iOS 17's symbolEffect.
                    .scaleEffect(isRecordingVoice ? 1.08 : 1.0)
                    .animation(
                        isRecordingVoice ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                        value: isRecordingVoice
                    )
            }
            .disabled(chat.isResponding)
            .accessibilityLabel(isRecordingVoice ? "停止录音并转录" : "语音提问")

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(canSend ? DSColor.accentOnBg : DSColor.inkSubtle)
            }
            .disabled(!canSend)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DSColor.bgWarm)
    }

    /// Toggle voice recording. On second tap, blocks briefly on Whisper so
    /// the transcript can land in the composer for a review-then-send flow
    /// (matches the composer semantics — voice-to-text, not voice-as-attachment).
    private func toggleVoiceRecording() async {
        if !isRecordingVoice {
            isRecordingVoice = true
            await voiceService.startRecording()
        } else {
            isRecordingVoice = false
            if let result = await voiceService.stopAndTranscribe(),
               let transcript = result.transcript,
               !transcript.isEmpty {
                if draft.isEmpty {
                    draft = transcript
                } else {
                    draft += " " + transcript
                }
                inputFocused = true
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isResponding
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.isResponding else { return }
        draft = ""

        // Reminder vNext：问过去的输入框同样接调度 —— 「明早提醒我看这段」
        // 在对话里直接落统一调度器，不进 RAG 检索。与 TodayCoachView.submit
        // 同一拦截逻辑；解析失败但含提醒动词时追问。
        if FeatureFlagStore.shared.isEnabled(.captureReminder) {
            if let parsed = ReminderIntentParser.parse(question) {
                let reminder = CaptureReminderService.shared.addReminder(
                    Reminder(trigger: parsed.trigger, label: parsed.label, source: .ai)
                )
                // 统一走 service —— 本地即答轮次同样落盘进会话文件。
                chat.appendLocalExchange(
                    user: question,
                    assistant: TodayCoachView.reminderConfirmation(for: reminder)
                )
                Haptics.success()
                return
            }
            if ReminderIntentParser.containsReminderVerb(question) {
                chat.appendLocalExchange(
                    user: question,
                    assistant: NSLocalizedString(
                        "coach.reminder.clarify",
                        value: "好——几点提醒你？可以说「今晚」「明早」「一小时后」，或者给个具体时间，比如「明天 15:00」；重复的话说「每天 22:00」「周一三五 9 点」。",
                        comment: "Coach follow-up when a reminder request lacks a parseable time"
                    )
                )
                return
            }
        }

        Task { await chat.ask(question) }
    }

    // MARK: - Static

    static let examplePrompts = [
        "我最近的情绪有什么变化？",
        "去年这个时候我在做什么？",
        "我提到最多的地方是哪里？"
    ]
}

// MARK: - FlowChips

/// 简单的自动换行 chip 容器。用于展示对话回答的来源依据。
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        // iOS 16 无原生 flow layout；chip 数量已被上游限制在个位数，
        // 这里用每行最多 3 个的 wrap 近似即可。
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows(), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in chip(item) }
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DSType.labelSM)
            .foregroundColor(DSColor.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.surfaceContainerHigh)
            .clipShape(Capsule())
    }

    /// 每行最多 3 个 chip。
    private func rows() -> [[String]] {
        stride(from: 0, to: items.count, by: 3).map {
            Array(items[$0..<min($0 + 3, items.count)])
        }
    }
}
