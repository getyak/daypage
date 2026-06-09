import Foundation
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

            SentryReporter.breadcrumb(
                category: "rawstorage",
                message: "append memo \(memo.id) to \(url.lastPathComponent)"
            )

            WidgetCenter.shared.reloadAllTimelines()
            notifyDidWrite(for: memo.created)
        }
    }

    // MARK: - Write notification

    /// Posted after any raw day-file mutation so caches (e.g. TimelineIndex) can
    /// update incrementally. The object is the affected day's `Date`. Decoupled
    /// via NotificationCenter so the storage layer never depends on the index
    /// layer, and every write path (TodayViewModel rewrite/delete,
    /// PassiveLocationService, SampleDataSeeder) is covered automatically.
    static func notifyDidWrite(for date: Date) {
        NotificationCenter.default.post(name: .rawStorageDidWrite, object: date)
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

                SentryReporter.breadcrumb(
                    category: "rawstorage",
                    message: "rewrite: removed empty file \(url.lastPathComponent)"
                )

                WidgetCenter.shared.reloadAllTimelines()
                notifyDidWrite(for: date)
                return
            }

            let content = serialize(memos)
            try atomicWrite(string: content, to: url)

            SentryReporter.breadcrumb(
                category: "rawstorage",
                message: "rewrite \(memos.count) memos to \(url.lastPathComponent)"
            )

            WidgetCenter.shared.reloadAllTimelines()
            notifyDidWrite(for: date)
        }
    }

    // MARK: - Read

    /// 读取给定日期日文件中的所有 Memo。
    /// 如果文件不存在或不包含有效的 memo，返回空数组。
    static func read(for date: Date) throws -> [Memo] {
        let url = fileURL(for: date)
        guard FileManager.default.fileExists(atPath: url.path) else {
            SentryReporter.breadcrumb(
                category: "rawstorage",
                level: .warning,
                message: "read: file not found \(url.lastPathComponent)"
            )
            return []
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let memos = parse(fileContent: content)

        SentryReporter.breadcrumb(
            category: "rawstorage",
            message: "read \(memos.count) memos from \(url.lastPathComponent)"
        )

        return memos
    }

    // MARK: - Parsing

    /// Splits file content on the memo separator and parses each block into a Memo.
    ///
    /// 兼容性策略（issue #227）：
    /// 1. 若文件含**当前**分隔符 → 新格式，按当前分隔符切分。
    /// 2. 否则若文件含历史分隔符 "\n\n---\n\n"，**尝试**按它切分。仅当切分后
    ///    每一块都能独立解析为合法 memo（含合法 frontmatter + id）时才采纳此结果——
    ///    这区分了「旧格式的多条 memo」与「新格式单 memo 正文中恰好出现的 ---」：
    ///    后者按 legacy 分隔符切开后会产生无合法 frontmatter 的碎片，于是被否决，
    ///    回退到步骤 3 当作单条 memo。
    /// 3. 否则将整个文件当作单条 memo 解析（覆盖新/旧格式的单 memo 文件，
    ///    两者磁盘表示相同）。
    /// 该策略既保证旧 vault 文件（含多条 memo）可读，又避免新格式 memo
    /// 正文中偶尔出现的 "---" 被错误切分导致数据丢失。
    static func parse(fileContent: String) -> [Memo] {
        if fileContent.contains(memoSeparator) {
            return splitAndParse(fileContent, separator: memoSeparator)
        }

        // 旧格式回退：只有当 legacy 分隔符切出的**每一非空块**都能独立解析为
        // 合法 memo 时才采纳。这样「旧格式多条 memo」与「空块 + 单条 memo」都能
        // 正确读出，而「新格式单 memo 正文里含 ---」会切出无 frontmatter 的碎片
        // （解析失败），于是被否决并落到下面的单条解析分支，避免数据被错切。
        if fileContent.contains(legacyMemoSeparator) {
            let blocks = fileContent
                .components(separatedBy: legacyMemoSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let parsed = blocks.compactMap(Memo.fromMarkdown)
            if !blocks.isEmpty, parsed.count == blocks.count {
                return parsed
            }
        }

        let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let single = Memo.fromMarkdown(trimmed) {
            return [single]
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
