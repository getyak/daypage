import SwiftUI
import UIKit
import PhotosUI

// MARK: - DailyPageTab

enum DailyPageTab: String, CaseIterable {
    case digest = "DIGEST"
    case timeline = "TIMELINE"
}

// MARK: - DailyPageModel

/// Daily Page Markdown 文件的解析模型。
struct DailyPageModel {
    let dateString: String
    let weekday: String
    let summary: String
    let locationPrimary: String
    let entriesCount: Int
    let rawContent: String        // Full file content
    let sections: [PageSection]
    let locations: [LocationEntry]
    let followUpQuestions: [String]
    let memoCount: Int
    /// Vault 相对路径，指向封面主图（例如 "raw/assets/photo_...jpg"）。
    /// 当日无照片时返回 nil。
    let coverAssetPath: String?
    /// Color-coded narrative threads. Falls back to stub when compile output lacks them.
    let threads: [ThreadEntry]
    /// Entity mention chips. Falls back to stub when compile output lacks them.
    let mentions: [String]

    struct PageSection {
        let title: String
        let body: String
    }

    struct LocationEntry {
        let time: String
        let name: String
        let note: String
    }

    /// A narrative thread with an optional color label.
    struct ThreadEntry {
        let label: String
        let color: Color
    }
}

// MARK: - FlowLayout

/// SwiftUI Layout that wraps subviews to new lines when the line width is exceeded.
struct FlowLayout: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += lineHeight + spacing
                totalHeight = y
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.maxX
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > bounds.minX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - DailyPageMemoVM

/// Lightweight MemoDetailViewModel for archive-date memos in DailyPageView.
@MainActor
final class DailyPageMemoVM: ObservableObject, MemoDetailViewModel {

    @Published var memos: [Memo] = []

    func update(memo: Memo, body: String) {
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var updated = memos[idx]
        updated.body = body
        var newMemos = memos
        newMemos[idx] = updated
        try? rewrite(memos: newMemos, referenceDate: memo.created)
        memos = newMemos
        Haptics.commit()
    }

    func deleteMemo(_ memo: Memo) {
        let remaining = memos.filter { $0.id != memo.id }
        try? rewrite(memos: remaining, referenceDate: memo.created)
        memos = remaining
    }

    private func rewrite(memos: [Memo], referenceDate: Date) throws {
        let url = RawStorage.fileURL(for: referenceDate)
        if memos.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let ordered = memos.sorted { $0.created < $1.created }
        let content = ordered.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
        try RawStorage.atomicWrite(string: content, to: url)
    }
}

// MARK: - DailyPageView

/// 渲染来自 vault/wiki/daily/YYYY-MM-DD.md 的已编译 Daily Page。
struct DailyPageView: View {

    let dateString: String
    var onReturnToToday: ((String) -> Void)? = nil  // 点击跟进问题时调用，传入预填充文本

    @Environment(\.dismiss) private var dismiss
    @StateObject private var memoVM = DailyPageMemoVM()
    @State private var selectedTab: DailyPageTab = .digest
    @State private var model: DailyPageModel? = nil
    @State private var rawText: String = ""
    @State private var rawMemos: [Memo] = []
    @State private var selectedEntitySlug: String? = nil
    @State private var selectedEntityType: String = "themes"

    // US-017: Recompile & Edit Metadata
    @State private var showRecompileConfirm: Bool = false
    @State private var isRecompiling: Bool = false
    @State private var recompileError: String? = nil
    @State private var showEditMetadata: Bool = false

    // Thread conversation state — keyed by question string
    @State private var threadVMs: [String: ThreadConversationViewModel] = [:]
    // Freeform input area
    @State private var freeformDraft: String = ""
    @State private var freeformVM: ThreadConversationViewModel? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

                if let model {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            segmentedControl
                                .padding(.horizontal, 20)
                                .padding(.top, 16)

                            if selectedTab == .digest {
                                digestContent(model: model)
                            } else {
                                timelineContent(model: model)
                            }

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
                    Text("Memo no longer exists").foregroundColor(DSColor.inkMuted)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        .alert("重新编译", isPresented: $showRecompileConfirm) {
            Button("取消", role: .cancel) {}
            Button("重新编译", role: .destructive) {
                Task { await recompile() }
            }
        } message: {
            Text("将重新调用 AI 编译今日日记，当前内容将备份至 .trash 目录。")
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
    }

    // MARK: - Recompile

    private func recompile() async {
        isRecompiling = true
        defer { isRecompiling = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: dateString) else {
            recompileError = "日期格式无效"
            return
        }

        do {
            try await CompilationService.shared.compile(for: date, trigger: "manual")
            loadPage()
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
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .monoLabelStyle(size: 11)
                        .foregroundColor(selectedTab == tab ? DSColor.onPrimary : DSColor.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedTab == tab ? DSColor.primary : Color.clear)
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
            .liquidGlassCard(cornerRadius: 18, tone: .std)
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
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: memo.created)
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
                        .foregroundColor(DSColor.amberDeep)
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
            // Status row: amber dot + "COMPILED N SIGNALS" chip
            HStack(spacing: 8) {
                Circle()
                    .fill(DSColor.amberAccent)
                    .frame(width: 8, height: 8)
                    .shadow(color: DSColor.amberGlow, radius: 6, x: 0, y: 0)

                Text("COMPILED \(model.entriesCount) SIGNALS")
                    .font(DSType.mono10)
                    .foregroundColor(DSColor.inkMuted)
                    .tracking(0.8)

                Spacer()
            }
            .padding(.bottom, 16)

            // Title: serif date heading
            Text(dailyPageMonthDay(model.dateString))
                .font(DSType.serifDisplay32)
                .foregroundColor(DSColor.inkPrimary)
                .tracking(-0.6)
                .lineSpacing(2)
                .padding(.bottom, 22)

            // Narrative sections with hairline dividers
            if !model.sections.isEmpty {
                // First section (no top divider)
                narrativeParagraph(model.sections[0].body)
                    .padding(.bottom, 8)

                // Remaining sections with dividers
                ForEach(model.sections.dropFirst(), id: \.title) { section in
                    hairlineDivider
                        .padding(.vertical, 22)
                    narrativeParagraph(section.body)
                        .padding(.bottom, 8)
                }
            } else if !model.summary.isEmpty {
                // Fallback: render summary as single paragraph
                narrativeParagraph(model.summary)
                    .padding(.bottom, 8)
            }

            // Threads section
            let displayThreads = model.threads.isEmpty
                ? stubThreads
                : model.threads
            hairlineDivider.padding(.vertical, 22)
            v4ThreadsSection(threads: displayThreads)

            // Mentions section
            let displayMentions = model.mentions.isEmpty
                ? stubMentions
                : model.mentions
            hairlineDivider.padding(.vertical, 22)
            v4MentionsSection(mentions: displayMentions)
        }
        .padding(28)
        .liquidGlassCard(cornerRadius: 24, tone: .hi)
    }

    // Stub data used when compile output has no threads/mentions — TODO: remove once AI output format updated
    private var stubThreads: [DailyPageModel.ThreadEntry] {
        [
            DailyPageModel.ThreadEntry(label: "Daily reflection", color: DSColor.amberAccent),
            DailyPageModel.ThreadEntry(label: "Work notes", color: DSColor.amberDeep),
        ]
    }

    private var stubMentions: [String] {
        ["@today", "@log"]
    }

    // MARK: - Threads UI

    private func v4ThreadsSection(threads: [DailyPageModel.ThreadEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THREADS")
                .font(DSFonts.spaceGrotesk(size: 11, weight: .semibold))
                .foregroundColor(DSColor.inkMuted)
                .tracking(1.6)
                .textCase(.uppercase)

            ForEach(threads.indices, id: \.self) { i in
                let thread = threads[i]
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(thread.color)
                        .frame(width: 4, height: 24)
                    Text(thread.label)
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkPrimary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Mentions UI

    private func v4MentionsSection(mentions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MENTIONS")
                .font(DSFonts.spaceGrotesk(size: 11, weight: .semibold))
                .foregroundColor(DSColor.inkMuted)
                .tracking(1.6)
                .textCase(.uppercase)

            FlowLayout(spacing: 8) {
                ForEach(mentions, id: \.self) { mention in
                    Text(mention)
                        .font(DSFonts.inter(size: 12, weight: .medium))
                        .foregroundColor(DSColor.amberDeep)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DSColor.amberSoft)
                        .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(DSColor.glassRimD)
            .frame(maxWidth: .infinity)
            .frame(height: 0.5)
    }

    private func narrativeParagraph(_ body: String) -> some View {
        // Render-only polish: CJK/Latin spacing; does not modify vault file.
        Text(CJKTextPolish.polish(body))
            .font(DSType.serifBody16)
            .foregroundColor(DSColor.inkPrimary)
            .lineSpacing(8)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Header Section

    private func headerSection(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main date title — "APRIL 14" (month + day only, all caps)
            Text(dailyPageMonthDay(model.dateString))
                .displayLGStyle()
                .foregroundColor(DSColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.bottom, 4)

            // Weekday + year subtitle — "Sunday, 2026"
            Text(dailyPageWeekdayYear(model.dateString))
                .captionText()
                .foregroundColor(DSColor.onSurfaceVariant)
                .padding(.bottom, 24)

            // Summary with left border
            if !model.summary.isEmpty {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(DSColor.primary)
                        .frame(width: 2)
                    // Render-only polish: CJK/Latin spacing; does not modify vault file.
                    Text(CJKTextPolish.polish(model.summary))
                        .font(DSType.serifBody18)
                        .foregroundColor(DSColor.onSurface)
                        .lineSpacing(6)
                        .padding(.leading, 16)
                        .padding(.vertical, 4)
                }
                .padding(.bottom, 20)
            }

            // Metadata chips row
            HStack(spacing: 8) {
                metaChip("\(model.entriesCount) entries")
                metaChipLocations(model: model)
                metaChipVoice(model: model)
            }
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text.uppercased())
            .monoLabelStyle(size: 11)
            .foregroundColor(DSColor.onSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.surfaceContainer)
            .cornerRadius(0)
    }

    private func metaChipLocations(model: DailyPageModel) -> some View {
        let count = model.locations.count
        if count > 0 {
            return AnyView(metaChip("\(count) locations"))
        }
        return AnyView(EmptyView())
    }

    private func metaChipVoice(model: DailyPageModel) -> some View {
        let allAttachments = rawMemos.flatMap { $0.attachments }
        let audioAttachments = allAttachments.filter { $0.kind == "audio" }
        let durations = audioAttachments.compactMap { $0.duration }
        let totalSeconds: Double = durations.reduce(0, +)

        guard totalSeconds > 0 else { return AnyView(EmptyView()) }

        let t = Int(totalSeconds)
        let label = "🎙️ \(String(format: "%02d:%02d", t / 60, t % 60))"
        return AnyView(metaChip(label))
    }

    // MARK: - Narrative Section

    private func narrativeSection(_ section: DailyPageModel.PageSection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section heading with right horizontal line
            HStack(spacing: 16) {
                Text(section.title.uppercased())
                    .sectionLabelStyle()
                    .foregroundColor(DSColor.outline)
                Rectangle()
                    .fill(DSColor.outlineVariant)
                    .frame(height: 1)
            }

            // Render-only polish: CJK/Latin spacing applied before wikilink rendering; does not modify vault file.
            wikifiedText(CJKTextPolish.polish(section.body))
        }
    }

    // MARK: - Locations Section

    private func locationsSection(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PLACES TODAY")
                .sectionLabelStyle()
                .foregroundColor(DSColor.outline)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.locations, id: \.name) { loc in
                    HStack(alignment: .top, spacing: 12) {
                        if !loc.time.isEmpty {
                            Text(loc.time)
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.onPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(DSColor.primary)
                                .cornerRadius(0)
                        }
                        HStack(spacing: 0) {
                            WikilinkText(text: loc.name, onTap: {
                                let (type, slug) = resolveEntityTypeAndSlug(loc.name)
                                selectedEntityType = type
                                selectedEntitySlug = slug
                            })
                            if !loc.note.isEmpty {
                                Text(" — \(loc.note)")
                                    .bodySMStyle()
                                    .foregroundColor(DSColor.onSurfaceVariant)
                                    .italic()
                            }
                        }
                    }
                }
            }
            .padding(DSSpacing.cardInner)
            .background(DSColor.surfaceContainer)
            .cornerRadius(DSSpacing.radiusCard)
            .surfaceElevatedShadow()
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
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
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
        let dateParser = DateFormatter()
        dateParser.dateFormat = "yyyy-MM-dd"
        dateParser.locale = Locale(identifier: "en_US_POSIX")
        let date = dateParser.date(from: dateString) ?? Date()
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
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                InlineMicButton { transcript in freeformDraft = transcript }

                Button(action: { sendFreeform(compiledText: compiledText) }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(canSendFreeform ? DSColor.amberAccent : DSColor.inkSubtle)
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
            let dateParser = DateFormatter()
            dateParser.dateFormat = "yyyy-MM-dd"
            dateParser.locale = Locale(identifier: "en_US_POSIX")
            let date = dateParser.date(from: dateString) ?? Date()
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

    // MARK: - Wikilink Text Rendering

    /// 渲染字符串，将 [[slug]] 模式替换为可点击的琥珀色文本段。
    /// 点击 wikilink 时通过 sheet 导航到对应的 EntityPageView。
    @ViewBuilder
    private func wikifiedText(_ text: String) -> some View {
        WikilinkBodyText(text: text) { slug in
            let (type, _) = resolveEntityTypeAndSlug(slug)
            selectedEntityType = type
            selectedEntitySlug = slug
        }
    }

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
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date).uppercased()
    }

    private func dailyPageWeekdayYear(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
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
            } catch {
                DayPageLogger.shared.error("DailyPageView: load daily \(url.path) errno=\(errno): \(error)")
                model = nil
            }
        } else {
            DayPageLogger.shared.error("DailyPageView: daily file missing at \(url.path) errno=\(errno)")
            model = nil
        }

        // Load raw memos for Timeline Tab
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else {
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

// MARK: - DailyPageParser

/// 将 Daily Page 文件的 Markdown 内容解析为 DailyPageModel。
enum DailyPageParser {

    static func parse(content: String, dateString: String) -> DailyPageModel {
        let lines = content.components(separatedBy: "\n")

        // -- 解析 frontmatter --
        var summary = ""
        var locationPrimary = ""
        var entriesCount = 0
        var cover: String? = nil
        var inFrontmatter = false
        var closingFound = false
        var bodyStartIndex = 0

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i == 0 && trimmed == "---" { inFrontmatter = true; continue }
            if inFrontmatter && !closingFound && trimmed == "---" {
                closingFound = true
                bodyStartIndex = i + 1
                break
            }
            if inFrontmatter {
                if trimmed.hasPrefix("summary:") {
                    summary = String(trimmed.dropFirst("summary:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if trimmed.hasPrefix("location_primary:") {
                    locationPrimary = String(trimmed.dropFirst("location_primary:".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("entries_count:") {
                    let raw = String(trimmed.dropFirst("entries_count:".count)).trimmingCharacters(in: .whitespaces)
                    entriesCount = Int(raw) ?? 0
                } else if trimmed.hasPrefix("cover:") {
                    let raw = String(trimmed.dropFirst("cover:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !raw.isEmpty { cover = raw }
                }
            }
        }

        // 回退：如果 frontmatter 中没有封面，从当日 raw memo 中推导。
        let resolvedCover = cover ?? firstPhotoAttachmentPath(for: dateString)

        let bodyLines = Array(lines.dropFirst(bodyStartIndex))
        let bodyText = bodyLines.joined(separator: "\n")

        // -- 解析星期 --
        let weekday = weekdayString(from: dateString)

        // -- 解析叙事段落（## MORNING, ## AFTERNOON, ## EVENING 等） --
        var sections: [DailyPageModel.PageSection] = []
        let skipSections: Set<String> = ["LOCATIONS TODAY", "AI FOLLOW-UP"]
        var currentSectionTitle: String? = nil
        var currentSectionLines: [String] = []

        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if let title = currentSectionTitle {
                    let body = currentSectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty && !skipSections.contains(title) {
                        sections.append(DailyPageModel.PageSection(title: title, body: body))
                    }
                }
                currentSectionTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentSectionLines = []
            } else {
                currentSectionLines.append(line)
            }
        }
        // 最后一个段落
        if let title = currentSectionTitle {
            let body = currentSectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty && !skipSections.contains(title) {
                sections.append(DailyPageModel.PageSection(title: title, body: body))
            }
        }

        // -- 解析 LOCATIONS TODAY 段落 --
        let locations = parseLocations(from: bodyText)

        // -- 解析 AI FOLLOW-UP 段落（以 > 开头的行） --
        let followUpQuestions = parseFollowUpQuestions(from: bodyText)

        // TODO: Parse threads/mentions from compiled markdown when format is defined — follow-up issue.
        let threads = parseThreads(from: bodyText)
        let mentions = parseMentions(from: bodyText)

        return DailyPageModel(
            dateString: dateString,
            weekday: weekday,
            summary: summary,
            locationPrimary: locationPrimary,
            entriesCount: entriesCount,
            rawContent: content,
            sections: sections,
            locations: locations,
            followUpQuestions: followUpQuestions,
            memoCount: entriesCount,
            coverAssetPath: resolvedCover,
            threads: threads,
            mentions: mentions
        )
    }

    /// 扫描 vault/raw/YYYY-MM-DD.md，返回第一个照片附件的 vault 相对路径
    ///（优先使用文件名以 "cover-" 为前缀的附件）。
    /// 如果没有照片附件则返回 nil。
    private static func firstPhotoAttachmentPath(for dateString: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        guard let date = formatter.date(from: dateString) else { return nil }

        let memos: [Memo] = (try? RawStorage.read(for: date)) ?? []
        let photoAttachments = memos.flatMap { $0.attachments }.filter { $0.kind == "photo" }

        // 优先使用文件名以 "cover" 开头的附件（手动覆盖约定）。
        if let explicit = photoAttachments.first(where: {
            ($0.file as NSString).lastPathComponent.lowercased().hasPrefix("cover")
        }) {
            return explicit.file
        }
        return photoAttachments.first?.file
    }

    // MARK: - Helpers

    private static func weekdayString(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: dateString) else { return "" }
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        return weekdayFormatter.string(from: date)
    }

    private static func parseLocations(from body: String) -> [DailyPageModel.LocationEntry] {
        var results: [DailyPageModel.LocationEntry] = []
        var inLocations = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## LOCATIONS TODAY" { inLocations = true; continue }
            if trimmed.hasPrefix("## ") && inLocations { break }
            if inLocations && trimmed.hasPrefix("- ") {
                let raw = String(trimmed.dropFirst(2))
                // 格式：[[slug]]: note  或  [[slug]]
                let linkPattern = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)
                let nsRaw = raw as NSString
                var name = raw
                var note = ""

                if let match = linkPattern?.firstMatch(in: raw, range: NSRange(location: 0, length: nsRaw.length)),
                   let innerRange = Range(match.range(at: 1), in: raw) {
                    let inner = String(raw[innerRange])
                    name = inner.contains("|") ? String(inner.split(separator: "|").last ?? Substring(inner)) : inner.replacingOccurrences(of: "-", with: " ").capitalized
                    let afterLink = String(raw[Range(match.range, in: raw)!.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
                    note = afterLink.trimmingCharacters(in: .whitespaces)
                }

                results.append(DailyPageModel.LocationEntry(time: "", name: name, note: note))
            }
        }
        return results
    }

    private static func parseFollowUpQuestions(from body: String) -> [String] {
        var results: [String] = []
        var inFollowUp = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## AI FOLLOW-UP" { inFollowUp = true; continue }
            if trimmed.hasPrefix("## ") && inFollowUp { break }
            if inFollowUp && trimmed.hasPrefix("> ") {
                let question = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !question.isEmpty {
                    // 如果存在 "Question N: " 前缀则移除
                    let cleaned = question.replacingOccurrences(of: #"^Question \d+:\s*"#, with: "", options: .regularExpression)
                    results.append(cleaned)
                }
            }
        }
        return results
    }

    /// Parses ## THREADS section; falls back to stub data when section absent.
    private static func parseThreads(from body: String) -> [DailyPageModel.ThreadEntry] {
        let threadColors: [Color] = [
            DSColor.amberAccent,
            DSColor.amberDeep,
            Color(hex: "4C7A3F"),
            Color(hex: "3B6BA8"),
            DSColor.amberGlow
        ]
        var results: [DailyPageModel.ThreadEntry] = []
        var inSection = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## THREADS" { inSection = true; continue }
            if trimmed.hasPrefix("## ") && inSection { break }
            if inSection && trimmed.hasPrefix("- ") {
                let label = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    let color = threadColors[results.count % threadColors.count]
                    results.append(DailyPageModel.ThreadEntry(label: label, color: color))
                }
            }
        }
        return results
    }

    /// Parses ## MENTIONS section; falls back to empty when section absent.
    private static func parseMentions(from body: String) -> [String] {
        var results: [String] = []
        var inSection = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## MENTIONS" { inSection = true; continue }
            if trimmed.hasPrefix("## ") && inSection { break }
            if inSection && trimmed.hasPrefix("- ") {
                let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { results.append(name) }
            }
        }
        return results
    }
}

// MARK: - HeroBannerView

/// Daily Page 顶部的全宽 16:7 横幅。
/// 将 `coverAssetPath` 相对于 Vault 沙盒解析，并在加载时显示骨架屏。
/// 当没有照片或文件解码失败时，回退为几何占位图。
struct HeroBannerView: View {
    let coverAssetPath: String?

    @State private var image: UIImage? = nil
    @State private var loadFailed: Bool = false
    @State private var showPreview: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = width * 7.0 / 16.0
            ZStack {
                DSColor.surfaceContainer

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { showPreview = true }
                        .accessibilityLabel("Daily hero image")
                        .accessibilityAddTraits(.isImage)
                } else if coverAssetPath == nil || loadFailed {
                    placeholder
                } else {
                    skeleton
                }
            }
            .frame(width: width, height: height)
        }
        .aspectRatio(16.0 / 7.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .task(id: coverAssetPath) { await load() }
        .fullScreenCover(isPresented: $showPreview) {
            HeroBannerPreview(image: image) { showPreview = false }
        }
    }

    // MARK: - Placeholder

    /// 当日无照片时使用的单色几何占位图。
    private var placeholder: some View {
        ZStack {
            DSColor.surfaceContainer

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Rectangle()
                        .stroke(DSColor.onSurfaceVariant.opacity(0.35), lineWidth: 1)
                        .frame(width: w * 0.55, height: h * 0.6)
                        .offset(x: -w * 0.12, y: -h * 0.05)
                    Circle()
                        .stroke(DSColor.onSurfaceVariant.opacity(0.35), lineWidth: 1)
                        .frame(width: h * 0.5, height: h * 0.5)
                        .offset(x: w * 0.18, y: h * 0.08)
                }
                .frame(width: w, height: h)
            }

            VStack {
                Spacer()
                HStack {
                    Text("NO HERO IMAGE")
                        .monoLabelStyle(size: 10)
                        .kerning(2)
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DSColor.surfaceContainerHigh)
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    // MARK: - Skeleton

    /// 图片解码期间显示的中性无闪烁骨架屏。
    private var skeleton: some View {
        DSColor.surfaceContainerHigh
            .overlay(
                ProgressView()
                    .tint(DSColor.onSurfaceVariant)
            )
    }

    // MARK: - Loading

    private func load() async {
        image = nil
        loadFailed = false
        guard let relativePath = coverAssetPath, !relativePath.isEmpty else { return }

        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(relativePath)
        let path = fileURL.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            UIImage(contentsOfFile: path)
        }.value

        if let loaded {
            self.image = loaded
        } else {
            self.loadFailed = true
        }
    }
}

// MARK: - HeroBannerPreview

/// 点击横幅时呈现的全屏捏合缩放预览。
private struct HeroBannerPreview: View {
    let image: UIImage?
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @GestureState private var gestureScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = max(1.0, min(4.0, scale * value))
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1.0 ? 1.0 : 2.0
                        }
                    }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
        .onTapGesture { onDismiss() }
    }
}

// MARK: - DailyPageMetadataEditView

/// 用于编辑 Daily Page 元数据字段的 Sheet：摘要、天气、心情、封面图片。
/// 更改会原子性地写回已编译日记的 YAML front-matter 中。
struct DailyPageMetadataEditView: View {

    let dateString: String
    let currentSummary: String
    let currentWeather: String
    let currentMood: String
    let currentCoverPath: String?
    let rawMemos: [Memo]

    @Environment(\.dismiss) private var dismiss

    @State private var summary: String = ""
    @State private var weather: String = ""
    @State private var mood: String = ""
    @State private var selectedCoverPath: String? = nil
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var coverPreview: UIImage? = nil
    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    private let moodOptions = ["😊 开心", "😐 平静", "😔 低落", "😤 烦躁", "🤩 兴奋", "😴 疲惫"]

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        summarySection
                        moodSection
                        weatherSection
                        coverSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(DSColor.onSurface)
                }
                ToolbarItem(placement: .principal) {
                    Text("编辑元数据")
                        .headlineMDStyle()
                        .foregroundColor(DSColor.onSurface)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        ProgressView().tint(DSColor.onSurface).scaleEffect(0.8)
                    } else {
                        Button("保存") {
                            Task { await save() }
                        }
                        .foregroundColor(DSColor.primary)
                        .h2Style()
                    }
                }
            }
        }
        .onAppear {
            summary = currentSummary
            weather = currentWeather
            mood = currentMood
            selectedCoverPath = currentCoverPath
            if let path = currentCoverPath {
                loadCoverPreview(path: path)
            }
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: photosPickerItem) { newItem in
            guard let item = newItem else { return }
            Task { await loadSelectedPhoto(item: item) }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("SUMMARY")
            TextEditor(text: $summary)
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurface)
                .frame(minHeight: 80)
                .padding(12)
                .background(DSColor.surfaceContainer)
                .cornerRadius(0)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("MOOD")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(moodOptions, id: \.self) { option in
                        Button(action: {
                            mood = mood == option ? "" : option
                        }) {
                            Text(option)
                                .captionStyle()
                                .foregroundColor(mood == option ? DSColor.onPrimary : DSColor.onSurface)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(mood == option ? DSColor.primary : DSColor.surfaceContainer)
                                .cornerRadius(0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !mood.isEmpty && !moodOptions.contains(mood) {
                Text(mood)
                    .monoLabelStyle(size: 12)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.top, 4)
            }
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("WEATHER")
            TextField("例如：晴 28°C", text: $weather)
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurface)
                .padding(12)
                .background(DSColor.surfaceContainer)
                .cornerRadius(0)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("COVER IMAGE")

            if let preview = coverPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(0)
            }

            HStack(spacing: 12) {
                // Choose from existing raw memos photos
                Menu {
                    ForEach(photoAttachmentsFromMemos, id: \.file) { att in
                        Button(att.file.components(separatedBy: "/").last ?? att.file) {
                            selectedCoverPath = att.file
                            loadCoverPreview(path: att.file)
                        }
                    }
                    if selectedCoverPath != nil {
                        Divider()
                        Button("移除封面", role: .destructive) {
                            selectedCoverPath = nil
                            coverPreview = nil
                        }
                    }
                } label: {
                    Text(selectedCoverPath == nil ? "从记录中选择" : "更换封面")
                        .labelSMStyle()
                        .foregroundColor(DSColor.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DSColor.surfaceContainer)
                        .cornerRadius(0)
                        .overlay(Rectangle().stroke(DSColor.primary, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Pick from photo library
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    Text("从相册选择")
                        .labelSMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(DSColor.surfaceContainer)
                        .cornerRadius(0)
                        .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .sectionLabelStyle()
            .foregroundColor(DSColor.outline)
    }

    // MARK: - Data Helpers

    private var photoAttachmentsFromMemos: [Memo.Attachment] {
        rawMemos.flatMap { $0.attachments }.filter { $0.kind == "photo" }
    }

    private func loadCoverPreview(path: String) {
        let url = VaultInitializer.vaultURL.appendingPathComponent(path)
        Task.detached(priority: .userInitiated) {
            let img = UIImage(contentsOfFile: url.path)
            await MainActor.run { self.coverPreview = img }
        }
    }

    private func loadSelectedPhoto(item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }

        // Save to vault/raw/assets/
        let filename = "cover-\(dateString)-\(Int(Date().timeIntervalSince1970)).jpg"
        let assetsDir = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")
        let fileURL = assetsDir.appendingPathComponent(filename)

        do {
            if !FileManager.default.fileExists(atPath: assetsDir.path) {
                try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            }
            if let jpeg = img.jpegData(compressionQuality: 0.85) {
                try jpeg.write(to: fileURL)
            }
            selectedCoverPath = "raw/assets/\(filename)"
            coverPreview = img
        } catch {
            saveError = "保存封面图片失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let dailyURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        let content: String
        do { content = try String(contentsOf: dailyURL, encoding: .utf8) }
        catch { saveError = "无法读取日记文件"; DayPageLogger.shared.error("DailyPageView: read daily: \(error)"); return }

        let updated = updateFrontmatter(
            content: content,
            summary: summary,
            weather: weather,
            mood: mood,
            coverPath: selectedCoverPath
        )

        do {
            try RawStorage.atomicWrite(string: updated, to: dailyURL)
            dismiss()
        } catch {
            saveError = "写入失败: \(error.localizedDescription)"
        }
    }

    /// Updates YAML front-matter fields: summary, weather, mood, cover.
    /// Preserves all other fields and the body unchanged.
    private func updateFrontmatter(
        content: String,
        summary: String,
        weather: String,
        mood: String,
        coverPath: String?
    ) -> String {
        var lines = content.components(separatedBy: "\n")

        // Find front-matter bounds
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return content
        }

        var closingLine = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingLine = i
                break
            }
        }
        guard closingLine > 0 else { return content }

        // Update existing keys or insert before closing ---
        func setKey(_ key: String, value: String) {
            let prefix = "\(key):"
            if let idx = (1..<closingLine).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) {
                if value.isEmpty {
                    lines.remove(at: idx)
                    closingLine -= 1
                } else {
                    lines[idx] = "\(key): \(value)"
                }
            } else if !value.isEmpty {
                lines.insert("\(key): \(value)", at: closingLine)
                closingLine += 1
            }
        }

        setKey("summary", value: summary.isEmpty ? "" : "\"\(summary.replacingOccurrences(of: "\"", with: "\\\""))\"")
        setKey("weather", value: weather)
        setKey("mood", value: mood)
        setKey("cover", value: coverPath ?? "")

        return lines.joined(separator: "\n")
    }
}
