import Foundation
import WidgetKit
import CryptoKit

// MARK: - RawStorageError

/// Errors thrown by atomic write/read operations on raw memo day-files.
/// `writeFailed` is raised when `replaceItemAt` returns nil (silent failure
/// path) or `moveItem` fails — historically these paths were swallowed and
/// the UI thought the write had succeeded.
enum RawStorageError: Error {
    case writeFailed(URL)
    case readFailed(URL)
}

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

            // R6: enqueue for offline sync. Memo.id is a UUID so its
            // canonical string is the SyncQueueService key. Hop to the
            // main actor because SyncQueueService is @MainActor-isolated;
            // the write queue itself is a DispatchQueue and cannot touch
            // it directly.
            let sizeBytes = newBlock.utf8.count
            let memoIDString = memo.id.uuidString
            Task { @MainActor in
                SyncQueueService.shared.enqueue(memoID: memoIDString, sizeBytes: sizeBytes)
            }
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

            // R6: enqueue every rewritten memo for offline sync. We don't
            // know which subset actually changed at this layer, so we
            // enqueue all of them — SyncQueueService.enqueue is idempotent
            // (Set semantics) so re-enqueuing an already-pending memo is
            // a no-op, and an already-synced memo will simply be re-tried,
            // which is exactly what we want after a body edit / pin.
            let enqueuePayload: [(String, Int)] = memos.map { memo in
                (memo.id.uuidString, memo.toMarkdown().utf8.count)
            }
            Task { @MainActor in
                for (memoIDString, sizeBytes) in enqueuePayload {
                    SyncQueueService.shared.enqueue(memoID: memoIDString, sizeBytes: sizeBytes)
                }
            }
        }
    }

    // MARK: - Mutate (read + transform + write inside the write queue)

    /// Atomically reads the day file, applies `transform`, and writes the
    /// result back — all inside `writeQueue.sync` so concurrent mutations
    /// cannot interleave at the read-modify-write boundary.
    ///
    /// Why this exists: writers like the voice-transcript queue read the
    /// current memos, mutate one attachment, and call `rewrite`. If two
    /// such writers run concurrently, each `read()` returns the same
    /// pre-image, and the second `rewrite` clobbers the first writer's
    /// change. `rewrite` itself is serialized — but the read happens
    /// outside the queue, so the staleness is established before either
    /// rewrite enters the critical section. This API closes that gap.
    ///
    /// `transform` runs on the write queue and must be fast and side-
    /// effect-free (no I/O, no awaiting). Returning `nil` aborts the
    /// mutation without writing.
    ///
    /// Throws on read/write failure. `transform` cannot throw.
    static func mutate(
        for date: Date,
        transform: ([Memo]) -> [Memo]?
    ) throws {
        try writeQueue.sync {
            let url = fileURL(for: date)
            let existing: [Memo]
            if FileManager.default.fileExists(atPath: url.path) {
                let content = try String(contentsOf: url, encoding: .utf8)
                existing = parse(fileContent: content, sourceFile: url)
            } else {
                existing = []
            }

            guard let updated = transform(existing) else { return }

            if updated.isEmpty {
                let fm = FileManager.default
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
            } else {
                let content = serialize(updated)
                try atomicWrite(string: content, to: url)
            }

            SentryReporter.breadcrumb(
                category: "rawstorage",
                message: "mutate \(updated.count) memos in \(url.lastPathComponent)"
            )

            WidgetCenter.shared.reloadAllTimelines()
            notifyDidWrite(for: date)

            // R6: enqueue surviving memos for offline sync. Skipping the
            // empty-file branch is intentional: if the user deleted the
            // last memo for a day we have nothing to upload. The transform
            // returning nil bypasses this entire tail (guard above), which
            // is the documented "no-change" path.
            let enqueuePayload: [(String, Int)] = updated.map { memo in
                (memo.id.uuidString, memo.toMarkdown().utf8.count)
            }
            Task { @MainActor in
                for (memoIDString, sizeBytes) in enqueuePayload {
                    SyncQueueService.shared.enqueue(memoID: memoIDString, sizeBytes: sizeBytes)
                }
            }
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
        let memos = parse(fileContent: content, sourceFile: url)

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
        parse(fileContent: fileContent, sourceFile: nil)
    }

    /// Internal entry point that knows the source filename, used for
    /// quarantining unparseable blocks. Callers in production (`read`,
    /// `mutate`) supply the day file URL so the quarantine path can derive
    /// `YYYY-MM-DD-{sha8}.md`. Tests can still call the public 1-arg overload.
    static func parse(fileContent: String, sourceFile: URL?) -> [Memo] {
        if fileContent.contains(memoSeparator) {
            return splitAndParse(fileContent, separator: memoSeparator, sourceFile: sourceFile)
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
            // Whole-or-nothing: only accept the legacy split when every
            // non-empty block parses. A partial parse here is the signature
            // of a modern single-memo body that happens to contain "---",
            // not of a broken legacy file — falling through to the single-
            // memo branch preserves the body intact.
            if !blocks.isEmpty, parsed.count == blocks.count {
                return parsed
            }
        }

        let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let single = Memo.fromMarkdown(trimmed) {
            return [single]
        }

        // Whole-file fallback failed too. If we have a source file we know
        // the user-visible day this came from — quarantine the raw bytes so
        // a later rewrite doesn't silently overwrite them with `[]`.
        if !trimmed.isEmpty, let sourceFile = sourceFile {
            quarantineBrokenBlock(trimmed, sourceFile: sourceFile, reason: "whole-file-unparseable")
        }
        return []
    }

    private static func splitAndParse(_ content: String, separator: String, sourceFile: URL?) -> [Memo] {
        var result: [Memo] = []
        for block in content.components(separatedBy: separator) {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let memo = Memo.fromMarkdown(trimmed) {
                result.append(memo)
            } else if let sourceFile = sourceFile {
                // Broken block in a multi-memo file is the truly dangerous
                // case: the next rewrite would silently drop it. Persist
                // the raw bytes under .broken/ so they survive even if the
                // main file is overwritten with the parseable subset.
                quarantineBrokenBlock(trimmed, sourceFile: sourceFile, reason: "block-unparseable")
            }
        }
        return result
    }

    // MARK: - Broken-block quarantine

    /// Writes `block` to `vault/raw/.broken/<dayfile-stem>-<sha8>.md` with a
    /// short reason header so the user (or a future recovery UI) can see what
    /// was salvaged. Idempotent: the SHA-256 prefix is derived from `block`'s
    /// bytes, so the same broken block hitting `parse` twice produces the same
    /// filename and the second write is a no-op.
    ///
    /// Failures are intentionally swallowed (breadcrumbed) — the day-file
    /// caller already lost the block in memory; we never want quarantine I/O
    /// errors to propagate up and break the user's read path.
    static func quarantineBrokenBlock(_ block: String, sourceFile: URL, reason: String) {
        let bytes = Data(block.utf8)
        let digest = SHA256.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let sha8 = String(hex.prefix(8))

        let stem = sourceFile.deletingPathExtension().lastPathComponent
        let brokenDir = sourceFile.deletingLastPathComponent()
            .appendingPathComponent(".broken", isDirectory: true)
        let target = brokenDir.appendingPathComponent("\(stem)-\(sha8).md")

        // Idempotent: skip if a quarantine copy with the same content hash
        // already exists. Avoids re-writing on every read.
        if FileManager.default.fileExists(atPath: target.path) {
            SentryReporter.breadcrumb(
                category: "rawstorage",
                level: .warning,
                message: "quarantine skipped (already present) \(target.lastPathComponent) reason=\(reason)"
            )
            return
        }

        let header = "<!-- daypage broken block quarantined\n"
            + "  source: \(sourceFile.lastPathComponent)\n"
            + "  reason: \(reason)\n"
            + "  sha256: \(hex)\n"
            + "  bytes: \(bytes.count)\n"
            + "-->\n\n"
        let payload = header + block

        do {
            try atomicWrite(string: payload, to: target)
            SentryReporter.breadcrumb(
                category: "rawstorage",
                level: .error,
                message: "quarantined broken block \(target.lastPathComponent) bytes=\(bytes.count) reason=\(reason)"
            )
        } catch {
            SentryReporter.breadcrumb(
                category: "rawstorage",
                level: .error,
                message: "quarantine write failed for \(target.lastPathComponent): \(error)"
            )
        }
    }

    // MARK: - Atomic write

    /// Writes `string` to `url` atomically, coordinated via NSFileCoordinator so
    /// iCloud Drive sees the write as a single coherent operation.
    /// The temp-file + replaceItemAt pattern runs inside the coordinator block.
    static func atomicWrite(string: String, to url: URL) throws {
        try atomicWrite(data: Data(string.utf8), to: url)
    }

    /// Binary-safe atomic write. Same NSFileCoordinator-guarded temp-file +
    /// replaceItemAt pattern as the `String` overload above — extracted so
    /// asset writers (PhotoService, etc.) get the same crash/iCloud safety
    /// without each duplicating the rename dance.
    ///
    /// Any error (permission, disk full, iCloud conflict) is propagated. The
    /// implementation owns the temp file and cleans it up before throwing,
    /// so callers don't need a `try? removeItem` cleanup path on failure.
    static func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            let tempURL = dir.appendingPathComponent(
                ".\(coordinatedURL.lastPathComponent).tmp.\(UUID().uuidString)"
            )
            do {
                // Step 1: write bytes to the temp file. If this throws, the
                // catch block cleans up the (possibly partial) temp file and
                // surfaces the underlying error to the caller.
                try data.write(to: tempURL, options: .atomic)

                // Step 2: atomic rename. We always go through replaceItemAt
                // when the destination exists; for first-write we moveItem.
                // Critically we INSPECT the NSURL replaceItemAt returns —
                // when the underlying coordinator silently refuses the swap
                // it returns nil with no thrown error, which previously made
                // the UI report success while the bytes never landed.
                if fm.fileExists(atPath: coordinatedURL.path) {
                    let replaced = try fm.replaceItemAt(coordinatedURL, withItemAt: tempURL)
                    if replaced == nil {
                        throw RawStorageError.writeFailed(coordinatedURL)
                    }
                } else {
                    try fm.moveItem(at: tempURL, to: coordinatedURL)
                }
            } catch {
                writeError = error
                // Best-effort cleanup of orphaned temp file on failure.
                try? fm.removeItem(at: tempURL)
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
