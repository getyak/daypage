import SwiftUI
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices

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

        // 摘要同样可能携带 wikilink（编译器把实体名写进一句话总结）。
        summary = normalizeWikilinks(in: summary)

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
                    let raw = currentSectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty && !skipSections.contains(title) {
                        let (cleanBody, evidenceIDs) = extractEvidence(from: raw)
                        sections.append(DailyPageModel.PageSection(title: title, body: cleanBody, evidenceMemoIDs: evidenceIDs))
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
            let raw = currentSectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty && !skipSections.contains(title) {
                let (cleanBody, evidenceIDs) = extractEvidence(from: raw)
                sections.append(DailyPageModel.PageSection(title: title, body: cleanBody, evidenceMemoIDs: evidenceIDs))
            }
        }

        // -- 解析 LOCATIONS TODAY 段落 --
        let locations = parseLocations(from: bodyText)

        // -- 解析 AI FOLLOW-UP 段落（以 > 开头的行） --
        let followUpQuestions = parseFollowUpQuestions(from: bodyText)

        // TODO(R13+): Parse threads/mentions from compiled markdown when format is defined — follow-up issue.
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
    /// Issue #4: strip `[^m:<uuid>]` footnote markers out of a compiled
    /// section body and return the cleaned prose + the deduped ordered list
    /// of memo UUIDs the AI cited for that section. Malformed UUIDs are
    /// silently dropped — the viewer treats the section as unevidenced
    /// rather than showing a broken chip.
    private static func extractEvidence(from raw: String) -> (String, [UUID]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\^m:([0-9a-fA-F\-]{8,})\]"#,
            options: []
        ) else { return (raw, []) }

        let ns = raw as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: raw, range: range)
        guard !matches.isEmpty else { return (raw, []) }

        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for m in matches where m.numberOfRanges >= 2 {
            let raw = ns.substring(with: m.range(at: 1))
            if let uuid = UUID(uuidString: raw), !seen.contains(uuid) {
                seen.insert(uuid)
                ordered.append(uuid)
            }
        }
        let cleaned = regex.stringByReplacingMatches(
            in: raw,
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalizeWikilinks(in: cleaned), ordered)
    }

    // Cached — pattern is invariant, and sections re-parse on every page load.
    private static let wikilinkDisplayRegex = try? NSRegularExpression(
        pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )

    /// 将叙事正文中的 wikilink 展示为人类可读名称（FINDING-005）。
    /// `[[wiki/people/a-ling|阿玲]]` → `阿玲`；`[[joma-coffee]]` → `joma coffee`。
    /// 编译器输出与手写页都可能带任一形式；在做成可点 chip 之前，至少不能把
    /// 原始链接语法裸露给读者。
    static func normalizeWikilinks(in text: String) -> String {
        guard text.contains("[["), let regex = wikilinkDisplayRegex else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Replace back-to-front so earlier ranges stay valid.
        for m in matches.reversed() {
            let display: String
            if m.range(at: 2).location != NSNotFound {
                display = ns.substring(with: m.range(at: 2))
            } else {
                let target = ns.substring(with: m.range(at: 1))
                let slug = target.split(separator: "/").last.map(String.init) ?? target
                display = slug.replacingOccurrences(of: "-", with: " ")
            }
            ns.replaceCharacters(in: m.range(at: 0), with: display)
        }
        return ns as String
    }

    private static func firstPhotoAttachmentPath(for dateString: String) -> String? {
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return nil }

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
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return "" }
        return DateFormatters.weekdayLong.string(from: date)
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
                    guard let fullMatchRange = Range(match.range, in: raw) else { continue }
                    let afterLink = String(raw[fullMatchRange.upperBound...])
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