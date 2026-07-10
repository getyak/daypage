import SwiftUI
import UIKit
import PhotosUI
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - DailyPageView

/// 渲染来自 vault/wiki/daily/YYYY-MM-DD.md 的已编译 Daily Page。
struct DailyPageView: View {

    let dateString: String
    var onReturnToToday: ((String) -> Void)? = nil  // 点击跟进问题时调用，传入预填充文本
    /// true = 由外层导航栈 push 呈现（DayDetailView 内嵌）；false = 独立模态
    /// （Today fullScreenCover / EntityPage sheet）需要自带 NavigationStack。
    var isEmbedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var memoVM = DailyPageMemoVM()
    @ObservedObject private var compilationService = CompilationService.shared
    @State private var selectedTab: DailyPageTab = .digest
    @Namespace private var tabPillNS
    @State private var model: DailyPageModel? = nil
    @State private var rawText: String = ""
    @State private var rawMemos: [Memo] = []
    @State private var selectedEntitySlug: String? = nil
    @State private var selectedEntityType: String = "themes"

    // US-017/US-021: Recompile & Edit Metadata
    @State private var showRecompileConfirm: Bool = false
    @State private var isRecompiling: Bool = false
    @State private var recompileError: String? = nil
    @State private var showEditMetadata: Bool = false

    /// Issue #302: share-card sheet payload.
    @State private var sharePayload: SharePayload? = nil
    /// "Last compiled at HH:MM" derived from the daily file's modification date.
    @State private var lastCompiledTimeLabel: String? = nil

    // Thread conversation state — keyed by question string
    @State private var threadVMs: [String: ThreadConversationViewModel] = [:]
    // Freeform input area
    @State private var freeformDraft: String = ""
    @State private var freeformVM: ThreadConversationViewModel? = nil

    /// Hosts the page in its own NavigationStack ONLY when presented modally.
    /// When pushed inside an existing stack (DayDetailView), nesting a second
    /// NavigationStack produced a duplicate back affordance (system chevron +
    /// arrow.left) and an intermittently blank first render (FINDING-003).
    @ViewBuilder
    private func navContainer<C: View>(@ViewBuilder content: () -> C) -> some View {
        if isEmbedded {
            content()
        } else {
            NavigationStack(root: content)
        }
    }

    var body: some View {
        navContainer {
            ZStack {
                DSColor.background.ignoresSafeArea()

                if let model {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            segmentedControl
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            ZStack {
                                if selectedTab == .digest {
                                    digestContent(model: model)
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)
                                        ))
                                } else {
                                    timelineContent(model: model)
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)
                                        ))
                                }
                            }
                            .dsAnimation(Motion.spring, value: selectedTab)

                            footer(model: model)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 40)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        Text("无法加载日记")
                            .bodyMDStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Text(dateString)
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Button("关闭") { dismiss() }
                            .monoLabelStyle(size: 12)
                            .foregroundColor(DSColor.primary)
                            .padding(.top, 8)
                    }
                }
            }
            .navigationDestination(for: Memo.ID.self) { memoID in
                if let memo = memoVM.memos.first(where: { $0.id == memoID }) {
                    MemoDetailView(memo: memo, vm: memoVM)
                } else {
                    Text(NSLocalizedString("memo.not_found", comment: "Memo missing fallback")).foregroundColor(DSColor.inkMuted)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Embedded (pushed) mode inherits the host stack's back button
                // and title — adding our own here doubled both (FINDING-003).
                if !isEmbedded {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(DSColor.onSurface)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(dailyPageMonthDay(dateString))
                            .headlineMDStyle()
                            .foregroundColor(DSColor.onSurface)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRecompiling {
                        ProgressView()
                            .tint(DSColor.onSurface)
                            .scaleEffect(0.8)
                    } else {
                        Menu {
                            Button {
                                showRecompileConfirm = true
                            } label: {
                                Label("重新编译", systemImage: "arrow.clockwise")
                            }
                            Button {
                                showEditMetadata = true
                            } label: {
                                Label("编辑元数据", systemImage: "pencil")
                            }
                            // Issue #302: share daily page as card.
                            if let m = model {
                                Button {
                                    sharePayload = .daily(DailySnapshot.from(m, rawMemos: rawMemos))
                                } label: {
                                    Label("分享为卡片", systemImage: "square.and.arrow.up.on.square")
                                }
                                Button {
                                    var attrib = m.dateString
                                    if !m.locationPrimary.isEmpty {
                                        attrib += " · " + m.locationPrimary
                                    }
                                    sharePayload = .quote(QuoteSnapshot(
                                        text: m.summary,
                                        attribution: attrib
                                    ))
                                } label: {
                                    Label("分享为引用", systemImage: "quote.opening")
                                }
                                let photoMemos = rawMemos.filter { $0.attachments.contains { $0.kind == "photo" } }
                                if let firstPhoto = photoMemos.first,
                                   let snap = PhotoSnapshot.from(firstPhoto) {
                                    Button {
                                        sharePayload = .photo(snap)
                                    } label: {
                                        Label("分享照片", systemImage: "photo.on.rectangle")
                                    }
                                }
                                let voiceMemos = rawMemos.filter { $0.attachments.contains { $0.kind == "audio" } }
                                if let firstVoice = voiceMemos.first,
                                   let snap = VoiceSnapshot.from(firstVoice) {
                                    Button {
                                        sharePayload = .voice(snap)
                                    } label: {
                                        Label("分享语音日记", systemImage: "mic.badge.plus")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundColor(DSColor.onSurface)
                        }
                    }
                }
            }
        }
        .onAppear { loadPage() }
        .alert("Recompile today?", isPresented: $showRecompileConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Recompile", role: .destructive) {
                Task { await recompile() }
            }
        } message: {
            if let t = lastCompiledTimeLabel {
                Text("Last compiled at \(t)")
            } else {
                Text("AI will recompile today's memos into a new daily page.")
            }
        }
        .alert("编译失败", isPresented: Binding(
            get: { recompileError != nil },
            set: { if !$0 { recompileError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(recompileError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { selectedEntitySlug != nil },
            set: { if !$0 { selectedEntitySlug = nil } }
        )) {
            if let slug = selectedEntitySlug {
                EntityPageView(entityType: selectedEntityType, entitySlug: slug, sourceDateString: dateString)
            }
        }
        .sheet(isPresented: $showEditMetadata, onDismiss: { loadPage() }) {
            if let m = model {
                DailyPageMetadataEditView(
                    dateString: dateString,
                    currentSummary: m.summary,
                    currentWeather: extractWeatherFromRawText(rawText),
                    currentMood: extractMoodFromRawText(rawText),
                    currentCoverPath: m.coverAssetPath,
                    rawMemos: rawMemos
                )
            }
        }
        // Issue #302: share-card sheet entry.
        .sheet(item: $sharePayload) { payload in
            ShareCardSheet(payload: payload)
        }
    }

    // MARK: - Recompile

    private func recompile() async {
        isRecompiling = true
        defer { isRecompiling = false }

        guard let date = DateFormatters.isoDate.date(from: dateString) else {
            recompileError = "日期格式无效"
            return
        }

        do {
            let memoCount = rawMemos.count
            // Explicit "recompile" intent — bypass the #814 source_hash guard
            // so the user can regenerate a page they disliked even when the
            // underlying memos are unchanged.
            try await CompilationService.shared.compile(for: date, trigger: "manual", force: true)
            loadPage()
            // US-022: show success banner with memo count
            BannerCenter.shared.show(AppBannerModel(
                kind: .success,
                title: "✓ Compiled \(memoCount) memos into today's page",
                autoDismiss: true
            ))
        } catch {
            recompileError = error.localizedDescription
        }
    }

    // MARK: - Metadata Extraction Helpers

    private func extractWeatherFromRawText(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("weather:") {
                return String(t.dropFirst("weather:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func extractMoodFromRawText(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("mood:") {
                return String(t.dropFirst("mood:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    // MARK: - Segmented Control

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(DailyPageTab.allCases, id: \.self) { tab in
                Button(action: {
                    guard selectedTab != tab else { return }
                    HapticFeedback.soft()
                    withAnimation(Motion.respectReduceMotion(Motion.spring)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.rawValue)
                        .monoLabelStyle(size: 11)
                        .foregroundColor(selectedTab == tab ? DSColor.onPrimary : DSColor.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if selectedTab == tab {
                                Rectangle()
                                    .fill(DSColor.primary)
                                    .matchedGeometryEffect(id: "tabPill", in: tabPillNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            Rectangle()
                .stroke(DSColor.primary, lineWidth: 2)
        )
        .cornerRadius(0)
        .padding(.bottom, 32)
    }

    // MARK: - Digest Content (v4 hero layout)

    @ViewBuilder
    private func digestContent(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // v4 hero card — glass hi-tone surface
            v4HeroCard(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)

            // Action row: Regenerate / Add note / Reflect
            sourceActionsRow(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            // Source Signals list
            if !rawMemos.isEmpty {
                sourceSignalsSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
            }

            // AI Follow-up Threads (legacy section kept for compatibility)
            if !model.followUpQuestions.isEmpty {
                threadsSection(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Source Actions Row

    private func sourceActionsRow(model: DailyPageModel) -> some View {
        HStack(spacing: 8) {
            ActionBtn(icon: "arrow.clockwise", label: "Regenerate") {
                Task { await recompile() }
            }
            ActionBtn(icon: "plus.bubble", label: "Add note") {
                dismiss()
                onReturnToToday?("")
            }
            ActionBtn(icon: "text.bubble", label: "Reflect", disabled: true) {
                // Coming soon — TODO: Reflect feature follow-up issue
            }
        }
    }

    // MARK: - Source Signals Section

    private var sourceSignalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCE SIGNALS")
                .font(DSFonts.spaceGrotesk(size: 11, weight: .semibold))
                .foregroundColor(DSColor.inkMuted)
                .tracking(1.6)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(memoVM.memos) { memo in
                    NavigationLink(value: memo.id) {
                        SourceSignalRow(memo: memo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .liquidGlassCard(cornerRadius: DSRadius.lg, tone: .std)
            .padding(4)
        }
    }

    // MARK: - ActionBtn

    struct ActionBtn: View {
        let icon: String
        let label: String
        var disabled: Bool = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                    Text(label)
                        .font(DSType.labelSM)
                    if disabled {
                        Text("Coming soon")
                            .font(DSType.mono9)
                            .foregroundColor(DSColor.inkSubtle)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(DSColor.amberSoft, in: Capsule())
                    }
                }
                .foregroundColor(disabled ? DSColor.inkSubtle : DSColor.inkPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .liquidGlassPill()
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }

    // MARK: - SourceSignalRow

    private struct SourceSignalRow: View {
        let memo: Memo

        private var kindIcon: String {
            if let att = memo.attachments.first {
                switch att.kind {
                case "audio": return "V"
                case "photo": return "P"
                case "location": return "L"
                default: return "T"
                }
            }
            return "T"
        }

        private var monoTime: String {
            DateFormatters.timeHHmm.string(from: memo.created)
        }

        var body: some View {
            HStack(spacing: 10) {
                // Kind tile
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DSColor.amberSoft)
                        .frame(width: 28, height: 28)
                    Text(kindIcon)
                        .font(DSFonts.jetBrainsMono(size: 11, weight: .medium))
                        .foregroundColor(DSColor.accentOnBg)
                }

                // Truncated body
                Text(memo.body.isEmpty ? "(no text)" : memo.body)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Timestamp
                Text(monoTime)
                    .font(DSType.mono9)
                    .foregroundColor(DSColor.inkMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - v4 Hero Card

    private func v4HeroCard(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DSColor.accentOnBg)
                    .frame(width: 8, height: 8)
                    .shadow(color: DSColor.amberGlow, radius: 6, x: 0, y: 0)
                Text("COMPILED \(model.entriesCount) SIGNALS")
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkMuted)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.bottom, 16)

            Text(dailyPageMonthDay(model.dateString))
                .font(DSType.serifDisplay32)
                .foregroundColor(DSColor.inkPrimary)
                .tracking(-0.6)
                .lineSpacing(2)
                .padding(.bottom, 22)

            DailyPageSummarySection(model: model, onMentionTap: { mention in
                let slug = mention.hasPrefix("@") ? String(mention.dropFirst()) : mention
                let (type, resolved) = resolveEntityTypeAndSlug(slug)
                selectedEntityType = type
                selectedEntitySlug = resolved
            })
        }
        .padding(28)
        .liquidGlassCard(cornerRadius: 24, tone: .hi)
    }

    // MARK: - Timeline Content

    @ViewBuilder
    private func timelineContent(model: DailyPageModel) -> some View {
        if rawMemos.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text("该日无原始记录")
                    .h2Style()
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(Array(rawMemos.enumerated()), id: \.element.id) { idx, memo in
                    TimelineRow(
                        memo: memo,
                        isLast: idx == rawMemos.count - 1
                    )
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Threads (AI Follow-up) — expandable conversation cards

    private func threadsSection(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THREADS")
                .sectionLabelStyle()
                .foregroundColor(DSColor.outline)

            ForEach(model.followUpQuestions, id: \.self) { question in
                threadCard(question: question, compiledText: model.rawContent)
            }

            freeformInputArea(compiledText: model.rawContent)
        }
    }

    /// Returns (creating if needed) the VM for a given question and renders an expandable card.
    private func threadCard(question: String, compiledText: String) -> some View {
        let vm = threadVM(for: question, compiledText: compiledText)
        return ThreadConversationView(vm: vm)
            .onTapGesture {
                // First tap expands and fires the initial question.
                guard !vm.isExpanded else { return }
                withAnimation(Motion.respectReduceMotion(Motion.expand)) {
                    // Collapse all other threads and freeform before expanding.
                    for key in threadVMs.keys where key != question {
                        threadVMs[key]?.isExpanded = false
                    }
                    freeformVM?.isExpanded = false
                    vm.isExpanded = true
                }
                if vm.messages.isEmpty {
                    Task { await vm.send(userMessage: question) }
                }
            }
    }

    private func threadVM(for question: String, compiledText: String) -> ThreadConversationViewModel {
        if let existing = threadVMs[question] { return existing }
        let date = DateFormatters.isoDate.date(from: dateString) ?? Date()
        let vm = ThreadConversationViewModel(question: question, compiledPageText: compiledText, date: date)
        Task { await vm.loadHistory() }
        threadVMs[question] = vm
        return vm
    }

    // MARK: - Freeform input area

    private func freeformInputArea(compiledText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Freeform VM thread card (visible only after first send)
            if let fvm = freeformVM, !fvm.messages.isEmpty {
                ThreadConversationView(vm: fvm)
            }

            // Input bar
            HStack(spacing: 8) {
                TextField("你想聊什么…", text: $freeformDraft)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkPrimary)
                    .submitLabel(.send)
                    .onSubmit { sendFreeform(compiledText: compiledText) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(DSColor.amberSoft.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))

                InlineMicButton { transcript in freeformDraft = transcript }

                Button(action: { sendFreeform(compiledText: compiledText) }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(canSendFreeform ? DSColor.accentOnBg : DSColor.inkSubtle)
                }
                .buttonStyle(.plain)
                .disabled(!canSendFreeform)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DSColor.surfaceContainerHigh.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var canSendFreeform: Bool {
        !freeformDraft.trimmingCharacters(in: .whitespaces).isEmpty
            && !(freeformVM?.isStreaming ?? false)
    }

    private func sendFreeform(compiledText: String) {
        let text = freeformDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        freeformDraft = ""

        if freeformVM == nil {
            let date = DateFormatters.isoDate.date(from: dateString) ?? Date()
            let vm = ThreadConversationViewModel(question: nil, compiledPageText: compiledText, date: date)
            freeformVM = vm
            Task {
                await vm.loadHistory()
                vm.isExpanded = true
                await vm.send(userMessage: text)
            }
        } else {
            freeformVM?.isExpanded = true
            Task { await freeformVM?.send(userMessage: text) }
        }
    }

    // MARK: - Footer

    private func footer(model: DailyPageModel) -> some View {
        VStack(spacing: 0) {
            Divider()
                .background(DSColor.surfaceContainerHigh)
                .padding(.bottom, 24)

            // US-020: compilation progress / error feedback
            if isRecompiling {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.primary)
                    Text(compilationStageLabel(compilationService.compilationProgress))
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.primary)
                    Spacer()
                }
                .padding(.bottom, 16)
            } else if let errMsg = recompileError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errMsg)
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: { Task { await recompile() } }) {
                        Text("RETRY →")
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.primary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 16)
            }

            HStack {
                Text("Compiled from \(model.memoCount) raw entries".uppercased())
                    .monoLabelStyle(size: 10)
                    .foregroundColor(DSColor.onSurfaceVariant)

                Spacer()

                Button(action: { dismiss() }) {
                    Text("VIEW ORIGINAL FLOW →")
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.primary)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
        }
    }

    private func compilationStageLabel(_ stage: CompilationStage) -> String {
        switch stage {
        case .extracting: return "Extracting memos…"
        case .compiling:  return "Compiling with AI…"
        case .formatting: return "Formatting output…"
        case .done:       return "Done"
        }
    }

    // MARK: - Wikilink Text Rendering

    /// 通过扫描 wiki 目录从 slug 解析实体类型。
    /// 未找到时回退到 "themes"（首次点击会创建空的实体页）。
    private func resolveEntityTypeAndSlug(_ inner: String) -> (type: String, slug: String) {
        let slug = inner.contains("|")
            ? String(inner.split(separator: "|", maxSplits: 1).first ?? Substring(inner))
            : inner
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")
        for type in ["places", "people", "themes"] {
            let url = wikiBase.appendingPathComponent(type).appendingPathComponent("\(slug).md")
            if FileManager.default.fileExists(atPath: url.path) {
                return (type, slug)
            }
        }
        return ("themes", slug)
    }

    // MARK: - Date Helpers

    private func dailyPageMonthDay(_ dateString: String) -> String {
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date).uppercased()
    }

    // MARK: - Load

    private func loadPage() {
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                rawText = content
                model = DailyPageParser.parse(content: content, dateString: dateString)
                // US-021: derive "Last compiled at HH:MM" from file modification date
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    lastCompiledTimeLabel = DateFormatters.timeHHmm.string(from: modDate)
                }
            } catch {
                DayPageLogger.shared.error("DailyPageView: load daily \(url.path) errno=\(errno): \(error)")
                model = nil
            }
        } else {
            DayPageLogger.shared.error("DailyPageView: daily file missing at \(url.path) errno=\(errno)")
            model = nil
        }

        // Load raw memos for Timeline Tab
        guard let date = DateFormatters.isoDate.date(from: dateString) else {
            DayPageLogger.shared.error("DailyPageView: invalid dateString '\(dateString)'")
            rawMemos = []
            return
        }
        let loaded: [Memo]
        do { loaded = try RawStorage.read(for: date) }
        catch {
            let rawURL = VaultInitializer.vaultURL
                .appendingPathComponent("raw")
                .appendingPathComponent("\(dateString).md")
            DayPageLogger.shared.error("DailyPageView: load memos \(rawURL.path) errno=\(errno): \(error)")
            loaded = []
        }
        rawMemos = loaded.sorted { $0.created < $1.created }
        memoVM.memos = rawMemos
    }
}
