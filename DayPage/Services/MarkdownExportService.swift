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

    /// Builds an Obsidian-compatible `.md` string from the given memos and date.
    static func buildExportContent(memos: [Memo], date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = AppSettings.currentTimeZone()
        let dateString = df.string(from: date)

        let moods = memos.compactMap { $0.mood }.filter { !$0.isEmpty }
        let entities = Array(Set(memos.flatMap { $0.entityMentions })).sorted()

        var lines: [String] = ["---"]
        lines.append("date: \(dateString)")
        lines.append("export_source: DayPage")
        lines.append("memo_count: \(memos.count)")

        if let mood = moods.first {
            lines.append("mood: \"\(mood)\"")
        }

        if entities.isEmpty {
            lines.append("entity_mentions: []")
        } else {
            lines.append("entity_mentions:")
            for e in entities {
                lines.append("  - \"\(e)\"")
            }
        }
        lines.append("---")
        lines.append("")
        lines.append("# DayPage — \(dateString)")
        lines.append("")

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

    /// Writes the export content to a temp file and returns the URL.
    static func writeExportFile(content: String, dateString: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPageExport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(dateString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Presents a share sheet for the exported markdown file.
    @MainActor
    static func share(memos: [Memo], date: Date, from viewController: UIViewController) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = AppSettings.currentTimeZone()
        let dateString = df.string(from: date)

        let content = buildExportContent(memos: memos, date: date)
        guard let url = try? writeExportFile(content: content, dateString: dateString) else {
            return
        }

        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        viewController.present(vc, animated: true)
    }
}
