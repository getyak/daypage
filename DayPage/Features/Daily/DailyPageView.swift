import SwiftUI
import UIKit
import PhotosUI

// MARK: - DailyPageTab

enum DailyPageTab: String, CaseIterable {
    case digest = "DIGEST"
    case timeline = "TIMELINE"
}

// MARK: - DailyPageModel

/// Parsed model for a Daily Page Markdown file.
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
    /// Vault-relative path to the hero banner image (e.g. "raw/assets/photo_...jpg").
    /// Nil when no photo is available for this day.
    let coverAssetPath: String?

    struct PageSection {
        let title: String
        let body: String
    }

    struct LocationEntry {
        let time: String
        let name: String
        let note: String
    }
}

// MARK: - DailyPageView

/// Renders a compiled Daily Page from vault/wiki/daily/YYYY-MM-DD.md.
struct DailyPageView: View {

    let dateString: String
    var onReturnToToday: ((String) -> Void)? = nil  // Called with pre-fill text when tapping a follow-up question

    @Environment(\.dismiss) private var dismiss
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
                    }
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
                    Text("DAYPAGE_PROTOCOL")
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

    // MARK: - Digest Content

    @ViewBuilder
    private func digestContent(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date header
            headerSection(model: model)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

            // Hero banner (16:7 asset) — full-bleed, no horizontal padding
            HeroBannerView(coverAssetPath: model.coverAssetPath)
                .padding(.bottom, 32)

            // Narrative sections
            ForEach(model.sections, id: \.title) { section in
                narrativeSection(section)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }

            // Locations Today
            if !model.locations.isEmpty {
                locationsSection(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }

            // AI Follow-up Threads
            if !model.followUpQuestions.isEmpty {
                threadsSection(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
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
            // Main date title — Space Grotesk 56px uppercase
            Text(model.dateString.uppercased())
                .displayLGStyle()
                .foregroundColor(DSColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.bottom, 4)

            // Weekday subtitle
            Text(model.weekday.uppercased())
                .monoLabelStyle(size: 13)
                .foregroundColor(DSColor.onSurfaceVariant)
                .padding(.bottom, 24)

            // Summary with left border
            if !model.summary.isEmpty {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(DSColor.primary)
                        .frame(width: 2)
                    Text(model.summary)
                        .titleSMStyle()
                        .foregroundColor(DSColor.onSurface)
                        .lineSpacing(4)
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

            // Body text with wikilink rendering
            wikifiedText(section.body)
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
            .padding(20)
            .background(DSColor.surfaceContainer)
            .cornerRadius(0)
        }
    }

    // MARK: - Threads (AI Follow-up)

    private func threadsSection(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("THREADS")
                .sectionLabelStyle()
                .foregroundColor(DSColor.outline)

            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.followUpQuestions, id: \.self) { question in
                    Button(action: {
                        dismiss()
                        onReturnToToday?(question)
                    }) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(question)
                                .bodySMStyle()
                                .foregroundColor(DSColor.onSurface)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 4) {
                                Text("CONTINUE")
                                    .monoLabelStyle(size: 10)
                                    .foregroundColor(DSColor.amberArchival)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(DSColor.amberArchival)
                            }
                        }
                        .padding(16)
                        .background(DSColor.surfaceContainerHigh)
                        .cornerRadius(0)
                    }
                    .buttonStyle(.plain)
                }
            }
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

    /// Renders a string replacing [[slug]] patterns with tappable amber-colored spans.
    /// Tapping a wikilink navigates to the corresponding EntityPageView via sheet.
    @ViewBuilder
    private func wikifiedText(_ text: String) -> some View {
        WikilinkBodyText(text: text) { slug in
            let (type, _) = resolveEntityTypeAndSlug(slug)
            selectedEntityType = type
            selectedEntitySlug = slug
        }
    }

    /// Resolves entity type from slug by scanning wiki directories.
    /// Falls back to "themes" if not found (creates empty entity page on first tap).
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

    // MARK: - Load

    private func loadPage() {
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            rawText = content
            model = DailyPageParser.parse(content: content, dateString: dateString)
        } catch {
            DayPageLogger.shared.error("DailyPageView: load daily: \(error)")
        }

        // Load raw memos for Timeline Tab
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        let date = parser.date(from: dateString) ?? Date()
        let loaded: [Memo]
        do { loaded = try RawStorage.read(for: date) }
        catch { loaded = []; DayPageLogger.shared.error("DailyPageView: load memos: \(error)") }
        rawMemos = loaded.sorted { $0.created < $1.created }
    }
}

// MARK: - DailyPageParser

/// Parses the Markdown content of a Daily Page file into a DailyPageModel.
enum DailyPageParser {

    static func parse(content: String, dateString: String) -> DailyPageModel {
        let lines = content.components(separatedBy: "\n")

        // -- Parse frontmatter --
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

        // Fallback: derive cover from the day's raw memos if frontmatter has none.
        let resolvedCover = cover ?? firstPhotoAttachmentPath(for: dateString)

        let bodyLines = Array(lines.dropFirst(bodyStartIndex))
        let bodyText = bodyLines.joined(separator: "\n")

        // -- Parse weekday --
        let weekday = weekdayString(from: dateString)

        // -- Parse narrative sections (## MORNING, ## AFTERNOON, ## EVENING etc.) --
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
        // Last section
        if let title = currentSectionTitle {
            let body = currentSectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty && !skipSections.contains(title) {
                sections.append(DailyPageModel.PageSection(title: title, body: body))
            }
        }

        // -- Parse LOCATIONS TODAY section --
        let locations = parseLocations(from: bodyText)

        // -- Parse AI FOLLOW-UP section (lines starting with >) --
        let followUpQuestions = parseFollowUpQuestions(from: bodyText)

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
            coverAssetPath: resolvedCover
        )
    }

    /// Scans vault/raw/YYYY-MM-DD.md and returns the vault-relative path of the first
    /// photo attachment (preferring any attachment file with a "cover-*" prefix if present).
    /// Returns nil if no photos are attached.
    private static func firstPhotoAttachmentPath(for dateString: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        guard let date = formatter.date(from: dateString) else { return nil }

        let memos: [Memo] = (try? RawStorage.read(for: date)) ?? []
        let photoAttachments = memos.flatMap { $0.attachments }.filter { $0.kind == "photo" }

        // Prefer an attachment whose filename starts with "cover" (manual override convention).
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
                // Format: [[slug]]: note  or  [[slug]]
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
                    // Remove "Question N: " prefix if present
                    let cleaned = question.replacingOccurrences(of: #"^Question \d+:\s*"#, with: "", options: .regularExpression)
                    results.append(cleaned)
                }
            }
        }
        return results
    }
}

// MARK: - HeroBannerView

/// Full-bleed 16:7 banner rendered at the top of a Daily Page.
/// Resolves `coverAssetPath` against the Vault sandbox and shows a skeleton
/// while loading. Falls back to a geometric placeholder when no photo is available
/// or the file fails to decode.
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

    /// Monochrome geometric placeholder used when no photo exists for the day.
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

    /// Neutral shimmer-free skeleton shown while the image decodes.
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

/// Full-screen pinch-to-zoom preview presented when tapping the banner.
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

/// Sheet for editing Daily Page metadata fields: summary, weather, mood, cover image.
/// Changes are atomically written back into the YAML front-matter of the compiled daily page.
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
