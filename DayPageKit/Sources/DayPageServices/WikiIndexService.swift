// WikiIndexService.swift — issue #814
//
// Deterministic, zero-LLM rebuild of vault/wiki/index.md — the wiki's table
// of contents (karpathy LLM-wiki pattern: an index.md with one line per page
// keeps the compiled knowledge base navigable and lint-able).
//
// Design notes:
//   - Full rebuild from disk (ground truth) instead of incremental append.
//     EntityPageService.updateIndex still appends new entities mid-compile;
//     this rebuild runs last in CompilationService.saveResults and wins,
//     which also dedupes any drift the incremental writer accumulated.
//   - Section headings (`## Places` / `## People` / `## Themes`) and the
//     `- [[wiki/<type>/<slug>|Name]]` link style match EntityPageService's
//     seedIndex() so both writers stay format-compatible.
//   - Never throws: an index is a derived artifact; failures log and move on.

import Foundation
import DayPageStorage

@MainActor
public final class WikiIndexService {

    public static let shared = WikiIndexService()
    private init() {}

    // MARK: - Rebuild

    /// Regenerates vault/wiki/index.md from the current wiki contents.
    /// Fire-and-forget for production callers: the full-wiki directory walk
    /// + per-file frontmatter parse used to run on the main actor at the
    /// tail of every compile (50–300ms with a few hundred pages). The
    /// rebuild is idempotent and atomicWrite serializes the final write, so
    /// detaching is safe. The returned task lets tests await completion.
    @discardableResult
    public func rebuild() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let wikiURL = VaultInitializer.vaultURL.appendingPathComponent("wiki")
            let content = Self.buildIndexMarkdown(
                daily: Self.scanDaily(wikiURL: wikiURL),
                weekly: Self.scanWeekly(wikiURL: wikiURL),
                entities: Self.scanEntities(wikiURL: wikiURL),
                updatedAt: ISO8601DateFormatter.memo.string(from: Date())
            )
            do {
                try RawStorage.atomicWrite(string: content, to: wikiURL.appendingPathComponent("index.md"))
            } catch {
                await DayPageLogger.shared.error("WikiIndexService: failed to write index.md: \(error)")
            }
        }
    }

    // MARK: - Scan (disk → entries)

    /// One indexed daily page: date from filename, summary/mood from frontmatter.
    public struct DailyEntry: Equatable {
        public let dateString: String
        public let summary: String
        public let mood: String

        public init(dateString: String, summary: String, mood: String) {
            self.dateString = dateString
            self.summary = summary
            self.mood = mood
        }
    }

    nonisolated private static func scanDaily(wikiURL: URL) -> [DailyEntry] {
        let dir = wikiURL.appendingPathComponent("daily")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files
            .filter { $0.hasSuffix(".md") }
            .compactMap { filename -> DailyEntry? in
                let dateString = String(filename.dropLast(3))
                // Only YYYY-MM-DD pages; skips stray files inside daily/.
                guard dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      let content = try? String(contentsOf: dir.appendingPathComponent(filename), encoding: .utf8)
                else { return nil }
                let fm = frontmatterFields(of: content)
                return DailyEntry(
                    dateString: dateString,
                    summary: fm["summary"] ?? "",
                    mood: fm["mood"] ?? ""
                )
            }
            .sorted { $0.dateString > $1.dateString } // newest first
    }

    nonisolated private static func scanWeekly(wikiURL: URL) -> [String] {
        let dir = wikiURL.appendingPathComponent("weekly")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(3)) }
            .sorted(by: >) // newest ISO week first
    }

    /// (type, slug, displayName) tuples for places / people / themes.
    nonisolated private static func scanEntities(wikiURL: URL) -> [(type: String, slug: String, name: String)] {
        var results: [(String, String, String)] = []
        for type in ["places", "people", "themes"] {
            let dir = wikiURL.appendingPathComponent(type)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for filename in files.filter({ $0.hasSuffix(".md") && !$0.hasPrefix(".") }).sorted() {
                let slug = String(filename.dropLast(3))
                let content = (try? String(contentsOf: dir.appendingPathComponent(filename), encoding: .utf8)) ?? ""
                let name = frontmatterFields(of: content)["name"] ?? slug
                results.append((type, slug, name))
            }
        }
        return results
    }

    // MARK: - Render (entries → markdown)

    /// Pure renderer — kept static + injectable so tests can assert the
    /// document shape without touching the real vault.
    nonisolated public static func buildIndexMarkdown(
        daily: [DailyEntry],
        weekly: [String],
        entities: [(type: String, slug: String, name: String)],
        updatedAt: String
    ) -> String {
        var lines: [String] = [
            "---",
            "type: index",
            "updated_at: \(updatedAt)",
            "daily_count: \(daily.count)",
            "entity_count: \(entities.count)",
            "---",
            "",
            "# Wiki Index",
            "",
            "## Daily",
            ""
        ]
        for entry in daily {
            var line = "- [[wiki/daily/\(entry.dateString)|\(entry.dateString)]]"
            if !entry.mood.isEmpty { line += " \(entry.mood)" }
            let summary = entry.summary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !summary.isEmpty { line += " — \(summary)" }
            lines.append(line)
        }
        lines.append(contentsOf: ["", "## Weekly", ""])
        for isoWeek in weekly {
            lines.append("- [[wiki/weekly/\(isoWeek)|\(isoWeek)]]")
        }
        for type in ["places", "people", "themes"] {
            lines.append(contentsOf: ["", sectionHeading(for: type), ""])
            for entity in entities where entity.type == type {
                lines.append("- [[wiki/\(entity.type)/\(entity.slug)|\(entity.name)]]")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func sectionHeading(for type: String) -> String {
        switch type {
        case "places": return "## Places"
        case "people": return "## People"
        case "themes": return "## Themes"
        default: return "## \(type.capitalized)"
        }
    }

    // MARK: - Frontmatter

    /// Minimal single-level `key: value` frontmatter parse. Quoted values
    /// are unwrapped so `summary: "..."` indexes cleanly.
    nonisolated private static func frontmatterFields(of content: String) -> [String: String] {
        var fields: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return fields }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }
}
