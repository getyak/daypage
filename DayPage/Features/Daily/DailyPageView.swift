import SwiftUI

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
            }
        }
        .onAppear { loadPage() }
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

    // MARK: - Timeline Content (simple raw view for MVP)

    @ViewBuilder
    private func timelineContent(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Show raw Markdown with wiki link highlighting
            wikifiedText(rawText)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Header Section

    private func headerSection(model: DailyPageModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main date title — Space Grotesk 56px uppercase
            Text(model.dateString.uppercased())
                .font(.custom("SpaceGrotesk-Bold", size: 56).leading(.tight))
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
                        .font(.custom("Inter-Regular", size: 18))
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
        // Count audio attachments from raw file for voice minutes
        // For MVP: show nothing if no voice info in front matter
        return AnyView(EmptyView())
    }

    // MARK: - Narrative Section

    private func narrativeSection(_ section: DailyPageModel.PageSection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section heading with right horizontal line
            HStack(spacing: 16) {
                Text(section.title.uppercased())
                    .font(.custom("SpaceGrotesk-Bold", size: 11))
                    .foregroundColor(DSColor.outline)
                    .kerning(3)
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
                .font(.custom("SpaceGrotesk-Bold", size: 11))
                .foregroundColor(DSColor.outline)
                .kerning(3)

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
                            WikilinkText(text: loc.name, onTap: nil)
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
                .font(.custom("SpaceGrotesk-Bold", size: 11))
                .foregroundColor(DSColor.outline)
                .kerning(3)

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

    /// Renders a string replacing [[slug]] patterns with amber-colored inline spans.
    /// Tapping a wikilink navigates to the EntityPageView (stub for MVP).
    @ViewBuilder
    private func wikifiedText(_ text: String) -> some View {
        let attributed = buildAttributedString(text)
        Text(attributed)
            .bodyMDStyle()
            .foregroundColor(DSColor.onSurface)
            .lineSpacing(3)
    }

    private func buildAttributedString(_ text: String) -> AttributedString {
        var result = AttributedString()

        // Pattern: [[slug]] or [[slug|Display Name]]
        let pattern = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = pattern?.matches(in: text, range: range) ?? []

        var lastEnd = text.startIndex

        for match in matches {
            let matchRange = Range(match.range, in: text)!
            let innerRange = Range(match.range(at: 1), in: text)!
            let inner = String(text[innerRange])

            // Append text before this match
            let before = String(text[lastEnd ..< matchRange.lowerBound])
            if !before.isEmpty {
                result.append(AttributedString(before))
            }

            // Determine display name
            let displayName: String
            if inner.contains("|") {
                displayName = String(inner.split(separator: "|", maxSplits: 1).last ?? Substring(inner))
            } else {
                displayName = inner.replacingOccurrences(of: "-", with: " ").capitalized
            }

            // Wikilink span
            var linkStr = AttributedString("[[" + displayName + "]]")
            linkStr.foregroundColor = DSColor.amberArchival
            linkStr.font = .custom("Inter-Medium", size: 15)
            result.append(linkStr)

            lastEnd = matchRange.upperBound
        }

        // Append remaining text
        let tail = String(text[lastEnd...])
        if !tail.isEmpty {
            result.append(AttributedString(tail))
        }

        return result
    }

    // MARK: - Load

    private func loadPage() {
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        rawText = content
        model = DailyPageParser.parse(content: content, dateString: dateString)
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
                }
            }
        }

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
            memoCount: entriesCount
        )
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
