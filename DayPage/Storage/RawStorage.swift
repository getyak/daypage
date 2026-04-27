import Foundation

// MARK: - RawStorage

/// 读取和写入 Memo 记录到 vault/raw/YYYY-MM-DD.md 文件。
/// 同一天文件中的多条 memo 由 "\n\n---\n\n" 分隔。
/// 所有写入都是原子的：先写入临时文件，再重命名。
enum RawStorage {

    // MARK: - Separator

    /// 同一天文件内 memo 之间使用的精确分隔符。
    static let memoSeparator = "\n\n---\n\n"

    // MARK: - URL helpers

    /// 返回给定日期的原始 memo 文件的 URL。
    static func fileURL(for date: Date) -> URL {
        let dateString = dateFormatter.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dateString).md")
    }

    // MARK: - Write

    /// 将单条 Memo 追加到 memo.created 对应的日文件中。
    /// 如果文件不存在则创建。
    /// 使用原子写入（临时文件 + 重命名）以防止损坏。
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

    /// 读取给定日期日文件中的所有 Memo。
    /// 如果文件不存在或不包含有效的 memo，返回空数组。
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

    /// Writes `string` to `url` atomically, coordinated via NSFileCoordinator so
    /// iCloud Drive sees the write as a single coherent operation.
    /// The temp-file + replaceItemAt pattern runs inside the coordinator block.
    static func atomicWrite(string: String, to url: URL) throws {
        let data = Data(string.utf8)
        let fm = FileManager.default

        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                let tempURL = dir.appendingPathComponent(
                    ".\(coordinatedURL.lastPathComponent).tmp.\(UUID().uuidString)"
                )
                try data.write(to: tempURL, options: .atomic)

                if fm.fileExists(atPath: coordinatedURL.path) {
                    _ = try fm.replaceItemAt(coordinatedURL, withItemAt: tempURL)
                } else {
                    try fm.moveItem(at: tempURL, to: coordinatedURL)
                }
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError { throw error }
        if let error = writeError { throw error }
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
