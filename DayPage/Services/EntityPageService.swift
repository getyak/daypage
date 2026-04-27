import Foundation

// MARK: - EntityUpdateInstruction

/// LLM 返回的单条实体创建或更新指令，作为结构化编译输出的一部分。
struct EntityUpdateInstruction {
    /// 实体类型："places"、"people" 或 "themes"
    let entityType: String
    /// URL 安全的 slug（小写，连字符分隔，无空格），例如 "joma-coffee"
    let entitySlug: String
    /// 要追加内容到的段落标题，例如 "## Visits"
    let section: String
    /// 追加到该段落下的 Markdown 内容块。
    let content: String
    /// 人类可读的显示名称，例如 "Joma Coffee"
    let displayName: String
}

// MARK: - EntityPageService

/// 管理 vault/wiki/ 下实体页面的创建与增量更新。
///
/// 职责：
///   1. 解析 LLM 返回的实体更新指令
///   2. 在 slug 不存在时创建新实体页面
///   3. 在正确段落下为已有实体页面追加新内容
///   4. 保持 wiki/index.md 同步（按实体类型分组）
///
/// 实体页面位置：
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

    /// 应用实体更新指令数组。
    /// 每条指令要么创建新页面，要么追加到已有页面。
    /// 处理完成后，wiki/index.md 会更新以反映新实体。
    ///
    /// - Parameter instructions: LLM 返回的更新指令数组。
    /// - Parameter date: 源编译的日期字符串（例如 "2026-01-15"）。
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

        // 更新索引，纳入所有新创建的实体
        if !newlyCreated.isEmpty {
            try updateIndex(newEntities: newlyCreated)
        }

        // 同时为已有实体递增 occurrence_count
        // （已在 appendToEntityPage 中通过 frontmatter 更新处理）
    }

    // MARK: - Create Entity Page

    /// 创建带有 frontmatter 和初始内容的实体页面。
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

        // 添加段落及其初始内容
        lines.append(instruction.section)
        lines.append("")
        lines.append(instruction.content)
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Append to Entity Page

    /// 在已有实体页面的指定段落下追加新内容。
    /// 若段落不存在，则在末尾添加。
    /// 更新 frontmatter 中的 `last_updated` 并递增 `occurrence_count`。
    private func appendToEntityPage(
        url: URL,
        instruction: EntityUpdateInstruction,
        date: String
    ) throws {
        var pageContent = try String(contentsOf: url, encoding: .utf8)

        // 更新 frontmatter 字段
        pageContent = updateFrontmatterField(
            in: pageContent,
            key: "last_updated",
            value: iso8601Now()
        )
        pageContent = incrementFrontmatterCount(
            in: pageContent,
            key: "occurrence_count"
        )

        // 在段落下追加（或在末尾添加新段落）
        pageContent = appendUnderSection(
            content: pageContent,
            section: instruction.section,
            newContent: instruction.content
        )

        try writeEntityFile(content: pageContent, to: url)
    }

    // MARK: - Section Management

    /// 在 Markdown 内容中查找 `sectionHeading`，并在该段落
    /// 最后一段已有内容之后追加 `newContent`。
    /// 若段落不存在，则在文档末尾添加。
    func appendUnderSection(
        content: String,
        section sectionHeading: String,
        newContent: String
    ) -> String {
        var lines = content.components(separatedBy: "\n")

        // 查找段落标题行
        if let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == sectionHeading }) {
            // 查找此段落的结束位置（下一个同级或更高级标题，或文件末尾）
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
            // 移除插入点前的空白行，避免过多间距
            while insertIndex > sectionIndex + 1 && lines[insertIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertIndex -= 1
            }
            // 插入一个空行分隔符 + 新内容
            let insertion = ["", newContent, ""]
            lines.insert(contentsOf: insertion, at: insertIndex)
        } else {
            // 未找到段落：追加到末尾
            lines.append("")
            lines.append(sectionHeading)
            lines.append("")
            lines.append(newContent)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Index Update

    /// 更新 vault/wiki/index.md，将新创建的实体按类型分组纳入。
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

        // 按类型分组新实体
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

    /// 替换 frontmatter 中某个键的值（位于首行 --- 与首个 --- 之间）。
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

    /// 将 frontmatter 中的整数字段值加 1。
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

    /// 从 LLM 响应中解析实体更新指令。
    /// 响应中内嵌的预期 JSON 块格式：
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
