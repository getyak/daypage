import Foundation

// MARK: - EntityUpdateInstruction

/// A single instruction to create or update an Entity Page.
/// Returned by the LLM as part of structured compilation output.
struct EntityUpdateInstruction {
    /// Entity type: "places", "people", or "themes"
    let entityType: String
    /// URL-safe slug (lowercase, hyphens, no spaces). e.g. "joma-coffee"
    let entitySlug: String
    /// The section heading to append content under. e.g. "## Visits"
    let section: String
    /// Markdown content block to append under the section.
    let content: String
    /// Human-readable display name. e.g. "Joma Coffee"
    let displayName: String
}

// MARK: - EntityPageService

/// Manages the creation and incremental update of Entity Pages in vault/wiki/.
///
/// Responsibilities:
///   1. Parse entity update instructions returned by the LLM
///   2. Create new Entity Pages when the slug doesn't exist yet
///   3. Append new content to existing Entity Pages under the correct section
///   4. Keep wiki/index.md in sync (grouped by entity type)
///
/// Entity Page Location:
///   vault/wiki/places/{slug}.md
///   vault/wiki/people/{slug}.md
///   vault/wiki/themes/{slug}.md
///
@MainActor
final class EntityPageService {

    // MARK: Singleton

    static let shared = EntityPageService()
    private init() {}

    // MARK: - Apply Instructions

    /// Applies an array of entity update instructions.
    /// Each instruction either creates a new page or appends to an existing one.
    /// After processing, wiki/index.md is updated to reflect new entities.
    ///
    /// - Parameter instructions: Array of update instructions from the LLM.
    /// - Parameter date: The date string for the source compilation (e.g. "2026-01-15").
    func apply(instructions: [EntityUpdateInstruction], date: String) throws {
        var newlyCreated: [(type: String, slug: String, name: String)] = []

        for instruction in instructions {
            let url = entityURL(type: instruction.entityType, slug: instruction.entitySlug)
            let exists = FileManager.default.fileExists(atPath: url.path)

            if exists {
                try appendToEntityPage(url: url, instruction: instruction, date: date)
            } else {
                try createEntityPage(url: url, instruction: instruction, date: date)
                newlyCreated.append((
                    type: instruction.entityType,
                    slug: instruction.entitySlug,
                    name: instruction.displayName
                ))
            }
        }

        // Update index for any newly created entities
        if !newlyCreated.isEmpty {
            try updateIndex(newEntities: newlyCreated)
        }

        // Also increment occurrence_count for existing entities
        // (already handled in appendToEntityPage via frontmatter update)
    }

    // MARK: - Create Entity Page

    /// Creates a new Entity Page with frontmatter and initial content.
    private func createEntityPage(
        url: URL,
        instruction: EntityUpdateInstruction,
        date: String
    ) throws {
        let now = iso8601Now()
        let content = buildNewEntityPage(
            instruction: instruction,
            firstSeen: date,
            now: now
        )
        try writeEntityFile(content: content, to: url)
    }

    private func buildNewEntityPage(
        instruction: EntityUpdateInstruction,
        firstSeen: String,
        now: String
    ) -> String {
        let typeLabel = entityTypeLabel(instruction.entityType)
        var lines: [String] = [
            "---",
            "type: \(instruction.entityType.dropLast())", // "place" / "person" / "theme"
            "name: \"\(escapedYAML(instruction.displayName))\"",
            "slug: \(instruction.entitySlug)",
            "first_seen: \(firstSeen)",
            "last_updated: \(now)",
            "occurrence_count: 1",
            "---",
            "",
            "# \(instruction.displayName)",
            "",
            "**Type**: \(typeLabel)  ",
            "**First seen**: \(firstSeen)",
            ""
        ]

        // Add the section with its initial content
        lines.append(instruction.section)
        lines.append("")
        lines.append(instruction.content)
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Append to Entity Page

    /// Appends new content under the given section in an existing Entity Page.
    /// If the section doesn't exist, it is added at the end.
    /// Updates `last_updated` and increments `occurrence_count` in frontmatter.
    private func appendToEntityPage(
        url: URL,
        instruction: EntityUpdateInstruction,
        date: String
    ) throws {
        var pageContent = try String(contentsOf: url, encoding: .utf8)

        // Update frontmatter fields
        pageContent = updateFrontmatterField(
            in: pageContent,
            key: "last_updated",
            value: iso8601Now()
        )
        pageContent = incrementFrontmatterCount(
            in: pageContent,
            key: "occurrence_count"
        )

        // Append under section (or add new section at end)
        pageContent = appendUnderSection(
            content: pageContent,
            section: instruction.section,
            newContent: instruction.content
        )

        try writeEntityFile(content: pageContent, to: url)
    }

    // MARK: - Section Management

    /// Finds `sectionHeading` in the Markdown content and appends `newContent` after
    /// the last existing paragraph in that section.
    /// If the section doesn't exist, adds it at the end of the document.
    func appendUnderSection(
        content: String,
        section sectionHeading: String,
        newContent: String
    ) -> String {
        var lines = content.components(separatedBy: "\n")

        // Find the section heading line
        if let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == sectionHeading }) {
            // Find the end of this section (next heading at same or higher level, or end of file)
            let level = headingLevel(of: sectionHeading)
            var insertIndex = sectionIndex + 1
            while insertIndex < lines.count {
                let line = lines[insertIndex]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") && headingLevel(of: trimmed) <= level {
                    break
                }
                insertIndex += 1
            }
            // Remove trailing blank lines before insert point to avoid excessive spacing
            while insertIndex > sectionIndex + 1 && lines[insertIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertIndex -= 1
            }
            // Insert a blank separator + new content
            let insertion = ["", newContent, ""]
            lines.insert(contentsOf: insertion, at: insertIndex)
        } else {
            // Section not found: append at end
            lines.append("")
            lines.append(sectionHeading)
            lines.append("")
            lines.append(newContent)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Index Update

    /// Updates vault/wiki/index.md to include newly created entities, grouped by type.
    private func updateIndex(newEntities: [(type: String, slug: String, name: String)]) throws {
        let indexURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("index.md")

        var indexContent: String
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do { indexContent = try String(contentsOf: indexURL, encoding: .utf8) }
            catch { DayPageLogger.shared.error("EntityPageService: read index: \(error)"); indexContent = seedIndex() }
        } else {
            indexContent = seedIndex()
        }

        // Group new entities by type
        var byType: [String: [(slug: String, name: String)]] = [:]
        for entity in newEntities {
            byType[entity.type, default: []].append((entity.slug, entity.name))
        }

        for (type, entities) in byType {
            let sectionHeading = indexSectionHeading(for: type)
            for entity in entities {
                let listItem = "- [[wiki/\(type)/\(entity.slug)|\(entity.name)]]"
                indexContent = appendUnderSection(
                    content: indexContent,
                    section: sectionHeading,
                    newContent: listItem
                )
            }
        }

        try RawStorage.atomicWrite(string: indexContent, to: indexURL)
    }

    // MARK: - Frontmatter Helpers

    /// Replaces the value of a frontmatter key (between leading --- and first ---).
    func updateFrontmatterField(in content: String, key: String, value: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var inFrontmatter = false
        var closingFound = false

        for (index, line) in lines.enumerated() {
            if index == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                inFrontmatter = true
                result.append(line)
                continue
            }
            if inFrontmatter && !closingFound && line.trimmingCharacters(in: .whitespaces) == "---" {
                closingFound = true
                inFrontmatter = false
                result.append(line)
                continue
            }
            if inFrontmatter {
                let prefix = "\(key): "
                if line.hasPrefix(prefix) {
                    result.append("\(key): \(value)")
                    continue
                }
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    /// Increments an integer frontmatter field by 1.
    func incrementFrontmatterCount(in content: String, key: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var inFrontmatter = false
        var closingFound = false

        for (index, line) in lines.enumerated() {
            if index == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                inFrontmatter = true
                result.append(line)
                continue
            }
            if inFrontmatter && !closingFound && line.trimmingCharacters(in: .whitespaces) == "---" {
                closingFound = true
                inFrontmatter = false
                result.append(line)
                continue
            }
            if inFrontmatter {
                let prefix = "\(key): "
                if line.hasPrefix(prefix) {
                    let raw = String(line.dropFirst(prefix.count))
                    let current = Int(raw.trimmingCharacters(in: .whitespaces)) ?? 0
                    result.append("\(key): \(current + 1)")
                    continue
                }
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Parse LLM Structured Output

    /// Parses entity update instructions from the LLM response.
    /// Expected JSON block embedded in the response:
    ///
    /// ```json
    /// {
    ///   "daily_page": "...markdown...",
    ///   "entity_updates": [
    ///     {
    ///       "entity_type": "places",
    ///       "entity_slug": "joma-coffee",
    ///       "display_name": "Joma Coffee",
    ///       "section": "## Visits",
    ///       "content": "- 2026-01-15: Had an Americano, worked on DayPage"
    ///     }
    ///   ]
    /// }
    /// ```
    static func parseStructuredOutput(_ rawLLMResponse: String) -> (dailyPage: String, instructions: [EntityUpdateInstruction]) {
        // Try to extract and parse a JSON block from the response
        guard let jsonBlock = extractJSONBlock(from: rawLLMResponse),
              let data = jsonBlock.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dailyPage = json["daily_page"] as? String,
              !dailyPage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Extraction or validation failed — signal failure via empty dailyPage sentinel
            return ("", [])
        }
        var instructions: [EntityUpdateInstruction] = []

        if let updates = json["entity_updates"] as? [[String: Any]] {
            for update in updates {
                guard
                    let entityType = update["entity_type"] as? String,
                    let entitySlug = update["entity_slug"] as? String,
                    let displayName = update["display_name"] as? String,
                    let section = update["section"] as? String,
                    let content = update["content"] as? String,
                    ["places", "people", "themes"].contains(entityType)
                else { continue }

                let safeSlug = sanitizeSlug(entitySlug)
                instructions.append(EntityUpdateInstruction(
                    entityType: entityType,
                    entitySlug: safeSlug,
                    section: section,
                    content: content,
                    displayName: displayName
                ))
            }
        }

        return (dailyPage, instructions)
    }

    // MARK: - File Helpers

    private func entityURL(type: String, slug: String) -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent(type)
            .appendingPathComponent("\(slug).md")
    }

    private func writeEntityFile(content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try RawStorage.atomicWrite(string: content, to: url)
    }

    // MARK: - Private Helpers

    private static func extractJSONBlock(from text: String) -> String? {
        // Match ```json (with optional space/uppercase) ... ``` fenced blocks
        let fencePatterns = ["```json\n", "```json \n", "```JSON\n", "```\n"]
        for pattern in fencePatterns {
            if let fenceStart = text.range(of: pattern, options: .caseInsensitive),
               let fenceEnd = text.range(of: "\n```", range: fenceStart.upperBound ..< text.endIndex) {
                return String(text[fenceStart.upperBound ..< fenceEnd.lowerBound])
            }
        }
        // Fallback: raw { ... } spanning the whole response
        if let braceStart = text.firstIndex(of: "{"),
           let braceEnd = text.lastIndex(of: "}") {
            return String(text[braceStart ... braceEnd])
        }
        return nil
    }

    static func sanitizeSlug(_ raw: String) -> String {
        raw
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined(separator: "-")
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func headingLevel(of line: String) -> Int {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        return level
    }

    private func entityTypeLabel(_ type: String) -> String {
        switch type {
        case "places": return "Place"
        case "people": return "Person"
        case "themes": return "Theme"
        default: return type.capitalized
        }
    }

    private func indexSectionHeading(for type: String) -> String {
        switch type {
        case "places": return "## Places"
        case "people": return "## People"
        case "themes": return "## Themes"
        default: return "## \(type.capitalized)"
        }
    }

    private func seedIndex() -> String {
        """
        ---
        type: index
        ---

        # Wiki Index

        ## Places

        ## People

        ## Themes
        """
    }

    private func iso8601Now() -> String {
        ISO8601DateFormatter.memo.string(from: Date())
    }

    private func escapedYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
