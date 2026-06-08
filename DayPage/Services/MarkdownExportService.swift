import Foundation
import UIKit

// MARK: - MarkdownExportService

/// Exports today's memos as an Obsidian-compatible Markdown file.
///
/// Output format:
///   - YAML frontmatter (date, mood, entity_mentions, export_source)
///   - Full memo bodies separated by horizontal rules
///   - Attachment references as `![[path]]` wikilinks
///
/// The exported file is written to the OS temp directory and passed to
/// `UIActivityViewController` for sharing (AirDrop, Files, Notes, etc.).
enum MarkdownExportService {

    // MARK: - Export

    /// Returns a yyyy-MM-dd string for the given date in the user's configured timezone.
    static func exportDateString(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = AppSettings.currentTimeZone()
        return df.string(from: date)
    }

    /// Builds an Obsidian-compatible `.md` string from the given memos and date.
    static func buildExportContent(
        memos: [Memo],
        date: Date,
        weather: String? = nil,
        summary: String? = nil
    ) -> String {
        let dateString = exportDateString(for: date)

        let moods = memos.compactMap { $0.mood }.filter { !$0.isEmpty }
        let entities = Array(Set(memos.flatMap { $0.entityMentions })).sorted()
        let resolvedWeather = weather ?? memos.first(where: { $0.weather != nil && !($0.weather!.isEmpty) })?.weather

        var lines: [String] = ["---"]
        lines.append("date: \(dateString)")
        lines.append("export_source: DayPage")
        lines.append("memo_count: \(memos.count)")

        if let mood = moods.first {
            lines.append("mood: \(yamlQuoted(mood))")
        }

        if let w = resolvedWeather {
            lines.append("weather: \(yamlQuoted(w))")
        }

        if entities.isEmpty {
            lines.append("entity_mentions: []")
        } else {
            lines.append("entity_mentions:")
            for e in entities {
                lines.append("  - \(yamlQuoted(e))")
            }
        }

        let locations = memos.compactMap { $0.location?.name }.filter { !$0.isEmpty }
        let dedupedLocations = Array(Set(locations)).sorted()
        if dedupedLocations.isEmpty {
            lines.append("locations: []")
        } else {
            lines.append("locations:")
            for loc in dedupedLocations {
                lines.append("  - \(yamlQuoted(loc))")
            }
        }

        lines.append("---")
        lines.append("")
        lines.append("# DayPage — \(dateString)")
        lines.append("")

        if let s = summary, !s.isEmpty {
            lines.append("> AI · \(s)")
            lines.append("")
        }

        let sorted = memos.sorted { $0.created < $1.created }
        for (idx, memo) in sorted.enumerated() {
            if idx > 0 {
                lines.append("")
                lines.append("---")
                lines.append("")
            }

            // Timestamp header
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            tf.locale = Locale(identifier: "en_US_POSIX")
            tf.timeZone = AppSettings.currentTimeZone()
            lines.append("## \(tf.string(from: memo.created))")
            lines.append("")

            if !memo.body.isEmpty {
                lines.append(memo.body)
            }

            // Attachment wikilinks
            for att in memo.attachments {
                let link: String
                switch att.kind {
                case "photo":
                    link = "![[vault/\(att.file)]]"
                case "audio":
                    var note = "![[vault/\(att.file)]]"
                    if let transcript = att.transcript, !transcript.isEmpty {
                        note += " *(transcript: \(transcript))*"
                    }
                    link = note
                default:
                    link = "[[vault/\(att.file)]]"
                }
                lines.append(link)
            }

            // Location
            if let loc = memo.location, let name = loc.name, !name.isEmpty {
                lines.append("")
                lines.append("> 📍 \(name)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Export Directory

    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPageExport", isDirectory: true)
    }

    // MARK: - Stale Export Cleanup

    /// Removes `.md` files in `exportDirectory` whose modification date is older than `now - interval`.
    /// Best-effort: per-file errors are logged and skipped.
    static func purgeStaleExports(olderThan interval: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        let dir = exportDirectory
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff = now.addingTimeInterval(-interval)
        for fileURL in contents where fileURL.pathExtension == "md" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = values.contentModificationDate else { continue }
            if modDate < cutoff {
                do {
                    try fm.removeItem(at: fileURL)
                } catch {
                    DayPageLogger.log(level: "ERROR", message: "MarkdownExportService: failed to remove stale export \(fileURL.lastPathComponent): \(error)")
                }
            }
        }
    }

    /// Writes the export content to a temp file and returns the URL.
    static func writeExportFile(content: String, dateString: String) throws -> URL {
        let dir = exportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        purgeStaleExports()
        let url = dir.appendingPathComponent("DayPage \(dateString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Private Helpers

    private static func yamlQuoted(_ s: String) -> String {
        var escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: "\\t")
        // Collapse multiple spaces introduced by newline replacement
        while escaped.contains("  ") {
            escaped = escaped.replacingOccurrences(of: "  ", with: " ")
        }
        return "\"\(escaped)\""
    }

    /// Presents a share sheet for the exported markdown file.
    @MainActor
    static func share(memos: [Memo], date: Date, from viewController: UIViewController) {
        let dateString = exportDateString(for: date)

        let content = buildExportContent(memos: memos, date: date)
        guard let url = try? writeExportFile(content: content, dateString: dateString) else {
            return
        }

        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        viewController.present(vc, animated: true)
    }
}
