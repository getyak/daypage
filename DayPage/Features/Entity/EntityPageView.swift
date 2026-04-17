import SwiftUI

// MARK: - EntityPageView

/// Renders an Entity Page (place, person, or theme) from vault/wiki/{type}/{slug}.md.
///
/// - Displays frontmatter metadata (type, first_seen, occurrence_count)
/// - Renders Markdown body with [[wikilink]] highlighting
/// - Shows "该实体页尚未生成" for unknown slugs
struct EntityPageView: View {

    let entityType: String  // "places", "people", or "themes"
    let entitySlug: String
    /// When presented from a Daily Page, pass the dateString to show a breadcrumb.
    var sourceDateString: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var model: EntityModel? = nil
    @State private var notFound: Bool = false
    @State private var selectedDate: String? = nil
    @State private var selectedEntitySlug: String? = nil
    @State private var selectedEntityType: String = "themes"

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

                if notFound {
                    notFoundView
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
                        }
                    }
                } else {
                    ProgressView()
                        .tint(DSColor.onSurfaceVariant)
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

    // MARK: - Not Found

    private var notFoundView: some View {
        VStack(spacing: 16) {
            Text("该实体页尚未生成")
                .bodyMDStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
            Text("[[" + entitySlug + "]]")
                .monoLabelStyle(size: 11)
                .foregroundColor(DSColor.amberArchival)
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

    // MARK: - Related Memos (stub for MVP)

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

            if model.relatedDates.isEmpty {
                Text("暂无关联记录")
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
            } else {
                ForEach(model.relatedDates, id: \.self) { dateStr in
                    Button(action: { selectedDate = dateStr }) {
                        HStack {
                            Text(dateStr)
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

    // MARK: - Wikilink Text

    @ViewBuilder
    private func wikifiedText(_ text: String) -> some View {
        WikilinkBodyText(text: text) { inner in
            let (type, slug) = resolveEntityTypeAndSlug(inner)
            selectedEntityType = type
            selectedEntitySlug = slug
        }
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
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent(entityType)
            .appendingPathComponent("\(entitySlug).md")

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            notFound = true
            return
        }

        model = EntityPageParser.parse(content: content, slug: entitySlug)
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
