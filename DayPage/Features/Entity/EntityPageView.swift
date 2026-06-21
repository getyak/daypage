import SwiftUI

// MARK: - EntityPageView

/// Renders an Entity Page (place, person, or theme) from vault/wiki/{type}/{slug}.md.
///
/// - Displays frontmatter metadata (type, first_seen, occurrence_count)
/// - Renders Markdown body with [[wikilink]] highlighting
/// - Shows a "page not generated yet" placeholder for unknown slugs
struct EntityPageView: View {

    let entityType: String  // "places", "people", or "themes"
    let entitySlug: String
    /// When presented from a Daily Page, pass the dateString to show a breadcrumb.
    var sourceDateString: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: EntityModel? = nil
    @State private var notFound: Bool = false
    @State private var notFoundReason: NotFoundReason = .neverMentioned
    @State private var selectedDate: String? = nil
    @State private var selectedEntitySlug: String? = nil
    @State private var selectedEntityType: String = "themes"
    /// Memos from raw vault files that mention this entity slug.
    @State private var linkedMemos: [(dateStr: String, memo: Memo)] = []
    @State private var skeletonBreathe = false
    /// Tracks the in-flight load+scan so re-appearances cancel stale work.
    @State private var scanTask: Task<Void, Never>? = nil
    /// True while the background scan is enumerating vault/raw — used to show
    /// a shimmer/spinner in the RELATED ENTRIES section instead of "empty".
    @State private var isScanningRelated: Bool = true
    /// When false, the backlinks section caps at 10 rows with a "查看更多" CTA.
    /// Tapping the CTA flips this to true so the rest of `linkedMemos` reveals.
    @State private var backlinksExpanded: Bool = false

    // MARK: - NotFoundReason

    /// Three states that the entity-not-found placeholder must distinguish so
    /// the empty state can guide the user toward the right next action.
    /// - neverMentioned: entity slug is absent from any vault/raw memo
    /// - pendingCompilation: slug appears in raw memos but tonight's 02:00
    ///   compilation hasn't run yet → page will exist tomorrow
    /// - compilationFailed: daily page exists but the entity page is missing
    ///   → next app launch retries compilation
    enum NotFoundReason {
        case neverMentioned
        case pendingCompilation
        case compilationFailed
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

                if notFound {
                    notFoundView(reason: notFoundReason)
                } else if let model {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            entityHeader(model: model)
                                .padding(.horizontal, 20)
                                .padding(.top, 24)
                                .padding(.bottom, 32)

                            entityBody(model: model)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 40)

                            relatedMemos(model: model)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 40)

                            backlinksSection
                                .padding(.horizontal, 20)
                                .padding(.bottom, 40)
                        }
                    }
                } else {
                    entitySkeleton
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let src = sourceDateString {
                        Button(action: { dismiss() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 13, weight: .medium))
                                Text(src)
                                    .font(.custom("JetBrainsMono-Regular", fixedSize: 11))
                                    .kerning(0.5)
                            }
                            .foregroundColor(DSColor.primary)
                        }
                    } else {
                        Button(action: { dismiss() }) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(DSColor.onSurface)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(entitySlug.uppercased())
                        .monoLabelStyle(size: 11)
                        .foregroundColor(DSColor.onSurface)
                }
            }
        }
        .onAppear { loadEntity() }
        .onDisappear {
            // Cancel any in-flight scan so a quick dismiss/re-open doesn't
            // pile up detached tasks racing on @MainActor writes.
            scanTask?.cancel()
            scanTask = nil
        }
        .sheet(isPresented: Binding(
            get: { selectedDate != nil },
            set: { if !$0 { selectedDate = nil } }
        )) {
            if let dateStr = selectedDate {
                DailyPageView(dateString: dateStr)
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedEntitySlug != nil },
            set: { if !$0 { selectedEntitySlug = nil } }
        )) {
            if let slug = selectedEntitySlug {
                EntityPageView(entityType: selectedEntityType, entitySlug: slug)
            }
        }
    }

    // MARK: - Skeleton

    @ViewBuilder
    private var entitySkeleton: some View {
        let opacity = reduceMotion ? 1.0 : (skeletonBreathe ? 0.45 : 0.25)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Badge chip
                Capsule()
                    .fill(DSColor.glassStd)
                    .frame(width: 60, height: 18)

                // Title bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(DSColor.glassStd)
                    .frame(maxWidth: .infinity * 0.7)
                    .frame(width: UIScreen.main.bounds.width * 0.7 - 40, height: 32)

                // Two mock sections
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        // Section label rule
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(DSColor.glassStd)
                                .frame(width: 80, height: 11)
                            Rectangle()
                                .fill(DSColor.inkFaint)
                                .frame(height: 1)
                        }
                        // Body lines at 94 / 80 / 55 %
                        ForEach([0.94, 0.80, 0.55], id: \.self) { frac in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DSColor.glassStd)
                                .frame(width: (UIScreen.main.bounds.width - 40) * frac, height: 14)
                        }
                    }
                }

                // Two related-entry row rectangles
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DSColor.glassStd)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .opacity(opacity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                skeletonBreathe = true
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Not Found

    private func notFoundView(reason: NotFoundReason) -> some View {
        VStack(spacing: 16) {
            Text(notFoundMessage(reason: reason))
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("[[" + entitySlug + "]]")
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.amberArchival)
        }
    }

    private func notFoundMessage(reason: NotFoundReason) -> String {
        switch reason {
        case .neverMentioned:
            return "「\(entitySlug)」从未在你的日记里出现过"
        case .pendingCompilation:
            return "「\(entitySlug)」会在今晚 02:00 编译后生成实体页"
        case .compilationFailed:
            return "编译失败，下次打开 App 时会自动重试"
        }
    }

    // MARK: - Entity Header

    private func entityHeader(model: EntityModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Type badge
            Text(entityTypeBadge.uppercased())
                .monoLabelStyle(size: 9)
                .foregroundColor(DSColor.onPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DSColor.primary)
                .cornerRadius(0)

            // Name
            Text(model.name.uppercased())
                .font(.custom("SpaceGrotesk-Bold", size: 32).leading(.tight))
                .foregroundColor(DSColor.primary)
                .lineLimit(3)
                .minimumScaleFactor(0.7)

            // Metadata chips
            HStack(spacing: 8) {
                if !model.firstSeen.isEmpty {
                    metaChip("First seen: \(model.firstSeen)")
                }
                if model.occurrenceCount > 0 {
                    metaChip("\(model.occurrenceCount)x")
                }
            }
        }
    }

    private var entityTypeBadge: String {
        switch entityType {
        case "places": return "Place"
        case "people": return "Person"
        case "themes": return "Theme"
        default: return entityType
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .monoLabelStyle(size: 10)
            .foregroundColor(DSColor.onSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DSColor.surfaceContainer)
            .cornerRadius(0)
    }

    // MARK: - Entity Body

    private func entityBody(model: EntityModel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(model.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 12) {
                    // Section heading with right line
                    HStack(spacing: 16) {
                        Text(section.title.uppercased())
                            .font(.custom("SpaceGrotesk-Bold", size: 11))
                            .foregroundColor(DSColor.outline)
                            .kerning(3)
                        Rectangle()
                            .fill(DSColor.outlineVariant)
                            .frame(height: 1)
                    }

                    wikifiedText(section.body)
                }
            }
        }
    }

    // MARK: - Related Memos (entity → memos bidirectional link)

    private func relatedMemos(model: EntityModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("RELATED ENTRIES")
                    .font(.custom("SpaceGrotesk-Bold", size: 11))
                    .foregroundColor(DSColor.outline)
                    .kerning(3)
                Rectangle()
                    .fill(DSColor.outlineVariant)
                    .frame(height: 1)
            }

            if isScanningRelated && linkedMemos.isEmpty && model.relatedDates.isEmpty {
                // Background scan of vault/raw is still running. Show a small
                // inline spinner so users distinguish "scanning" from "empty".
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                    Text("正在扫描关联记录…")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
                .padding(.vertical, 8)
            } else if linkedMemos.isEmpty && model.relatedDates.isEmpty {
                Text("暂无关联记录")
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
            } else if !linkedMemos.isEmpty {
                // Show individual memo snippets with navigation
                ForEach(linkedMemos.indices, id: \.self) { idx in
                    let item = linkedMemos[idx]
                    Button(action: { Haptics.tapConfirm(); selectedDate = item.dateStr }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(relativeDateLabel(item.dateStr))
                                .monoLabelStyle(size: 9)
                                .foregroundColor(DSColor.onSurfaceVariant)
                            let preview = item.memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !preview.isEmpty {
                                Text(preview)
                                    .font(.custom("SourceSerif4-Regular", size: 14))
                                    .foregroundColor(DSColor.onSurface)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            } else {
                                Text("[\(item.memo.type.rawValue)]")
                                    .monoLabelStyle(size: 10)
                                    .foregroundColor(DSColor.onSurfaceVariant)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(DSColor.surfaceContainer)
                        .cornerRadius(0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(relativeDateLabel(item.dateStr)): \(item.memo.body.prefix(80))")
                }
            } else {
                // Fallback: daily page dates only (entity mentioned in compiled page but not raw)
                ForEach(model.relatedDates, id: \.self) { dateStr in
                    Button(action: { Haptics.tapConfirm(); selectedDate = dateStr }) {
                        HStack {
                            Text(relativeDateLabel(dateStr))
                                .monoLabelStyle(size: 11)
                                .foregroundColor(DSColor.onSurface)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(DSColor.surfaceContainer)
                        .cornerRadius(0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Backlinks (📌 被 N 个 memo 引用)

    /// New section showing raw-memo backlinks for this entity. Distinct from
    /// "RELATED ENTRIES" above: that section navigates to DailyPageView via a
    /// sheet; this one routes back to ArchiveView so the user can scroll the
    /// timeline at that date. Empty state hides the entire section.
    @ViewBuilder
    private var backlinksSection: some View {
        if isScanningRelated && linkedMemos.isEmpty {
            // Loading state: reuse the same "scanning" copy as RELATED ENTRIES so
            // the user doesn't see a flash-of-empty-section while the background
            // scan is still walking vault/raw.
            VStack(alignment: .leading, spacing: 12) {
                backlinksHeader(count: 0)
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                    Text("正在扫描关联记录…")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
                .padding(.vertical, 8)
            }
        } else if !linkedMemos.isEmpty {
            let total = linkedMemos.count
            let visibleCount = backlinksExpanded ? total : min(10, total)
            VStack(alignment: .leading, spacing: 0) {
                backlinksHeader(count: total)
                    .padding(.bottom, 12)

                ForEach(0..<visibleCount, id: \.self) { idx in
                    backlinkRow(linkedMemos[idx])
                    if idx < visibleCount - 1 {
                        Rectangle()
                            .fill(DSColor.glassEdge)
                            .frame(height: 0.5)
                    }
                }

                if !backlinksExpanded && total > 10 {
                    Button {
                        Haptics.soft()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            backlinksExpanded = true
                        }
                    } label: {
                        HStack {
                            Text("查看更多 (\(total - 10))")
                                .font(DSType.bodyMD)
                                .foregroundColor(DSColor.amberArchival)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11))
                                .foregroundColor(DSColor.amberArchival)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看更多 \(total - 10) 条引用")
                }
            }
        }
        // Empty (!isScanningRelated && linkedMemos.isEmpty) → render nothing.
    }

    private func backlinksHeader(count: Int) -> some View {
        // "📌 被 N 个 memo 引用" — count = total linkedMemos (not the visible
        // window) so the header always reflects the full backlink fan-in.
        HStack(spacing: 16) {
            Text("📌 被 \(count) 个 memo 引用")
                .font(.custom("SpaceGrotesk-Bold", size: 11))
                .foregroundColor(DSColor.outline)
                .kerning(2)
            Rectangle()
                .fill(DSColor.outlineVariant)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func backlinkRow(_ item: (dateStr: String, memo: Memo)) -> some View {
        Button {
            Haptics.tapConfirm()
            // Two-step nav: dismiss this sheet first, then route to Archive.
            // EntityPageView is presented from several entry points (Graph,
            // DailyPage, recursive Entity) where the nav environment object
            // is not consistently available, so we go through Notification
            // instead of @EnvironmentObject. DayPageApp observes the
            // notification and calls navModel.openArchive(at:).
            let dateStr = item.dateStr
            dismiss()
            // Defer the post by one runloop so SwiftUI's dismiss animation
            // doesn't race with ArchiveView's onChange(of: pendingArchiveDate).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                NotificationCenter.default.post(
                    name: .openArchiveAt,
                    object: nil,
                    userInfo: ["date": dateStr]
                )
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.dateStr)
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Text(backlinkSnippet(item.memo))
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.dateStr): \(backlinkSnippet(item.memo))")
        .accessibilityHint("跳转到归档查看该日期")
    }

    /// First non-empty line of the memo body, truncated to 60 chars.
    /// Falls back to a typed placeholder (e.g. "[voice]") when the body
    /// is empty — those memos exist when the user records audio without
    /// adding text.
    private func backlinkSnippet(_ memo: Memo) -> String {
        let trimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "[\(memo.type.rawValue)]" }
        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
        if firstLine.count <= 60 { return firstLine }
        return String(firstLine.prefix(60)) + "…"
    }

    // MARK: - Wikilink Text

    @ViewBuilder
    private func wikifiedText(_ text: String) -> some View {
        WikilinkBodyText(text: text) { inner in
            let (type, slug) = resolveEntityTypeAndSlug(inner)
            selectedEntityType = type
            selectedEntitySlug = slug
        }
    }

    private func relativeDateLabel(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let daysDiff = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if daysDiff > 0 && daysDiff < 7 { return "\(daysDiff) DAYS AGO" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date).uppercased()
    }

    /// Resolves entity type from slug by scanning wiki directories.
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

    private func loadEntity() {
        // Cancel any stale work from a previous appearance before starting
        // a new scan — keeps @MainActor writes serialised.
        scanTask?.cancel()

        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent(entityType)
            .appendingPathComponent("\(entitySlug).md")
        let slug = entitySlug
        let vaultURL = VaultInitializer.vaultURL
        let rawDir = vaultURL.appendingPathComponent("raw")
        let dailyDir = vaultURL.appendingPathComponent("daily")

        isScanningRelated = true

        scanTask = Task.detached(priority: .userInitiated) {
            let rawContent: String?
            do { rawContent = try String(contentsOf: url, encoding: .utf8) }
            catch { rawContent = nil }

            // Even on the not-found path we want backlink-aware reason
            // classification, so scan first regardless of wiki file presence.
            if Task.isCancelled { return }
            let memoLinks = Self.scanRawMemosWithContent(in: rawDir, mentioning: slug)
            if Task.isCancelled { return }

            guard let rawContent else {
                // Decide WHY the wiki file is missing so the placeholder copy
                // matches the user's actual situation (#R2-MEDIUM).
                let reason = Self.classifyNotFound(
                    slug: slug,
                    memoLinks: memoLinks,
                    dailyDir: dailyDir
                )
                await MainActor.run {
                    self.notFoundReason = reason
                    self.notFound = true
                    self.isScanningRelated = false
                }
                return
            }

            var parsed = EntityPageParser.parse(content: rawContent, slug: slug)

            let backlinkedDates = memoLinks.map { $0.dateStr }
            if !backlinkedDates.isEmpty {
                let merged = Array(Set(parsed.relatedDates + backlinkedDates)).sorted(by: >)
                parsed = EntityModel(
                    name: parsed.name,
                    entityType: parsed.entityType,
                    firstSeen: parsed.firstSeen,
                    occurrenceCount: parsed.occurrenceCount,
                    sections: parsed.sections,
                    relatedDates: merged
                )
            }

            if Task.isCancelled { return }
            await MainActor.run {
                self.model = parsed
                self.linkedMemos = memoLinks
                self.isScanningRelated = false
            }
        }
    }

    /// Classifies the not-found state into one of three user-facing reasons.
    /// - If no raw memo mentions the slug → `neverMentioned`
    /// - Else if no daily.md exists for any backlinked date → `pendingCompilation`
    /// - Else (daily exists but no wiki page was produced) → `compilationFailed`
    private static func classifyNotFound(
        slug: String,
        memoLinks: [(dateStr: String, memo: Memo)],
        dailyDir: URL
    ) -> NotFoundReason {
        if memoLinks.isEmpty {
            return .neverMentioned
        }
        let fm = FileManager.default
        // Backlinks exist. If at least one backlinked day has been compiled
        // into daily/ but still no entity page → compilation produced an
        // incomplete graph → failed. Otherwise compilation simply hasn't
        // run yet for those days → pending.
        let dailyExistsForAny = memoLinks.contains { link in
            let url = dailyDir.appendingPathComponent("\(link.dateStr).md")
            return fm.fileExists(atPath: url.path)
        }
        return dailyExistsForAny ? .compilationFailed : .pendingCompilation
    }

    /// Scans all `vault/raw/YYYY-MM-DD.md` files and returns (dateStr, Memo) pairs
    /// for each memo that mentions `slug` (bare or inside a wikilink).
    /// Sorted newest-first. Provides the data for bidirectional entity → memo links.
    private static func scanRawMemosWithContent(in rawDir: URL, mentioning slug: String) -> [(dateStr: String, memo: Memo)] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: rawDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        let datePattern = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        var found: [(dateStr: String, memo: Memo)] = []

        for item in items {
            guard item.pathExtension == "md" else { continue }
            let dateStr = item.deletingPathExtension().lastPathComponent
            guard let pat = datePattern,
                  pat.firstMatch(in: dateStr, range: NSRange(location: 0, length: (dateStr as NSString).length)) != nil
            else { continue }
            guard let content = try? String(contentsOf: item, encoding: .utf8) else { continue }
            // Match both bare [[slug]] and [[wiki/type/slug|Name]] forms
            guard content.contains(slug) else { continue }
            let memos = RawStorage.parse(fileContent: content)
            for memo in memos {
                let body = memo.body
                if body.contains(slug) || body.contains("[[\(slug)]]") {
                    found.append((dateStr: dateStr, memo: memo))
                }
            }
        }
        return found.sorted { $0.dateStr > $1.dateStr }
    }
}

// MARK: - EntityModel

struct EntityModel {
    let name: String
    let entityType: String
    let firstSeen: String
    let occurrenceCount: Int
    let sections: [EntitySection]
    let relatedDates: [String]

    struct EntitySection {
        let title: String
        let body: String
    }
}

// MARK: - EntityPageParser

enum EntityPageParser {

    static func parse(content: String, slug: String) -> EntityModel {
        let lines = content.components(separatedBy: "\n")

        var name = slug.replacingOccurrences(of: "-", with: " ").capitalized
        var entityType = ""
        var firstSeen = ""
        var occurrenceCount = 0
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
                if trimmed.hasPrefix("name:") {
                    name = String(trimmed.dropFirst("name:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if trimmed.hasPrefix("type:") {
                    entityType = String(trimmed.dropFirst("type:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("first_seen:") {
                    firstSeen = String(trimmed.dropFirst("first_seen:".count)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("occurrence_count:") {
                    let raw = String(trimmed.dropFirst("occurrence_count:".count)).trimmingCharacters(in: .whitespaces)
                    occurrenceCount = Int(raw) ?? 0
                }
            }
        }

        let bodyLines = Array(lines.dropFirst(bodyStartIndex))
        var sections: [EntityModel.EntitySection] = []
        var currentTitle: String? = nil
        var currentLines: [String] = []

        // Skip the top-level # heading and ** metadata lines
        let skipPrefixes = ["# ", "**Type", "**First seen"]

        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if let title = currentTitle {
                    let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { sections.append(EntityModel.EntitySection(title: title, body: body)) }
                }
                currentTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else if !skipPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                currentLines.append(line)
            }
        }
        if let title = currentTitle {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(EntityModel.EntitySection(title: title, body: body)) }
        }

        // Extract related dates from section content (lines starting with "- YYYY-MM-DD")
        var relatedDates: [String] = []
        let datePattern = try? NSRegularExpression(pattern: #"^- (\d{4}-\d{2}-\d{2})"#)
        for section in sections {
            for line in section.body.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let match = datePattern?.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
                   let range = Range(match.range(at: 1), in: trimmed) {
                    let dateStr = String(trimmed[range])
                    if !relatedDates.contains(dateStr) { relatedDates.append(dateStr) }
                }
            }
        }
        relatedDates.sort(by: >)

        return EntityModel(
            name: name,
            entityType: entityType,
            firstSeen: firstSeen,
            occurrenceCount: occurrenceCount,
            sections: sections,
            relatedDates: relatedDates
        )
    }
}
