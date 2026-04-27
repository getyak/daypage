import Foundation

// MARK: - ConflictResolutionInfo

struct ConflictResolutionInfo {
    let date: Date
    let mergedMemoCount: Int
    let sourceDevice: String
}

extension Notification.Name {
    static let vaultConflictResolved = Notification.Name("vaultConflictResolved")
}

// MARK: - ConflictMerger

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
            // 冲突无法解决；系统将重试。
        }
    }

    private static func resolveMDConflict(primaryURL: URL, conflictVersions: [NSFileVersion]) throws {
        // 判断是原始备忘录文件（vault/raw/YYYY-MM-DD.md）还是日志文件。
        let pathComponents = primaryURL.pathComponents
        let isRaw = pathComponents.contains("raw") && !pathComponents.contains("assets")

        let originalData = try Data(contentsOf: primaryURL)

        if isRaw {
            var original = parseMemos(from: originalData)
            for version in conflictVersions {
                if let conflictData = try? Data(contentsOf: version.url) {
                    let conflictMemos = parseMemos(from: conflictData)
                    original = mergeRawMemos(original: original, conflict: conflictMemos)
                }
            }
            let merged = original.map { $0.toMarkdown() }.joined(separator: "\n\n---\n\n")
            try writeMerged(data: Data(merged.utf8), to: primaryURL)
        } else {
            // 日志/wiki 文件：按行时间戳前缀去重。
            var merged = String(data: originalData, encoding: .utf8) ?? ""
            for version in conflictVersions {
                if let conflictData = try? Data(contentsOf: version.url),
                   let conflictText = String(data: conflictData, encoding: .utf8) {
                    merged = mergeLogLines(original: merged, conflict: conflictText)
                }
            }
            try writeMerged(data: Data(merged.utf8), to: primaryURL)
        }
    }

    private static func resolveJSONConflict(primaryURL: URL, conflictVersions: [NSFileVersion]) throws {
        var original = try Data(contentsOf: primaryURL)
        for version in conflictVersions {
            if let conflictData = try? Data(contentsOf: version.url) {
                original = mergeJSONEntries(original: original, conflict: conflictData, idKey: "id")
            }
        }
        try writeMerged(data: original, to: primaryURL)
    }

    private static func writeMerged(data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let err = coordinatorError ?? writeError { throw err }
    }

    private static func parseMemos(from data: Data) -> [Memo] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n\n---\n\n").compactMap { Memo.fromMarkdown($0) }
    }
}
