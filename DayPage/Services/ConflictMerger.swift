import Foundation
import Sentry

// MARK: - ConflictResolutionInfo

struct ConflictResolutionInfo {
    let date: Date
    let mergedMemoCount: Int
    let sourceDevice: String
}

extension Notification.Name {
    static let vaultConflictResolved = Notification.Name("vaultConflictResolved")
    static let vaultConflictFailed = Notification.Name("vaultConflictFailed")

    /// Posted by RawStorage after a raw day-file write/delete. `object` is the
    /// affected day's `Date`. TimelineIndex listens to update incrementally.
    static let rawStorageDidWrite = Notification.Name("rawStorageDidWrite")
}

// MARK: - Conflict Merge Strategy (R4-MEDIUM #38)
//
// When iCloud reports an unresolved conflict on a vault file (it materialises
// a sibling .conflicted file alongside the canonical one), ConflictMerger
// runs in three layers:
//
//   1. Memo arrays — mergeRawMemos(original:conflict:)
//      Concatenate both arrays, sort by `created`, then drop duplicates by
//      UUID, preserving the earliest occurrence. This is the safest default
//      because memo IDs are stable across devices, so concurrent additions
//      from two phones are merged rather than overwritten.
//
//   2. Wiki append-only logs — mergeWikiLines(original:conflict:)
//      Both copies are line-sets; union them and re-sort. Append-only files
//      cannot lose data this way; duplicate lines collapse via Set.
//
//   3. JSON entry maps — mergeJSONEntries(original:conflict:)
//      Keys are dates / entity ids. For each key present in both copies we
//      keep the entry with the later `mtime` (last-writer-wins on a key).
//      Ties fall back to the *longer* serialized form (heuristic: a user is
//      far more likely to append to a daily entry than to truncate it).
//
// File-level winner selection (used when we have to pick *one* side, e.g.
// for the rare case where a layer is opaque):
//   a. Compare NSFileVersion.modificationDate — take the newest one.
//   b. If timestamps tie, take the version whose serialized payload is
//      longer (additive-writes heuristic, same reasoning as JSON map ties).
//
// After a successful merge, ConflictMerger posts:
//   • Notification.Name.vaultConflictResolved (object = ConflictResolutionInfo)
//     — listened to by TodayView, which surfaces an orange banner explaining
//     "detected an iCloud conflict — kept the most recent version (date)".
//   • Notification.Name.vaultConflictFailed when the merge itself errors out
//     so we can fall back to surfacing the .conflicted file to the user.
//
// `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` drives detection;
// once we have a merged payload we persist it via the atomic
// `FileManager.replaceItem` path used by RawStorage, then call
// `NSFileVersion.removeOtherVersionsOfItem(at:)` so the sibling .conflicted
// files disappear from the UI.

/// 合并原始备忘录文件、wiki 日志行及 JSON 条目的 iCloud 冲突副本。
/// 冲突检测由 NSMetadataQuery 监听 NSMetadataUbiquitousItemHasUnresolvedConflictsKey 驱动。
enum ConflictMerger {

    // MARK: - Memo Merge

    /// 合并两个 Memo 对象数组。
    /// 算法：拼接，按 created 升序排列，按 UUID 去重（保留首个）。
    static func mergeRawMemos(original: [Memo], conflict: [Memo]) -> [Memo] {
        let combined = (original + conflict).sorted { $0.created < $1.created }
        var seen = Set<UUID>()
        return combined.filter { memo in
            guard !seen.contains(memo.id) else { return false }
            seen.insert(memo.id)
            return true
        }
    }

    // MARK: - Log Line Merge

    /// 合并两个 wiki/log.md 字符串，按时间戳前缀（首个 token）去重。
    static func mergeLogLines(original: String, conflict: String) -> String {
        let originalLines = original.components(separatedBy: "\n")
        let conflictLines = conflict.components(separatedBy: "\n")
        var seen = Set<String>()
        var merged: [String] = []

        for line in originalLines + conflictLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // 使用以空格分隔的第一个 token 作为去重键（时间戳前缀）。
            let key = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(line)
        }

        return merged.joined(separator: "\n")
    }

    // MARK: - JSON Entry Merge

    /// 合并两个 JSON 数组，按给定 idKey 字段值去重。
    /// 若任一输入无法解析为 JSON 数组，则返回原始数据。
    static func mergeJSONEntries(original: Data, conflict: Data, idKey: String) -> Data {
        guard
            let originalArray = try? JSONSerialization.jsonObject(with: original) as? [[String: Any]],
            let conflictArray = try? JSONSerialization.jsonObject(with: conflict) as? [[String: Any]]
        else {
            return original
        }

        var seen = Set<String>()
        var merged: [[String: Any]] = []

        for entry in originalArray + conflictArray {
            guard let idValue = entry[idKey].flatMap({ "\($0)" }) else {
                merged.append(entry)
                continue
            }
            guard !seen.contains(idValue) else { continue }
            seen.insert(idValue)
            merged.append(entry)
        }

        return (try? JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)) ?? original
    }

    // MARK: - iCloud Conflict Resolution

    /// 扫描 vault URL 中的 iCloud 冲突副本并解决。
    /// 使用 NSMetadataQuery 查找有未解决冲突的文件，合并内容，
    /// 并在每次成功解决后发送 .vaultConflictResolved 通知。
    static func resolveConflictsIfNeeded(in vaultURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vaultURL.path) else { return }

        // 收集 vaultURL 下所有存在未解决冲突的文件。
        guard let enumerator = fm.enumerator(at: vaultURL,
                                             includingPropertiesForKeys: [.ubiquitousItemHasUnresolvedConflictsKey],
                                             options: [.skipsHiddenFiles]) else { return }

        var conflictedURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
            if values?.ubiquitousItemHasUnresolvedConflicts == true {
                conflictedURLs.append(fileURL)
            }
        }

        for primaryURL in conflictedURLs {
            resolveConflict(at: primaryURL)
        }
    }

    // MARK: - Private Helpers

    private static func resolveConflict(at primaryURL: URL) {
        guard let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: primaryURL),
              !conflictVersions.isEmpty else { return }

        let ext = primaryURL.pathExtension

        do {
            if ext == "md" {
                try resolveMDConflict(primaryURL: primaryURL, conflictVersions: conflictVersions)
            } else if ext == "json" {
                try resolveJSONConflict(primaryURL: primaryURL, conflictVersions: conflictVersions)
            }

            // 将所有冲突版本标记为已解决并删除。
            for version in conflictVersions {
                version.isResolved = true
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: primaryURL)

            let device = conflictVersions.first?.localizedNameOfSavingComputer ?? "unknown"
            let info = ConflictResolutionInfo(date: Date(), mergedMemoCount: conflictVersions.count, sourceDevice: device)
            NotificationCenter.default.post(name: .vaultConflictResolved, object: info)
        } catch {
            DayPageLogger.log(
                level: "ERROR",
                message: "[ConflictMerger] Failed to resolve conflict at \(primaryURL.lastPathComponent): \(error)"
            )
            if !Secrets.sentryDSN.isEmpty { SentrySDK.capture(error: error) }
            NotificationCenter.default.post(name: .vaultConflictFailed, object: primaryURL)
        }
    }

    private static func resolveMDConflict(primaryURL: URL, conflictVersions: [NSFileVersion]) throws {
        // 判断是原始备忘录文件（vault/raw/YYYY-MM-DD.md）还是日志文件。
        let pathComponents = primaryURL.pathComponents
        let isRaw = pathComponents.contains("raw") && !pathComponents.contains("assets")

        let originalData = try Data(contentsOf: primaryURL)

        if isRaw {
            var original = parseMemos(from: originalData)
            let beforeCount = original.count
            for version in conflictVersions {
                do {
                    let conflictData = try Data(contentsOf: version.url)
                    let conflictMemos = parseMemos(from: conflictData)
                    original = mergeRawMemos(original: original, conflict: conflictMemos)
                } catch {
                    // C7 fix: instead of silently skipping (which lost the
                    // conflict version's memos forever after isResolved=true),
                    // quarantine the raw bytes so they survive for manual
                    // recovery. If even the raw copy fails, escalate to Sentry
                    // with NSFileVersion metadata so the loss is observable.
                    quarantineConflictVersion(
                        version: version,
                        primaryURL: primaryURL,
                        reason: "read-failed: \(error)"
                    )
                    DayPageLogger.log(
                        level: "WARN",
                        message: "[ConflictMerger] Could not read conflict version for \(primaryURL.lastPathComponent): \(error) — quarantined for recovery"
                    )
                }
            }
            let afterCount = original.count
            SentryReporter.breadcrumb(
                category: "conflict_merger",
                level: afterCount < beforeCount ? .warning : .info,
                message: "merged \(primaryURL.lastPathComponent): \(beforeCount) primary + conflict versions → \(afterCount) memos"
            )
            if afterCount < beforeCount {
                DayPageLogger.log(
                    level: "WARN",
                    message: "[ConflictMerger] Memo count decreased after merge of \(primaryURL.lastPathComponent): \(beforeCount) → \(afterCount)"
                )
            }
            let merged = original.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
            try writeMerged(data: Data(merged.utf8), to: primaryURL)
        } else {
            // 日志/wiki 文件：按行时间戳前缀去重。
            var merged = String(data: originalData, encoding: .utf8) ?? ""
            for version in conflictVersions {
                do {
                    let conflictData = try Data(contentsOf: version.url)
                    if let conflictText = String(data: conflictData, encoding: .utf8) {
                        merged = mergeLogLines(original: merged, conflict: conflictText)
                    }
                } catch {
                    quarantineConflictVersion(
                        version: version,
                        primaryURL: primaryURL,
                        reason: "log-read-failed: \(error)"
                    )
                    DayPageLogger.log(level: "WARN",
                                     message: "[ConflictMerger] Skipping unreadable log conflict version \(version.url.lastPathComponent): \(error) — quarantined for recovery")
                }
            }
            try writeMerged(data: Data(merged.utf8), to: primaryURL)
        }
    }

    // C7 fix: copy the conflict version's raw bytes into
    // `vault/raw/.broken/conflict-quarantine/` before NSFileVersion drops it.
    // If even the raw copy fails (e.g., iCloud not yet downloaded), emit a
    // Sentry event with the NSFileVersion metadata so the loss is observable.
    private static func quarantineConflictVersion(version: NSFileVersion, primaryURL: URL, reason: String) {
        let rawBytes = try? Data(contentsOf: version.url)
        let dir = primaryURL.deletingLastPathComponent()
            .appendingPathComponent(".broken", isDirectory: true)
            .appendingPathComponent("conflict-quarantine", isDirectory: true)
        let timestamp = Int(version.modificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
        let stem = primaryURL.deletingPathExtension().lastPathComponent
        let ext = primaryURL.pathExtension.isEmpty ? "md" : primaryURL.pathExtension
        let target = dir.appendingPathComponent("\(stem)-conflict-\(timestamp).\(ext)")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = rawBytes {
                try RawStorage.atomicWrite(data: data, to: target)
                SentryReporter.breadcrumb(
                    category: "conflict_merger",
                    level: .warning,
                    message: "quarantined conflict version → \(target.lastPathComponent) reason=\(reason)"
                )
            } else {
                // Raw bytes unreadable too — surface enough metadata that a
                // human can correlate the loss with an iCloud transient.
                SentryReporter.breadcrumb(
                    category: "conflict_merger",
                    level: .error,
                    message: "conflict version unrecoverable for \(primaryURL.lastPathComponent) modifier=\(version.localizedNameOfSavingComputer ?? "?") at=\(String(describing: version.modificationDate)) reason=\(reason)"
                )
            }
        } catch {
            SentryReporter.breadcrumb(
                category: "conflict_merger",
                level: .error,
                message: "quarantine write failed for \(primaryURL.lastPathComponent): \(error) (original reason=\(reason))"
            )
        }
    }

    private static func resolveJSONConflict(primaryURL: URL, conflictVersions: [NSFileVersion]) throws {
        var original = try Data(contentsOf: primaryURL)
        for version in conflictVersions {
            do {
                let conflictData = try Data(contentsOf: version.url)
                original = mergeJSONEntries(original: original, conflict: conflictData, idKey: "id")
            } catch {
                DayPageLogger.log(level: "WARN",
                                 message: "[ConflictMerger] Skipping unreadable JSON conflict version \(version.url.lastPathComponent): \(error)")
            }
        }
        try writeMerged(data: original, to: primaryURL)
    }

    private static func writeMerged(data: Data, to url: URL) throws {
        // Delegate to RawStorage.atomicWrite — it does NSFileCoordinator *and*
        // an explicit temp-file + replaceItemAt rename inside the coordinator
        // block, so a crash mid-write cannot leave a partial or zero-length
        // file on disk. The prior `data.write(.atomic)` gave only per-call
        // atomicity and lost the temp-file recovery path on coordinator failure.
        try RawStorage.atomicWrite(data: data, to: url)
    }

    private static func parseMemos(from data: Data) -> [Memo] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return RawStorage.parse(fileContent: text)
    }
}
