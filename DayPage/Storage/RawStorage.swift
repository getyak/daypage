import Foundation

// MARK: - RawStorage

/// Reads and writes Memo records to vault/raw/YYYY-MM-DD.md files.
/// Multiple memos in a single day file are separated by "\n\n---\n\n".
/// All writes are atomic: written to a temp file first, then renamed.
enum RawStorage {

    // MARK: - Separator

    /// The exact separator used between memos within a day file.
    static let memoSeparator = "\n\n---\n\n"

    // MARK: - URL helpers

    /// Returns the URL for a given date's raw memo file.
    static func fileURL(for date: Date) -> URL {
        let dateString = dateFormatter.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dateString).md")
    }

    // MARK: - Write

    /// Appends a single Memo to the day file for memo.created.
    /// Creates the file if it doesn't exist.
    /// Uses atomic write (temp file + rename) to prevent corruption.
    static func append(_ memo: Memo) throws {
        let url = fileURL(for: memo.created)
        let newBlock = memo.toMarkdown()

        let existingContent: String
        if FileManager.default.fileExists(atPath: url.path) {
            existingContent = try String(contentsOf: url, encoding: .utf8)
        } else {
            existingContent = ""
        }

        let combined: String
        if existingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combined = newBlock
        } else {
            combined = existingContent + memoSeparator + newBlock
        }

        try atomicWrite(string: combined, to: url)
    }

    // MARK: - Read

    /// Reads all Memos from the day file for the given date.
    /// Returns an empty array if the file doesn't exist or contains no valid memos.
    static func read(for date: Date) throws -> [Memo] {
        let url = fileURL(for: date)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(fileContent: content)
    }

    // MARK: - Parsing

    /// Splits file content on the memo separator and parses each block into a Memo.
    static func parse(fileContent: String) -> [Memo] {
        // Split on the separator
        let blocks = fileContent.components(separatedBy: memoSeparator)
        return blocks.compactMap { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Memo.fromMarkdown(trimmed)
        }
    }

    // MARK: - Atomic write

    /// Writes `string` to `url` atomically by writing to a temp file first,
    /// then using FileManager.replaceItem to rename, avoiding mid-write corruption.
    static func atomicWrite(string: String, to url: URL) throws {
        let data = Data(string.utf8)
        let fm = FileManager.default

        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Write to a temp file in the same directory (required for atomic rename)
        let tempURL = dir.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
        )
        try data.write(to: tempURL, options: .atomic)

        // Move temp → destination
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
    }

    // MARK: - Date formatter

    // Computed so that a change to AppSettings.preferredTimeZone takes effect
    // immediately without restarting the app.
    private static var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f
    }
}
