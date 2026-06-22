// VaultExportService.swift — R11 data layer (manifest-only step)
//
// Scope of this file (intentionally narrow):
//   Produce a summary manifest (counts + byte total) of everything inside the
//   user's vault so the upcoming VaultExportView (R13+) can render a
//   "what's about to be backed up" preview before the user taps "Export".
//
// What this file deliberately does NOT do (left for later rounds):
//   - Build the actual zip archive (R11 follow-up).
//   - Surface UI / Settings entry (R13+).
//   - Touch CompilationService / SyncQueue / iCloud — pure read-only scan.
//
// Why a "manifest" first:
//   On a heavy vault (a year of daily memos + photos) the zip step is the slow
//   part. We want the user to see counts + size before we burn CPU/disk, and
//   we want a deterministic seam unit tests can hit without going through the
//   `@MainActor` singleton.
//
// Threading:
//   `collectExportManifest()` is `@MainActor async` so callers can `await` it
//   from SwiftUI views; the actual file walk happens off the main actor via
//   `Task.detached` so we don't hitch the UI on a multi-thousand-file scan.

import Foundation

/// Errors surfaced by `VaultExportService`. Equatable so SwiftUI views can
/// pattern-match the `.noData` case to render an empty-state, and tests can
/// assert with `#expect(error == .vaultNotFound)`.
enum VaultExportError: Error, Equatable {
    /// Vault root directory itself is missing — usually means
    /// `VaultInitializer.initializeIfNeeded()` was never called (first launch
    /// crash window) or iCloud container vanished mid-session.
    case vaultNotFound
    /// Vault exists but is completely empty (0 raw, 0 daily, 0 entity, 0
    /// asset). Distinct from `.vaultNotFound` so the UI can say "nothing to
    /// export yet" rather than "vault missing — try reopening the app".
    case noData
}

/// Summary of what an export would contain. All counts are non-negative.
/// `estimatedTotalBytes` is the sum of every file's `.fileSizeKey` — does NOT
/// include the zip overhead that a future implementation will add, hence the
/// "estimated" qualifier.
struct ExportManifest: Equatable {
    /// Number of `vault/raw/*.md` files (one per day, or one per Memo group).
    let rawMemoCount: Int
    /// Number of `vault/wiki/daily/*.md` compiled diary pages.
    let dailyPageCount: Int
    /// Combined count of places + people + themes — the union "entity wiki".
    let entityCount: Int
    /// Number of files anywhere under `vault/raw/assets/` (recursive — photos
    /// live in `assets/photos/`, voice in `assets/audio/`, etc.).
    let assetCount: Int
    /// Sum of every file's byte size across all of the above. Int64 because
    /// a year of 4K photos easily passes the Int32 ceiling on 32-bit slices.
    let estimatedTotalBytes: Int64
}

/// Read-only service that walks the vault and produces an `ExportManifest`.
/// Singleton because the `@MainActor` isolation is the only state it needs;
/// the heavy lifting is a pure static helper (`computeManifest(vaultURL:)`)
/// so tests can inject a fixture vault without touching `VaultInitializer`.
@MainActor
final class VaultExportService {
    static let shared = VaultExportService()
    private init() {}

    /// Scan the live vault and produce summary counts. Used by
    /// `VaultExportView` (R13+) to render a "ready to export" preview.
    ///
    /// - Throws: `.vaultNotFound` if `VaultInitializer.vaultURL` doesn't exist
    ///           on disk; `.noData` if every count came back zero.
    ///
    /// The file walk runs on a detached background task so a multi-thousand-
    /// file scan doesn't hitch the main actor.
    func collectExportManifest() async throws -> ExportManifest {
        let vaultURL = VaultInitializer.vaultURL
        return try await Task.detached(priority: .userInitiated) {
            guard let manifest = try VaultExportService.computeManifest(vaultURL: vaultURL) else {
                throw VaultExportError.vaultNotFound
            }
            guard !VaultExportService.isEmpty(manifest) else {
                throw VaultExportError.noData
            }
            return manifest
        }.value
    }

    // MARK: - Pure helpers (testability)

    /// Pure function variant — accepts an explicit vault URL so tests can
    /// inject a fixture directory without touching `VaultInitializer.shared`.
    ///
    /// - Returns: `nil` when the vault root directory itself doesn't exist.
    ///            A populated `ExportManifest` otherwise; if the vault is
    ///            present-but-empty the manifest has all-zero counts and the
    ///            caller is responsible for translating that into `.noData`.
    /// - Throws: Re-throws FileManager errors that aren't "missing directory"
    ///           (e.g. permission denied). Routine "subdirectory missing"
    ///           cases are swallowed and treated as 0 contribution.
    nonisolated internal static func computeManifest(vaultURL: URL) throws -> ExportManifest? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: vaultURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // Each subdirectory may legitimately be missing on a freshly-initialized
        // vault (e.g. user has captured raw memos but no compilation has run
        // yet -> wiki/daily doesn't exist). We treat "directory missing" as 0
        // contribution so the manifest stays well-defined.
        let rawDir    = vaultURL.appendingPathComponent("raw")
        let dailyDir  = vaultURL.appendingPathComponent("wiki/daily")
        let placesDir = vaultURL.appendingPathComponent("wiki/places")
        let peopleDir = vaultURL.appendingPathComponent("wiki/people")
        let themesDir = vaultURL.appendingPathComponent("wiki/themes")
        let assetsDir = vaultURL.appendingPathComponent("raw/assets")

        // raw/ holds *.md files directly (flat, not recursive). We deliberately
        // exclude the nested raw/assets/ subtree from rawMemoCount — assets get
        // counted separately under assetCount below.
        let rawScan    = try scanFlatMarkdown(directory: rawDir, fm: fm)
        let dailyScan  = try scanFlatMarkdown(directory: dailyDir, fm: fm)
        let placesScan = try scanFlatMarkdown(directory: placesDir, fm: fm)
        let peopleScan = try scanFlatMarkdown(directory: peopleDir, fm: fm)
        let themesScan = try scanFlatMarkdown(directory: themesDir, fm: fm)
        // assets/ is recursive — photos live under assets/photos/, voice under
        // assets/audio/, etc. Use enumerator() rather than contentsOfDirectory.
        let assetsScan = try scanRecursive(directory: assetsDir, fm: fm)

        let entityCount = placesScan.count + peopleScan.count + themesScan.count
        let totalBytes = rawScan.bytes + dailyScan.bytes + placesScan.bytes
                       + peopleScan.bytes + themesScan.bytes + assetsScan.bytes

        return ExportManifest(
            rawMemoCount: rawScan.count,
            dailyPageCount: dailyScan.count,
            entityCount: entityCount,
            assetCount: assetsScan.count,
            estimatedTotalBytes: totalBytes
        )
    }

    /// `true` iff every count in the manifest is zero. Extracted so both
    /// `collectExportManifest()` and tests share one definition of "empty".
    nonisolated internal static func isEmpty(_ manifest: ExportManifest) -> Bool {
        return manifest.rawMemoCount == 0
            && manifest.dailyPageCount == 0
            && manifest.entityCount == 0
            && manifest.assetCount == 0
    }

    // MARK: - Directory walkers

    /// Flat (non-recursive) scan of `*.md` files in `directory`. Returns
    /// `(0, 0)` if the directory doesn't exist — that's the expected state
    /// on a brand-new vault where wiki/daily hasn't been created yet.
    nonisolated private static func scanFlatMarkdown(directory: URL, fm: FileManager) throws -> (count: Int, bytes: Int64) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return (0, 0)
        }
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        var count = 0
        var bytes: Int64 = 0
        for url in entries where url.pathExtension.lowercased() == "md" {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    /// Recursive scan of every regular file under `directory`. Used for the
    /// assets tree where files live under nested `photos/`, `audio/` etc.
    /// Returns `(0, 0)` if the directory doesn't exist.
    nonisolated private static func scanRecursive(directory: URL, fm: FileManager) throws -> (count: Int, bytes: Int64) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return (0, 0)
        }
        // enumerator() returns nil on serious failure; treat that as "empty"
        // rather than crashing — the caller can still see 0 counts.
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }
}
