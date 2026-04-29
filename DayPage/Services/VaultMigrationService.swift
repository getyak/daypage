import Foundation
import CryptoKit
import SwiftUI

// MARK: - MigrationError

enum MigrationError: LocalizedError {
    case iCloudUnavailable
    case verificationFailed(details: String)
    case fileCopyFailed(path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud 不可用，无法迁移"
        case .verificationFailed(let details):
            return "验证失败：\(details)"
        case .fileCopyFailed(let path, let err):
            return "文件复制失败 \(path)：\(err.localizedDescription)"
        }
    }
}

// MARK: - MigrationProgress

struct MigrationProgress {
    let copied: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(copied) / Double(total) : 0 }
}

// MARK: - VaultMigrationService

@MainActor
final class VaultMigrationService: ObservableObject {

    static let shared = VaultMigrationService()
    private init() {}

    @Published var isMigrating: Bool = false
    @Published var migrationProgress: MigrationProgress = MigrationProgress(copied: 0, total: 0)
    @Published var migrationError: String? = nil

    // MARK: - Public migration entry point

    /// 将所有文件从 localVault 复制到 iCloudVault，保留目录结构和 modificationDate，
    /// 验证完整性，然后更新 AppSettings。失败时抛出异常。
    func migrateToiCloud(
        localVault: URL,
        iCloudVault: URL,
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        isMigrating = true
        migrationError = nil
        defer { isMigrating = false }

        let fm = FileManager.default

        // 枚举 localVault 中的所有文件
        guard let enumerator = fm.enumerator(
            at: localVault,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MigrationError.verificationFailed(details: "无法枚举本地 vault")
        }

        var filesToCopy: [URL] = []
        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir { filesToCopy.append(fileURL) }
        }

        let total = filesToCopy.count
        var logEntries: [String] = ["migration started: \(Date().iso8601String)", "total files: \(total)"]
        var copyErrors: [String] = []

        let localVaultPathPrefix = localVault.path.hasSuffix("/") ? localVault.path : localVault.path + "/"

        for (index, sourceURL) in filesToCopy.enumerated() {
            // 使用前缀删除而非 replacingOccurrences 以防止路径遍历
            // 当 localVault.path 在 sourceURL.path 中出现多次时。
            guard sourceURL.path.hasPrefix(localVaultPathPrefix) else { continue }
            let relativePath = String(sourceURL.path.dropFirst(localVaultPathPrefix.count))
            guard !relativePath.contains("..") else { continue }
            let destURL = iCloudVault.appendingPathComponent(relativePath)

            let destDir = destURL.deletingLastPathComponent()
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            do {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: sourceURL, to: destURL)

                // 保留修改日期
                if let modDate = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    try? fm.setAttributes([.modificationDate: modDate], ofItemAtPath: destURL.path)
                }

                let fileSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
                logEntries.append("success: \(relativePath) (\(fileSize) bytes)")
            } catch {
                copyErrors.append(relativePath)
                logEntries.append("failed: \(relativePath) - \(error.localizedDescription)")
                throw MigrationError.fileCopyFailed(path: relativePath, underlying: error)
            }

            let copied = index + 1
            await MainActor.run {
                self.migrationProgress = MigrationProgress(copied: copied, total: total)
            }
            progress(copied, total)
        }

        // 将 migration.log 写入 iCloud
        let logContent = logEntries.joined(separator: "\n")
        let logURL = iCloudVault.appendingPathComponent("migration.log")
        try? logContent.data(using: .utf8)?.write(to: logURL, options: .atomic)

        // 验证步骤
        try verifyMigration(localVault: localVault, iCloudVault: iCloudVault, fm: fm)

        // 成功 —— 更新设置
        AppSettings.shared.vaultLocation = .iCloud
        AppSettings.shared.migrationCompletedAt = Date()
    }

    // MARK: - Verification

    func verifyMigration(localVault: URL, iCloudVault: URL, fm: FileManager) throws {
        // 比较文件数量
        let localFiles = allFiles(in: localVault, fm: fm)
        let icloudFiles = allFiles(in: iCloudVault, fm: fm)

        // iCloud vault 可能有额外的 migration.log；允许 +1
        if icloudFiles.count < localFiles.count {
            throw MigrationError.verificationFailed(
                details: "文件数量不匹配：本地 \(localFiles.count)，iCloud \(icloudFiles.count)"
            )
        }

        // 对 3 个最大的 raw/*.md 文件进行哈希
        let rawFiles = localFiles
            .filter { $0.contains("/raw/") && $0.hasSuffix(".md") }
            .compactMap { relPath -> (String, Int)? in
                let url = localVault.appendingPathComponent(relPath)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                return (relPath, size)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { $0.0 }

        // Hash 3 latest wiki/daily/*.md files
        let wikiFiles = localFiles
            .filter { $0.contains("/wiki/daily/") && $0.hasSuffix(".md") }
            .sorted()
            .suffix(3)

        let filesToVerify = Array(rawFiles) + Array(wikiFiles)

        for relativePath in filesToVerify {
            let localURL = localVault.appendingPathComponent(relativePath)
            let icloudURL = iCloudVault.appendingPathComponent(relativePath)

            guard let localHash = sha256(of: localURL),
                  let icloudHash = sha256(of: icloudURL) else {
                throw MigrationError.verificationFailed(details: "无法读取文件：\(relativePath)")
            }

            if localHash != icloudHash {
                throw MigrationError.verificationFailed(details: "哈希不匹配：\(relativePath)")
            }
        }
    }

    private func allFiles(in directory: URL, fm: FileManager) -> [String] {
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var files: [String] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir, url.path.hasPrefix(prefix) {
                let relative = String(url.path.dropFirst(prefix.count))
                if !relative.hasSuffix("migration.log") {
                    files.append(relative)
                }
            }
        }
        return files
    }

    // Stream the file in 256 KB chunks to avoid loading large media files into memory.
    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 256 * 1024
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Local backup cleanup

    /// Deletes the local vault backup after the user confirms they no longer need it.
    /// Only safe to call when vaultLocation == .iCloud and 30-day window has passed.
    /// Clears migrationCompletedAt so the cleanup button disappears after use.
    func deleteLocalBackup() throws {
        let localVault = LocalVaultLocator().vaultURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: localVault.path) else {
            AppSettings.shared.migrationCompletedAt = nil
            return
        }
        try fm.removeItem(at: localVault)
        AppSettings.shared.migrationCompletedAt = nil
    }

    // MARK: - Auto-migration trigger

    /// Called from VaultInitializer when iCloud becomes available.
    /// Migrates if: iCloud is usable, vaultLocation == .local, and local vault is non-empty.
    func migrateIfNeeded() {
        let locator = iCloudVaultLocator()
        guard locator.isUsingiCloud else { return }
        guard AppSettings.shared.vaultLocation == .local else { return }

        let localVault = LocalVaultLocator().vaultURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: localVault.path) else { return }

        // Check non-empty: must have at least one raw/*.md file
        let rawDir = localVault.appendingPathComponent("raw")
        guard let contents = try? fm.contentsOfDirectory(atPath: rawDir.path),
              !contents.filter({ $0.hasSuffix(".md") }).isEmpty else { return }

        let iCloudVault = locator.vaultURL

        Task { @MainActor in
            do {
                try await self.migrateToiCloud(
                    localVault: localVault,
                    iCloudVault: iCloudVault,
                    progress: { _, _ in }
                )
                // Swap runtime locator to iCloud
                VaultInitializer.shared = locator
            } catch {
                self.migrationError = error.localizedDescription
            }
        }
    }
}

// MARK: - Date helper

private extension Date {
    var iso8601String: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: self)
    }
}

// MARK: - MigrationProgressView

struct MigrationProgressSheet: View {
    @ObservedObject var service: VaultMigrationService

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 48))
                .foregroundColor(DSColor.primary)

            Text("正在迁移到 iCloud")
                .font(.custom("SpaceGrotesk-Bold", size: 20))
                .foregroundColor(DSColor.onSurface)

            ProgressView(value: service.migrationProgress.fraction)
                .tint(DSColor.primary)
                .frame(maxWidth: 280)

            Text("\(service.migrationProgress.copied) / \(service.migrationProgress.total) 个文件")
                .font(.custom("Inter-Regular", size: 14))
                .foregroundColor(DSColor.onSurfaceVariant)

            Text("请勿关闭应用")
                .font(.custom("Inter-Regular", size: 12))
                .foregroundColor(DSColor.onSurfaceVariant)
        }
        .padding(40)
        .interactiveDismissDisabled(true)
    }
}
