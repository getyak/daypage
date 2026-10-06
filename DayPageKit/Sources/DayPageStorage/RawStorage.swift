import Foundation
import WidgetKit
import CryptoKit
import DayPageModels

// MARK: - RawStorageError

/// Errors thrown by atomic write/read operations on raw memo day-files.
/// `writeFailed` is raised when `replaceItemAt` returns nil (silent failure
/// path) or `moveItem` fails — historically these paths were swallowed and
/// the UI thought the write had succeeded.
public enum RawStorageError: Error {
    case writeFailed(URL)
    case readFailed(URL)
    case invalidDayString(String)
}

// MARK: - RawStorage

/// 读取和写入 Memo 记录到 vault/raw/YYYY-MM-DD.md 文件。
/// 同一天文件中的多条 memo 由 memoSeparator 分隔。
/// 所有写入都是原子的：先写入临时文件，再重命名。
public enum RawStorage {

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
    public static let memoSeparator = "\n\n<!-- daypage-memo-separator -->\n\n"

    /// 历史分隔符（v1）。仍然保留以便向后兼容已有 vault 文件的解析。
    public static let legacyMemoSeparator = "\n\n---\n\n"

    // MARK: - URL helpers

    /// 返回给定日期的原始 memo 文件的 URL。
    public static func fileURL(for date: Date) -> URL {
        fileURL(for: date, vaultRoot: VaultInitializer.vaultURL)
    }

    public static func fileURL(for date: Date, vaultRoot: URL) -> URL {
        let dateString = dateFormatter.string(from: date)
        return vaultRoot
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dateString).md")
    }

    /// Resolve a canonical day filename in the same timezone used to read it.
    /// Device-local midnight can otherwise point at the previous stored day.
    public static func date(forDayString dayString: String) -> Date? {
        let formatter = dateFormatter
        formatter.isLenient = false
        guard let date = formatter.date(from: dayString),
              formatter.string(from: date) == dayString else { return nil }
        return date
    }

    // MARK: - Canonical owning-day keys

    /// `userInfo` key carrying the validated raw day file key that a
    /// `.rawStorageDidWrite` notification actually wrote. Consumers must
    /// prefer this key over reinterpreting the legacy `Date` object through a
    /// cached formatter when the preferred time zone can change at runtime.
    public static let writtenDayStringKey = "dayString"

    /// Strict canonical owning-day validator: exact `yyyy-MM-dd` lexical
    /// shape and a real Gregorian calendar date (rejects `2026-02-30`,
    /// separators, traversal, and trailing garbage). Evaluated by Gregorian rules — independently of the current preferred zone — so a
    /// timezone switch or a skipped local midnight can never change whether
    /// a key is valid.
    public static func isValidDayString(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ byte in
                  byte.offset == 4 || byte.offset == 7 || (48...57).contains(byte.element)
              }),
              let year = Int(String(decoding: bytes[0..<4], as: UTF8.self)), year > 0,
              let month = Int(String(decoding: bytes[5..<7], as: UTF8.self)), (1...12).contains(month),
              let day = Int(String(decoding: bytes[8..<10], as: UTF8.self)), day > 0
        else { return false }
        let isLeapYear = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        let daysInMonth = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= daysInMonth[month - 1]
    }

    /// Exact raw day-file URL for a canonical owning-day key. The URL is
    /// selected directly from the validated string — never derived from a
    /// `Date` through the mutable preferred zone. Fails closed (`nil`) for
    /// invalid keys, so no path separator or traversal can enter the URL.
    public static func fileURL(forDayString dayString: String, vaultRoot: URL) -> URL? {
        guard isValidDayString(dayString) else { return nil }
        return vaultRoot
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dayString).md")
    }

    /// Legacy Date interop: the canonical owning-day key for `date` under the
    /// current preferred zone. Callers holding a `Date` should convert ONCE
    /// (e.g. at route construction) and keep the resulting key.
    public static func dayString(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// 生成 asset 文件名：`<prefix>_<yyyyMMdd_HHmmss>_<uniq>.<ext>`（本地时区）。
    /// 用于照片（prefix "IMG"）、语音（prefix "voice"）等带时间戳的附件。
    /// 时间戳只有秒级精度——同一秒内保存多张照片（相册多选）会生成相同
    /// 文件名并互相覆盖，后一张静默吞掉前一张。追加 4 位随机后缀保证
    /// 同秒多附件各自落盘；`IMG_*.jpg` 通配消费方（OrphanedPhotoScanner）不受影响。
    public static func assetFilename(prefix: String, ext: String) -> String {
        let stamp = assetTimestampFormatter.string(from: Date())
        let uniq = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(prefix)_\(stamp)_\(uniq).\(ext)"
    }

    // MARK: - Write

    /// 将单条 Memo 追加到 memo.created 对应的日文件中。
    /// 如果文件不存在则创建。
    /// 使用原子写入（临时文件 + 重命名）以防止损坏。
    /// 写入操作由 writeQueue 序列化以防止并发追加时数据丢失。
    public static func append(_ memo: Memo) throws {
        try append(memo, vaultRoot: VaultInitializer.vaultURL)
    }

    public static func append(_ memo: Memo, vaultRoot: URL) throws {
        let capturedVaultRoot = vaultRoot
        try writeQueue.sync {
            let url = fileURL(for: memo.created, vaultRoot: capturedVaultRoot)
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

            let outboxRecorded: Bool
            do {
                try SyncOutboxStore.recordUpsert(
                    memo,
                    vaultPath: "raw/\(url.lastPathComponent)",
                    vaultRoot: capturedVaultRoot
                )
                outboxRecorded = true
            } catch {
                outboxRecorded = false
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "outbox append record failed for \(memo.id): \(error)"
                )
            }

            SentryReporter.breadcrumb(
                category: "rawstorage",
                message: "append memo \(memo.id) to \(url.lastPathComponent)"
            )

            WidgetCenter.shared.reloadAllTimelines()
            notifyDidWrite(
                for: memo.created,
                dayString: url.deletingPathExtension().lastPathComponent
            )

            let sizeBytes = newBlock.utf8.count
            let memoIDString = memo.id.uuidString
            Task { @MainActor in
                if outboxRecorded {
                    SyncQueueService.shared.reloadFromOutbox()
                } else {
                    // The Vault write already committed. Keep the visible
                    // backlog fail-closed; background reconciliation repairs
                    // the sidecar without risking a duplicate local memo.
                    SyncQueueService.shared.enqueue(memoID: memoIDString, sizeBytes: sizeBytes)
                }
                await SyncQueueService.shared.flushIfOnline()
            }
        }
    }

    // MARK: - Write notification

    /// Posted after any raw day-file mutation so caches (e.g. TimelineIndex) can
    /// update incrementally. The object is the affected day's `Date` (legacy
    /// compatibility). The actual written raw file key is additionally carried
    /// under `writtenDayStringKey` in `userInfo` whenever the written URL stem
    /// passes `isValidDayString`, so cache consumers never have to reinterpret
    /// a `Date` through a formatter whose zone may have changed. Invalid keys
    /// are dropped from `userInfo` — the notification still posts.
    public static func notifyDidWrite(for date: Date, dayString: String? = nil) {
        var userInfo: [AnyHashable: Any]? = nil
        if let dayString, isValidDayString(dayString) {
            userInfo = [writtenDayStringKey: dayString]
        }
        NotificationCenter.default.post(
            name: .rawStorageDidWrite,
            object: date,
            userInfo: userInfo
        )
    }

    // MARK: - Serialization

    /// Serializes an ordered list of memos into the on-disk format for a single
    /// day's file: each memo's markdown joined by `memoSeparator`, written
    /// newest-last so the file is chronological (parser sorts later anyway).
    ///
    /// Pure function — no I/O, safe to call from any thread/actor.
    public static func serialize(_ memos: [Memo]) -> String {
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
    public static func rewrite(_ memos: [Memo], for date: Date) throws {
        try writeQueue.sync {
            let url = fileURL(for: date)
            let previous: [Memo]
            if FileManager.default.fileExists(atPath: url.path),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                previous = parse(fileContent: content, sourceFile: url)
            } else {
                previous = []
            }
            if memos.isEmpty {
                let fm = FileManager.default
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }

                let outboxRecorded: Bool
                do {
                    try SyncOutboxStore.recordChanges(
                        before: previous,
                        after: [],
                        vaultPath: "raw/\(url.lastPathComponent)"
                    )
                    outboxRecorded = true
                } catch {
                    outboxRecorded = false
                    SentryReporter.breadcrumb(
                        category: "syncqueue",
                        level: .warning,
                        message: "outbox delete record failed for \(url.lastPathComponent): \(error)"
                    )
                }

                SentryReporter.breadcrumb(
                    category: "rawstorage",
                    message: "rewrite: removed empty file \(url.lastPathComponent)"
                )

                WidgetCenter.shared.reloadAllTimelines()
                notifyDidWrite(
                    for: date,
                    dayString: url.deletingPathExtension().lastPathComponent
                )
                let deletedPayload = previous.map { ($0.id.uuidString, 0) }
                Task { @MainActor in
                    if outboxRecorded {
                        SyncQueueService.shared.reloadFromOutbox()
                    } else {
                        for (memoID, sizeBytes) in deletedPayload {
                            SyncQueueService.shared.enqueue(memoID: memoID, sizeBytes: sizeBytes)
                        }
                    }
                    await SyncQueueService.shared.flushIfOnline()
                }
                return
            }

            let content = serialize(memos)
            try atomicWrite(string: content, to: url)

            let outboxRecorded: Bool
            do {
                try SyncOutboxStore.recordChanges(
                    before: previous,
                    after: memos,
                    vaultPath: "raw/\(url.lastPathComponent)"
                )
                outboxRecorded = true
            } catch {
                outboxRecorded = false
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "outbox rewrite record failed for \(url.lastPathComponent): \(error)"
                )
            }

            SentryReporter.breadcrumb(
                category: "rawstorage",
                message: "rewrite \(memos.count) memos to \(url.lastPathComponent)"
            )

            WidgetCenter.shared.reloadAllTimelines()
            notifyDidWrite(
                for: date,
                dayString: url.deletingPathExtension().lastPathComponent
            )

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
                if outboxRecorded {
                    SyncQueueService.shared.reloadFromOutbox()
                } else {
                    for (memoIDString, sizeBytes) in enqueuePayload {
                        SyncQueueService.shared.enqueue(memoID: memoIDString, sizeBytes: sizeBytes)
                    }
                }
                await SyncQueueService.shared.flushIfOnline()
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
    public static func mutate(
        for date: Date,
        transform: ([Memo]) -> [Memo]?
    ) throws {
        try mutate(for: date, vaultRoot: VaultInitializer.vaultURL, transform: transform)
    }

    public static func mutate(
        for date: Date,
        vaultRoot: URL,
        transform: ([Memo]) -> [Memo]?
    ) throws {
        let capturedVaultRoot = vaultRoot
        try writeQueue.sync {
            let url = fileURL(for: date, vaultRoot: capturedVaultRoot)
            try performMutate(
                at: url,
                vaultRoot: capturedVaultRoot,
                notifyDate: date,
                transform: transform
            )
        }
    }

    /// Canonical owning-day mutation boundary. The exact raw URL is selected
    /// directly from the validated `YYYY-MM-DD` key and passed into the same
    /// serialized read-transform-write critical section — never derived from a
    /// `Date` reinterpreted under a possibly-changed preferred zone, and no
    /// global time zone is touched. Fails closed on an invalid key before the
    /// critical section, so no file is read or written.
    public static func mutate(
        dayString: String,
        vaultRoot: URL,
        transform: ([Memo]) -> [Memo]?
    ) throws {
        guard let url = fileURL(forDayString: dayString, vaultRoot: vaultRoot) else {
            throw RawStorageError.invalidDayString(dayString)
        }
        // The Date below is the legacy notification object only; the
        // authoritative written key travels in userInfo. It is captured here,
        // before the write — never re-derived from a Date afterwards.
        let notifyDate = date(forDayString: dayString) ?? Date()
        try writeQueue.sync {
            try performMutate(
                at: url,
                vaultRoot: vaultRoot,
                notifyDate: notifyDate,
                transform: transform
            )
        }
    }

    /// Shared serialized mutation body. Callers select the exact target URL
    /// (Date-derived or canonical-key-derived) and enter `writeQueue` first.
    private static func performMutate(
        at url: URL,
        vaultRoot capturedVaultRoot: URL,
        notifyDate: Date,
        transform: ([Memo]) -> [Memo]?
    ) throws {
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

            let outboxRecorded: Bool
            do {
                try SyncOutboxStore.recordChanges(
                    before: existing,
                    after: updated,
                    vaultPath: "raw/\(url.lastPathComponent)",
                    vaultRoot: capturedVaultRoot
                )
                outboxRecorded = true
            } catch {
                outboxRecorded = false
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "outbox mutate record failed for \(url.lastPathComponent): \(error)"
                )
            }

            SentryReporter.breadcrumb(
                category: "rawstorage",
                message: "mutate \(updated.count) memos in \(url.lastPathComponent)"
            )

            WidgetCenter.shared.reloadAllTimelines()
            notifyDidWrite(
                for: notifyDate,
                dayString: url.deletingPathExtension().lastPathComponent
            )

            // R6: enqueue surviving memos for offline sync. Skipping the
            // empty-file branch is intentional: if the user deleted the
            // last memo for a day we have nothing to upload. The transform
            // returning nil bypasses this entire tail (guard above), which
            // is the documented "no-change" path.
            let deletedIDs = Set(existing.map(\.id)).subtracting(updated.map(\.id))
            let enqueuePayload: [(String, Int)] = updated.map { memo in
                (memo.id.uuidString, memo.toMarkdown().utf8.count)
            } + deletedIDs.map { ($0.uuidString, 0) }
            Task { @MainActor in
                if outboxRecorded {
                    SyncQueueService.shared.reloadFromOutbox()
                } else {
                    for (memoIDString, sizeBytes) in enqueuePayload {
                        SyncQueueService.shared.enqueue(memoID: memoIDString, sizeBytes: sizeBytes)
                    }
                }
                await SyncQueueService.shared.flushIfOnline()
            }
    }

    /// Returns the current canonical memo for a stable UUID without exposing
    /// the raw file path. This is used by explicit user filing flows that must
    /// verify a source reference before mutating it.
    public static func memo(id: UUID) -> Memo? {
        writeQueue.sync { findMemoOnDisk(id: id)?.memo }
    }

    /// Adds one already-copied Vault attachment to the referenced memo through
    /// the normal atomic rewrite/outbox path. Exact file references are
    /// idempotent, so recovery after a manifest-write crash cannot duplicate an
    /// attachment. A missing/moved memo returns nil instead of creating one.
    @discardableResult
    public static func appendAttachment(
        _ attachment: Memo.Attachment,
        toMemoID memoID: UUID
    ) throws -> Memo? {
        guard attachment.file.hasPrefix("raw/assets/"),
              !attachment.file.contains(".."),
              let located = writeQueue.sync(execute: { findMemoOnDisk(id: memoID) }) else {
            return nil
        }
        var result: Memo?
        try mutate(for: located.memo.created) { memos in
            guard let index = memos.firstIndex(where: { $0.id == memoID }) else { return nil }
            var memo = memos[index]
            if memo.attachments.contains(where: { $0.file == attachment.file }) {
                result = memo
                return nil
            }
            memo.attachments.append(attachment)
            memo.type = .mixed
            var updated = memos
            updated[index] = memo
            result = memo
            return updated
        }
        return result
    }

    // MARK: - Remote sync application

    /// Applies an ordered page of server changes without echoing those changes
    /// back into the outbox. If the same memo has an unsynced local edit, the
    /// local version is first preserved under a new UUID and remains queued for
    /// upload; the server version then becomes canonical for the original UUID.
    /// This keeps both sides of a concurrent edit instead of silently choosing
    /// a winner and losing text.
    public static func applyRemoteChanges(
        _ changes: [SyncRemoteChange]
    ) throws -> SyncRemoteApplyResult {
        try applyRemoteChanges(changes, afterWrite: { _ in })
    }

    /// Individual durable boundaries, exposed internally for interruption tests.
    /// The callback is invocation-scoped so tests cannot affect another writer.
    enum RemoteApplyWriteStage: CaseIterable {
        case localOutbox
        case conflictCopy
        case conflictOutbox
        case canonicalRemoval
        case canonicalMemo
        case remoteAcknowledgement
    }

    static func applyRemoteChanges(
        _ changes: [SyncRemoteChange],
        afterWrite: (RemoteApplyWriteStage) throws -> Void
    ) throws -> SyncRemoteApplyResult {
        try writeQueue.sync {
            var appliedCount = 0
            var deletedCount = 0
            var conflictCopies: [UUID] = []
            var writtenDayStrings: Set<String> = []

            for change in changes.sorted(by: { $0.changeSequence < $1.changeSequence }) {
                let located = findMemoOnDisk(
                    id: change.id,
                    preferredFile: change.isDeleted ? nil : fileURL(for: change.createdAt)
                )
                let localMemo = located?.memo
                // A raw edit can commit even if its outbox write fails. Repair
                // this one record before trusting pending hashes (including an
                // empty outbox), and fail before replacing raw data if that
                // durable repair is unavailable. An unchanged hash is a no-op.
                if let located {
                    try SyncOutboxStore.recordUpsert(
                        located.memo, vaultPath: "raw/\(located.file.lastPathComponent)"
                    )
                    try afterWrite(.localOutbox)
                }
                let pending = try SyncOutboxStore.pendingOperation(for: change.id)
                let remoteMemo = change.isDeleted
                    ? nil
                    : change.makeMemo(preservingLocalMetadata: localMemo)
                // Compare/acknowledge what the raw reader can actually restore:
                // dates have millisecond precision and body edge whitespace is
                // normalized by the existing Markdown parser.
                let canonicalRemote = remoteMemo.flatMap { Memo.fromMarkdown($0.toMarkdown()) }

                let pendingMatchesRemote = !change.isDeleted
                    && pending?.kind == .upsert
                    && pending?.contentHash != nil
                    && pending?.contentHash == change.contentHash
                    && pending?.contentHash == localMemo.map { SyncOutboxStore.contentHash(for: $0) }
                    && change.attachmentManifestHash == nil
                    && localMemo?.attachments.isEmpty != false

                // Reconciliation can have refreshed the pending operation after
                // an interrupted canonical write. An exact canonical match is
                // already applied; preserving it again would echo the remote
                // version as another conflict on every restart.
                let canonicalMatchesRemote = canonicalRemote != nil && localMemo == canonicalRemote
                if let located {
                    // Destination-first moves can leave a source with the same
                    // ID after interruption. It may have been edited since the
                    // crash; the sidecar cannot prove that it is stale. Preserve
                    // each different source version before removing duplicate
                    // IDs, even if this conservatively retains an old version.
                    for source in try memoLocations(id: change.id) where !sameFileLocation(source.file, located.file) {
                        let preserved = try preserveMovedSource(
                            source.memo,
                            writtenDayStrings: &writtenDayStrings,
                            afterWrite: afterWrite
                        )
                        conflictCopies.append(preserved.id)
                    }
                }
                if let pending, !pendingMatchesRemote, !canonicalMatchesRemote {
                    // The operation ID is minted once and persisted before this
                    // pull. Reusing it as the conflict memo ID makes retries
                    // stable without adding a journal or changing the format.
                    // Never overwrite an existing copy: the canonical may
                    // already be the remote version after an interruption.
                    var conflictCopy = findMemoOnDisk(id: pending.operationID)?.memo
                    if conflictCopy == nil, var preserved = localMemo {
                        preserved.id = pending.operationID
                        try insertMemoOnDisk(preserved, writtenDayStrings: &writtenDayStrings)
                        try afterWrite(.conflictCopy)
                        conflictCopy = preserved
                    }
                    if let conflictCopy {
                        try SyncOutboxStore.recordUpsert(
                            conflictCopy,
                            vaultPath: "raw/\(fileURL(for: conflictCopy.created).lastPathComponent)"
                        )
                        try afterWrite(.conflictOutbox)
                        conflictCopies.append(conflictCopy.id)
                    }
                }

                try replaceMemoOnDisk(
                    id: change.id,
                    with: remoteMemo,
                    writtenDayStrings: &writtenDayStrings,
                    afterWrite: afterWrite
                )
                try SyncOutboxStore.acceptRemoteChange(
                    memo: canonicalRemote ?? remoteMemo,
                    memoID: change.id,
                    remoteRevision: change.syncRevision,
                    deleted: change.isDeleted
                )
                try afterWrite(.remoteAcknowledgement)

                if change.isDeleted {
                    deletedCount += 1
                } else {
                    appliedCount += 1
                }
            }

            WidgetCenter.shared.reloadAllTimelines()
            // One notification per ACTUAL written raw file key, captured from
            // the written URLs — never re-derived from a memo Date through the
            // mutable preferred zone. The Date object stays for legacy
            // subscribers; the authoritative key travels in userInfo.
            for dayString in writtenDayStrings.sorted() {
                notifyDidWrite(
                    for: date(forDayString: dayString) ?? Date(),
                    dayString: dayString
                )
            }
            return SyncRemoteApplyResult(
                appliedCount: appliedCount,
                deletedCount: deletedCount,
                conflictCopies: conflictCopies
            )
        }
    }

    private static func findMemoOnDisk(id: UUID, preferredFile: URL? = nil) -> (memo: Memo, file: URL)? {
        let rawDirectory = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rawDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let target = id.uuidString.lowercased()
        // A moved-day write commits the destination before removing the source.
        // On replay, use that committed destination rather than mistaking the
        // stale source for a new local edit after outbox reconciliation.
        let orderedFiles = files.filter { sameFileLocation($0, preferredFile) }
            + files.filter { !sameFileLocation($0, preferredFile) }
        for file in orderedFiles where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  content.lowercased().contains(target) else { continue }
            if let memo = parse(fileContent: content, sourceFile: file).first(where: {
                $0.id == id
            }) {
                return (memo, file)
            }
        }
        return nil
    }

    private static func replaceMemoOnDisk(
        id: UUID,
        with replacement: Memo?,
        writtenDayStrings: inout Set<String>,
        afterWrite: (RemoteApplyWriteStage) throws -> Void
    ) throws {
        let target = replacement.map { fileURL(for: $0.created) }
        if let replacement, let target {
            let existing: [Memo]
            if FileManager.default.fileExists(atPath: target.path) {
                let content = try String(contentsOf: target, encoding: .utf8)
                existing = parse(fileContent: content, sourceFile: target)
            } else {
                existing = []
            }
            var updated = existing.filter { $0.id != id }
            updated.append(replacement)
            try writeRemoteMemoList(updated, to: target)
            writtenDayStrings.insert(target.deletingPathExtension().lastPathComponent)
            try afterWrite(.canonicalMemo)
        }

        // A move must never leave a window with no canonical record. The
        // destination is durable first, then every old occurrence is removed.
        // Retrying after either write also cleans a temporarily duplicated ID.
        let rawDirectory = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        guard FileManager.default.fileExists(atPath: rawDirectory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: rawDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let idText = id.uuidString.lowercased()
        for file in files where file.pathExtension == "md" && !sameFileLocation(file, target) {
            let content = try String(contentsOf: file, encoding: .utf8)
            guard content.lowercased().contains(idText) else { continue }
            let existing = parse(fileContent: content, sourceFile: file)
            let updated = existing.filter { $0.id != id }
            guard updated.count != existing.count else { continue }
            try writeRemoteMemoList(updated, to: file)
            writtenDayStrings.insert(file.deletingPathExtension().lastPathComponent)
            try afterWrite(.canonicalRemoval)
        }
    }

    private static func sameFileLocation(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        // URL equality also compares representation (relative bases, aliases).
        // Destructive duplicate cleanup must compare actual file locations.
        return lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func memoLocations(id: UUID? = nil) throws -> [(memo: Memo, file: URL)] {
        let rawDirectory = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: rawDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return try files.filter { $0.pathExtension == "md" }.flatMap { file in
            try parse(fileContent: String(contentsOf: file, encoding: .utf8), sourceFile: file)
                .filter { id == nil || $0.id == id }
                .map { (memo: $0, file: file) }
        }
    }

    private static func preserveMovedSource(
        _ source: Memo,
        writtenDayStrings: inout Set<String>,
        afterWrite: (RemoteApplyWriteStage) throws -> Void
    ) throws -> Memo {
        // An earlier conflict copy may already preserve this exact preimage.
        // Reuse it rather than adding a second memo during crash recovery.
        var copy = try memoLocations().first { candidate in
            guard candidate.memo.id != source.id else { return false }
            var comparable = candidate.memo
            comparable.id = source.id
            return comparable == source
        }?.memo
        if copy == nil {
            var preserved = source
            // UUID v5: original memo as namespace, canonical content as name.
            // Stable across process restarts and outbox reconciliation without
            // adding any raw metadata or a new recovery sidecar format.
            var namespace = source.id.uuid
            var name = withUnsafeBytes(of: &namespace) { Array($0) }
            name.append(contentsOf: Data(("daypage-move-recovery-v1:" + source.toMarkdown()).utf8))
            var digest = Array(Insecure.SHA1.hash(data: Data(name)).prefix(16))
            digest[6] = (digest[6] & 0x0f) | 0x50
            digest[8] = (digest[8] & 0x3f) | 0x80
            preserved.id = UUID(uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
            // A user may have amended that recovery copy since the crash.
            copy = findMemoOnDisk(id: preserved.id)?.memo
            if copy == nil {
                try insertMemoOnDisk(preserved, writtenDayStrings: &writtenDayStrings)
                try afterWrite(.conflictCopy)
                copy = preserved
            }
        }
        guard let copy else { throw RawStorageError.readFailed(fileURL(for: source.created)) }
        try SyncOutboxStore.recordUpsert(copy, vaultPath: "raw/\(fileURL(for: copy.created).lastPathComponent)")
        try afterWrite(.conflictOutbox)
        return copy
    }

    private static func insertMemoOnDisk(
        _ memo: Memo,
        writtenDayStrings: inout Set<String>
    ) throws {
        let target = fileURL(for: memo.created)
        let existing: [Memo]
        if FileManager.default.fileExists(atPath: target.path) {
            let content = try String(contentsOf: target, encoding: .utf8)
            existing = parse(fileContent: content, sourceFile: target)
        } else {
            existing = []
        }
        var updated = existing.filter { $0.id != memo.id }
        updated.append(memo)
        try writeRemoteMemoList(updated, to: target)
        writtenDayStrings.insert(target.deletingPathExtension().lastPathComponent)
    }

    private static func writeRemoteMemoList(_ memos: [Memo], to file: URL) throws {
        if memos.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } else {
            try atomicWrite(string: serialize(memos), to: file)
        }
    }

    // MARK: - Read

    /// 读取给定日期日文件中的所有 Memo。
    /// 如果文件不存在或不包含有效的 memo，返回空数组。
    public static func read(for date: Date) throws -> [Memo] {
        try read(for: date, vaultRoot: VaultInitializer.vaultURL)
    }

    public static func read(for date: Date, vaultRoot: URL) throws -> [Memo] {
        let url = fileURL(for: date, vaultRoot: vaultRoot)
        return try read(at: url)
    }

    /// Canonical owning-day read boundary. The exact raw URL is selected
    /// directly from the validated `YYYY-MM-DD` key — independent of the
    /// current preferred zone — and fails closed on an invalid key.
    public static func read(dayString: String, vaultRoot: URL) throws -> [Memo] {
        guard let url = fileURL(forDayString: dayString, vaultRoot: vaultRoot) else {
            throw RawStorageError.invalidDayString(dayString)
        }
        return try read(at: url)
    }

    private static func read(at url: URL) throws -> [Memo] {
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
    public static func parse(fileContent: String) -> [Memo] {
        parse(fileContent: fileContent, sourceFile: nil)
    }

    /// Internal entry point that knows the source filename, used for
    /// quarantining unparseable blocks. Callers in production (`read`,
    /// `mutate`) supply the day file URL so the quarantine path can derive
    /// `YYYY-MM-DD-{sha8}.md`. Tests can still call the public 1-arg overload.
    public static func parse(fileContent: String, sourceFile: URL?) -> [Memo] {
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
    public static func quarantineBrokenBlock(_ block: String, sourceFile: URL, reason: String) {
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
    public static func atomicWrite(string: String, to url: URL) throws {
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
    public static func atomicWrite(data: Data, to url: URL) throws {
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
    public static func pruneTrashOlderThan(days: Int = 7) {
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
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = StorageSettings.currentTimeZone()
        return f
    }

    // Second-precision stamp for asset filenames. Device-local time so the
    // filename matches the wall-clock moment of capture.
    private static var assetTimestampFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }
}
