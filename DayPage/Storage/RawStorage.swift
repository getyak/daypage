import Foundation
import Sentry
import WidgetKit

// MARK: - RawStorage

/// 读取和写入 Memo 记录到 vault/raw/YYYY-MM-DD.md 文件。
/// 同一天文件中的多条 memo 由 memoSeparator 分隔。
/// 所有写入都是原子的：先写入临时文件，再重命名。
enum RawStorage {

    // MARK: - Serial write queue

    /// Guards append() against concurrent read-modify-write races.
    /// Two simultaneous appends (e.g. voice transcription completing
    /// at the same moment the user taps Send) would otherwise read
    /// the same file content, each append their memo, and the last
    /// writer wins — silently dropping one memo.
    private static let writeQueue = DispatchQueue(label: "com.daypage.rawstorage.write")

    // MARK: - Separator

    /// 同一天文件内 memo 之间使用的精确分隔符。
    /// 使用 HTML 注释而非裸 "---"，避免与 YAML frontmatter 闭合符及
    /// 用户正文中可能出现的 "---" 冲突（issue #227）。
    static let memoSeparator = "\n\n<!-- daypage-memo-separator -->\n\n"

    /// 历史分隔符（v1）。仍然保留以便向后兼容已有 vault 文件的解析。
    static let legacyMemoSeparator = "\n\n---\n\n"

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
    /// 写入操作由 writeQueue 序列化以防止并发追加时数据丢失。
    static func append(_ memo: Memo) throws {
        try writeQueue.sync {
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

            let crumb = Breadcrumb()
            crumb.category = "rawstorage"
            crumb.message = "append memo \(memo.id) to \(url.lastPathComponent)"
            crumb.level = .info
            SentrySDK.addBreadcrumb(crumb)

            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Serialization

    /// Serializes an ordered list of memos into the on-disk format for a single
    /// day's file: each memo's markdown joined by `memoSeparator`, written
    /// newest-last so the file is chronological (parser sorts later anyway).
    ///
    /// Pure function — no I/O, safe to call from any thread/actor.
    static func serialize(_ memos: [Memo]) -> String {
        let ordered = memos.sorted { $0.created < $1.created }
        return ordered.map { $0.toMarkdown() }.joined(separator: memoSeparator)
    }

    // MARK: - Rewrite

    /// Replaces the contents of `date`'s raw file with the given memo list.
    /// If `memos` is empty, the file is deleted.
    ///
    /// Runs through `writeQueue.sync` so that it cannot interleave with
    /// `append()` — without this, a concurrent rewrite + append against the
    /// same day's file would race (e.g. user pins a memo while a voice
    /// transcript callback appends another), and the last writer would silently
    /// overwrite the other's changes.
    ///
    /// Safe to call from any thread/actor. Performs disk I/O inline, so callers
    /// on `@MainActor` should dispatch via `Task.detached` to avoid blocking
    /// the UI thread (see TodayViewModel for the canonical pattern).
    static func rewrite(_ memos: [Memo], for date: Date) throws {
        try writeQueue.sync {
            let url = fileURL(for: date)
            if memos.isEmpty {
                let fm = FileManager.default
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }

                let crumb = Breadcrumb()
                crumb.category = "rawstorage"
                crumb.message = "rewrite: removed empty file \(url.lastPathComponent)"
                crumb.level = .info
                SentrySDK.addBreadcrumb(crumb)

                WidgetCenter.shared.reloadAllTimelines()
                return
            }

            let content = serialize(memos)
            try atomicWrite(string: content, to: url)

            let crumb = Breadcrumb()
            crumb.category = "rawstorage"
            crumb.message = "rewrite \(memos.count) memos to \(url.lastPathComponent)"
            crumb.level = .info
            SentrySDK.addBreadcrumb(crumb)

            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Read

    /// 读取给定日期日文件中的所有 Memo。
    /// 如果文件不存在或不包含有效的 memo，返回空数组。
    static func read(for date: Date) throws -> [Memo] {
        let url = fileURL(for: date)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let crumb = Breadcrumb()
            crumb.category = "rawstorage"
            crumb.message = "read: file not found \(url.lastPathComponent)"
            crumb.level = .warning
            SentrySDK.addBreadcrumb(crumb)
            return []
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let memos = parse(fileContent: content)

        let crumb = Breadcrumb()
        crumb.category = "rawstorage"
        crumb.message = "read \(memos.count) memos from \(url.lastPathComponent)"
        crumb.level = .info
        SentrySDK.addBreadcrumb(crumb)

        return memos
    }

    // MARK: - Parsing

    /// Splits file content on the memo separator and parses each block into a Memo.
    ///
    /// 兼容性策略（issue #227）：
    /// 1. 若文件含**当前**分隔符 → 新格式，按当前分隔符切分。
    /// 2. 否则先尝试将整个文件当作单条 memo 解析 — 这覆盖了所有
    ///    新格式单 memo 文件，以及旧格式的单 memo 文件（两者磁盘
    ///    表示相同）。若成功且整段被一条 memo 完整消费，返回该结果。
    /// 3. 否则回退到历史分隔符 "\n\n---\n\n"，处理旧 vault 文件。
    /// 该策略既保证旧文件可读，又避免新格式 memo 正文中偶尔出现的
    /// "---" 被错误切分。
    static func parse(fileContent: String) -> [Memo] {
        if fileContent.contains(memoSeparator) {
            return splitAndParse(fileContent, separator: memoSeparator)
        }

        let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let single = Memo.fromMarkdown(trimmed) {
            return [single]
        }

        if fileContent.contains(legacyMemoSeparator) {
            return splitAndParse(fileContent, separator: legacyMemoSeparator)
        }

        return []
    }

    private static func splitAndParse(_ content: String, separator: String) -> [Memo] {
        content.components(separatedBy: separator).compactMap { block -> Memo? in
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

    // MARK: - Trash TTL Cleanup

    /// Removes backup files older than `days` days from every `.trash` directory
    /// under vault/wiki/daily/ and vault/wiki/ (hot cache backups).
    /// Safe to call on a background thread.
    static func pruneTrashOlderThan(days: Int = 7) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)

        let trashDirs: [URL] = [
            VaultInitializer.vaultURL.appendingPathComponent("wiki/daily/.trash"),
            VaultInitializer.vaultURL.appendingPathComponent("wiki/.trash"),
        ]

        for dir in trashDirs {
            guard fm.fileExists(atPath: dir.path) else { continue }
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { continue }
            for entry in entries {
                guard let attrs = try? entry.resourceValues(forKeys: [.creationDateKey]),
                      let created = attrs.creationDate,
                      created < cutoff else { continue }
                try? fm.removeItem(at: entry)
            }
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
