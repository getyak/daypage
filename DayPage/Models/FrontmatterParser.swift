import Foundation

/// Lightweight YAML frontmatter field extractor. Reads only the leading
/// `---\n...\n---` block conceptually; does not parse the full YAML document.
///
/// Centralises the `summary:` (and future scalar fields like `summary_zh:`)
/// extraction that was previously duplicated across `TodayViewModel`,
/// `ArchiveView`, `TimelineService`, and `WeeklyRecapService`.
enum FrontmatterParser {

    /// Extracts a top-level scalar field's string value from frontmatter.
    ///
    /// Handles `key: value`, `key: "value"`, `key: 'value'`. Trims surrounding
    /// whitespace and a single layer of matching single/double quotes. Returns
    /// `nil` when the field is absent or the trimmed value is empty.
    ///
    /// - Note: This intentionally scans every line, not just the frontmatter
    ///   block, to preserve the historical behaviour of the now-removed
    ///   per-call-site `extractSummary` helpers. Daily Page files only ever
    ///   write the field once inside the frontmatter, so the behaviour is
    ///   equivalent in practice while remaining tolerant of files without a
    ///   closing `---` delimiter.
    static func extractField(_ key: String, from content: String) -> String? {
        let prefix = "\(key):"
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
