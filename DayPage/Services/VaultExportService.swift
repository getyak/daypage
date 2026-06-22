// VaultExportService.swift — R11 (manifest) + R13 (zip packaging)
//
// Scope of this file:
//   1. R11 — Produce a summary manifest (counts + byte total) so the
//      VaultExportView (R14) can show a "what's about to be backed up" preview
//      before the user commits to a long-running export.
//   2. R13 — Package selected vault subdirectories into a single zip archive
//      written to `NSTemporaryDirectory`. The caller (UI layer, R14) is
//      responsible for handing that URL off to a share sheet or Files App.
//
// What this file deliberately does NOT do (left for later rounds):
//   - Surface UI / Settings entry (R14).
//   - Touch CompilationService / SyncQueue / iCloud — pure read + temp write.
//   - Encrypt or sign the archive (separate threat-model conversation).
//
// Why a "manifest" first:
//   On a heavy vault (a year of daily memos + photos) the zip step is the slow
//   part. We want the user to see counts + size before we burn CPU/disk, and
//   we want a deterministic seam unit tests can hit without going through the
//   `@MainActor` singleton.
//
// Threading:
//   Both `collectExportManifest()` and `exportVaultZip(...)` are
//   `@MainActor async` so callers can `await` them from SwiftUI views; the
//   actual file walk + copy + archive happen off the main actor via
//   `Task.detached` so we don't hitch the UI on a multi-thousand-file scan.
//   Progress callbacks are hopped back onto `MainActor` before invocation so
//   SwiftUI `@Published` updates are safe.
//
// Zip strategy (no external dependency):
//   We avoid pulling in ZIPFoundation / SSZipArchive. iOS Foundation already
//   ships an archiver via `NSFileCoordinator.coordinate(readingItemAt:
//   options: .forUploading)` — the `.forUploading` option tells the
//   coordinator to hand back a zip copy of the directory in a temporary
//   location. We then copy that zip to our final destination before the
//   coordinator cleans up its temp dir.

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
    /// Zip packaging failed for an operational reason — staging copy denied,
    /// NSFileCoordinator returned an error, etc. The reason String is human-
    /// readable (suitable for surfacing in a SwiftUI alert). We use a String
    /// instead of `Error` so the enum stays automatically `Equatable` — tests
    /// can `#expect(error == .exportFailed("..."))` if they need exact match,
    /// or `if case let .exportFailed(reason) = error` for substring checks.
    case exportFailed(String)
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

/// Bitmask selecting which vault subdirectories `exportVaultZip(...)` should
/// pull into the staging archive. Defaults to `.all` so the common "back up
/// everything" path is a single call. Tests rely on `[]` (empty set) being
/// explicitly rejected with `.exportFailed` so users don't get an empty zip
/// they paid CPU for.
struct VaultExportIncludes: OptionSet, Equatable {
    let rawValue: Int
    /// `vault/raw/*.md` — the source-of-truth memo dump.
    static let rawMemos    = VaultExportIncludes(rawValue: 1 << 0)
    /// `vault/wiki/daily/*.md` — AI-compiled diary pages.
    static let dailyPages  = VaultExportIncludes(rawValue: 1 << 1)
    /// `vault/wiki/{places,people,themes}/*.md` — combined entity wiki.
    /// One flag rather than three because the UI surfaces "Entities" as a
    /// single toggle, and splitting would tempt callers into invalid combos
    /// (e.g. places without themes when a daily page links both).
    static let entities    = VaultExportIncludes(rawValue: 1 << 2)
    /// `vault/raw/assets/**` — photos, audio, attachments (recursive).
    static let assets      = VaultExportIncludes(rawValue: 1 << 3)
    /// Convenience: every known subdirectory. Add new bits to this set when
    /// the vault grows new top-level subdirectories.
    static let all: VaultExportIncludes = [.rawMemos, .dailyPages, .entities, .assets]
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

    // MARK: - Zip packaging (R13)

    /// Package the selected vault subdirectories into a single `.zip` archive
    /// written to `NSTemporaryDirectory`. Returns the final archive URL —
    /// the caller (R14 UI layer) is responsible for moving / sharing it.
    ///
    /// Implementation flow:
    ///   1. Validate the vault exists and is non-empty via `computeManifest`.
    ///   2. Create a unique `staging-{UUID}/` directory under tmp.
    ///   3. Copy each selected subdirectory under staging, preserving the
    ///      `raw/`, `wiki/daily/`, `wiki/places/`, … layout the user would
    ///      see in iCloud Drive — so an unzip restores a familiar tree.
    ///   4. Ask `NSFileCoordinator` to produce a `.zip` of the staging
    ///      directory using `.forUploading`; copy that zip to the final
    ///      destination before the coordinator's temp dir is reclaimed.
    ///   5. `defer`-clean the staging directory regardless of success.
    ///
    /// Threading:
    ///   The heavy I/O runs inside a `Task.detached(priority: .userInitiated)`
    ///   so the main actor stays free. `progress` is hopped onto `MainActor`
    ///   before each invocation so SwiftUI `@Published` updates are safe.
    ///   Progress milestones: 0.10 (staging ready) → 0.50 (copy done) →
    ///   0.90 (zip produced) → 1.00 (zip moved to final location).
    ///
    /// Cleanup:
    ///   Staging is always removed in `defer` — even on throw. The final zip
    ///   under tmp is the caller's to delete (typically after the share
    ///   sheet closes); we don't own its lifecycle past return.
    ///
    /// - Parameters:
    ///   - includes: Which subdirectories to include. Defaults to `.all`.
    ///               Empty set is an explicit `.exportFailed` to avoid
    ///               silently producing an empty archive.
    ///   - progress: Optional 0.0…1.0 progress callback, invoked on the
    ///               main actor.
    /// - Throws: `.vaultNotFound` if the vault directory is missing,
    ///           `.noData` if the vault is present-but-empty,
    ///           `.exportFailed(reason)` for any other failure (no
    ///           subdirectories selected, copy denied, coordinator error).
    /// - Returns: URL of the final `.zip` file under `NSTemporaryDirectory`.
    func exportVaultZip(
        includes: VaultExportIncludes = .all,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        // Fail fast on an empty include set BEFORE we burn manifest CPU —
        // tests and the UI both care that this returns immediately.
        guard !includes.isEmpty else {
            throw VaultExportError.exportFailed("no subdirectories selected")
        }

        let vaultURL = VaultInitializer.vaultURL

        return try await Task.detached(priority: .userInitiated) { [progress] in
            let fm = FileManager.default

            // Step 1 — Validate vault. computeManifest gives us both the
            // existence check (.vaultNotFound) and the emptiness check
            // (.noData) for free; reuse it rather than re-walking the tree.
            guard let manifest = try VaultExportService.computeManifest(vaultURL: vaultURL) else {
                throw VaultExportError.vaultNotFound
            }
            guard !VaultExportService.isEmpty(manifest) else {
                throw VaultExportError.noData
            }

            // Step 2 — Create staging directory. UUID suffix avoids collisions
            // when two share-sheet exports race (rare but possible if the user
            // taps quickly).
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let stagingURL = tmp.appendingPathComponent("daypage-export-staging-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            } catch {
                throw VaultExportError.exportFailed("failed to create staging dir: \(error.localizedDescription)")
            }
            // Always clean staging — success or failure. The final zip lives
            // in tmp/ at a separate path, so this doesn't affect the result.
            defer { try? fm.removeItem(at: stagingURL) }

            if let progress {
                await MainActor.run { progress(0.10) }
            }

            // Step 3 — Selective copy. We map each OptionSet bit to a list of
            // (source, destination-relative) pairs so the staging layout
            // mirrors the vault layout the user already knows from iCloud.
            // Missing source directories are tolerated — a vault that hasn't
            // run AI compilation yet legitimately lacks wiki/daily/.
            //
            // `skipChildName` lets a spec copy a directory while excluding one
            // child subtree. This matters for `.rawMemos`: the on-disk `raw/`
            // dir *contains* `raw/assets/`, but `.assets` owns that subtree as
            // its own flag. Without the exclusion, selecting both `.rawMemos`
            // and `.assets` (the `.all` default) would stage `raw/assets/`
            // twice and the second copyItem would throw "item already exists".
            struct CopySpec {
                let source: URL
                let stagingRelativePath: String
                /// Immediate child directory name to omit when staging `source`.
                /// nil means copy the whole subtree.
                var skipChildName: String? = nil
            }
            var specs: [CopySpec] = []
            if includes.contains(.rawMemos) {
                // Copy raw/ but leave raw/assets/ to the `.assets` flag so the
                // two flags stay non-overlapping (and so a memo-only export
                // doesn't drag in hundreds of MB of photos).
                specs.append(CopySpec(
                    source: vaultURL.appendingPathComponent("raw"),
                    stagingRelativePath: "raw",
                    skipChildName: "assets"
                ))
            }
            if includes.contains(.dailyPages) {
                specs.append(CopySpec(
                    source: vaultURL.appendingPathComponent("wiki/daily"),
                    stagingRelativePath: "wiki/daily"
                ))
            }
            if includes.contains(.entities) {
                specs.append(CopySpec(
                    source: vaultURL.appendingPathComponent("wiki/places"),
                    stagingRelativePath: "wiki/places"
                ))
                specs.append(CopySpec(
                    source: vaultURL.appendingPathComponent("wiki/people"),
                    stagingRelativePath: "wiki/people"
                ))
                specs.append(CopySpec(
                    source: vaultURL.appendingPathComponent("wiki/themes"),
                    stagingRelativePath: "wiki/themes"
                ))
            }
            if includes.contains(.assets) {
                specs.append(CopySpec(
                    source: vaultURL.appendingPathComponent("raw/assets"),
                    stagingRelativePath: "raw/assets"
                ))
            }

            for spec in specs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: spec.source.path, isDirectory: &isDir), isDir.boolValue else {
                    // Source dir missing is fine — represents "no entries of
                    // this type yet". Skip silently.
                    continue
                }
                let dest = stagingURL.appendingPathComponent(spec.stagingRelativePath, isDirectory: true)
                // Ensure parent exists (e.g. staging/wiki/) before copying
                // staging/wiki/daily/.
                let parent = dest.deletingLastPathComponent()
                do {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    if let skip = spec.skipChildName {
                        // Per-child copy so we can omit one subtree (raw/assets/).
                        // Create the dest dir, then copy every immediate child
                        // except `skip`. shallow=top-level enumerate is enough
                        // because we recurse via copyItem on each child.
                        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                        let children = try fm.contentsOfDirectory(
                            at: spec.source,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )
                        for child in children where child.lastPathComponent != skip {
                            try fm.copyItem(
                                at: child,
                                to: dest.appendingPathComponent(child.lastPathComponent)
                            )
                        }
                    } else {
                        try fm.copyItem(at: spec.source, to: dest)
                    }
                } catch {
                    throw VaultExportError.exportFailed(
                        "failed to stage \(spec.stagingRelativePath): \(error.localizedDescription)"
                    )
                }
            }

            if let progress {
                await MainActor.run { progress(0.50) }
            }

            // Step 4 — Produce zip via NSFileCoordinator. `.forUploading` is
            // the documented Foundation API for "give me a zip copy of this
            // directory"; the closure's `URL` argument points to a temp file
            // that the system reclaims after the closure returns, so we
            // copy it to our own destination synchronously.
            let timestamp = Self.timestampFormatter.string(from: Date())
            let destinationURL = tmp.appendingPathComponent(
                "daypage-vault-export-\(timestamp).zip",
                isDirectory: false
            )
            // If a same-second export already exists (unlikely but possible
            // in test loops), remove it first so copyItem doesn't throw
            // NSFileWriteFileExistsError.
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            var coordinatorThrew: Error?
            coordinator.coordinate(
                readingItemAt: stagingURL,
                options: [.forUploading],
                error: &coordError
            ) { (zipURL: URL) in
                do {
                    try fm.copyItem(at: zipURL, to: destinationURL)
                } catch {
                    coordinatorThrew = error
                }
            }
            if let err = coordError {
                throw VaultExportError.exportFailed("coordinator: \(err.localizedDescription)")
            }
            if let err = coordinatorThrew {
                throw VaultExportError.exportFailed("zip copy failed: \(err.localizedDescription)")
            }
            guard fm.fileExists(atPath: destinationURL.path) else {
                throw VaultExportError.exportFailed("coordinator produced no zip url")
            }

            if let progress {
                await MainActor.run { progress(0.90) }
            }

            // Step 5 — Final progress tick. The zip is already at its final
            // location (we wrote there directly in the coordinator block);
            // this tick exists so observers see a clean 1.0 terminal value.
            if let progress {
                await MainActor.run { progress(1.0) }
            }

            return destinationURL
        }.value
    }

    /// Stable filename timestamp generator. `en_US_POSIX` so the locale of
    /// the device can't introduce e.g. Arabic-Indic digits into a filename.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

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
