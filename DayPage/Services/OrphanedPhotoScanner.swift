import Foundation

// MARK: - OrphanedPhotoScanner

/// Reconciles `vault/raw/assets/IMG_*.jpg` files against memos that reference
/// them. Mirrors `OrphanedVoiceScanner` for photo attachments.
///
/// Orphans appear when:
///   1. The user picks/captures a photo, `PhotoService` saves it to disk +
///      stages a pending attachment, but the user backgrounds / kills the app
///      before tapping Send — pendingAttachments lives in memory only.
///   2. A memo with photo attachments is deleted (TodayViewModel.deleteMemo
///      and DailyPageModel.deleteMemo only rewrite the day file; they do not
///      clean up the referenced `IMG_*.jpg` files).
///   3. Camera capture succeeds but the memo never reaches the day file
///      (submit error / network drop during compile).
///
/// Strategy mirrors the voice scanner:
///   • Stale orphans (older than `garbageCollectThreshold`, default 24h) are
///     deleted silently with a Sentry breadcrumb.
///   • Recent orphans (within `garbageCollectThreshold`) are reported via
///     `findOrphans()` so a future "recover unsent photo?" UI can surface
///     them without re-walking the disk.
///
/// Pure functions over `FileManager` + `RawStorage`; safe to call from any
/// thread/actor. No I/O happens at module load — `runStartupScan()` must be
/// called explicitly from app launch.
enum OrphanedPhotoScanner {

    // MARK: - Public surface

    struct Orphan: Equatable {
        let url: URL
        let modifiedAt: Date
        let sizeBytes: Int64
    }

    /// Default age threshold above which orphans are eligible for silent GC.
    /// Matches the voice scanner so first-launch sweeps behave consistently.
    static let garbageCollectThreshold: TimeInterval = 24 * 3600

    /// Scan + GC entry point for app launch.
    ///
    /// Returns the count of (deletedStale, retainedRecent) for telemetry.
    /// Errors during individual file delete are swallowed and breadcrumbed;
    /// errors during the directory walk propagate.
    @discardableResult
    static func runStartupScan(
        now: Date = Date(),
        threshold: TimeInterval = garbageCollectThreshold
    ) -> (deletedStale: Int, retainedRecent: Int) {
        let orphans: [Orphan]
        do {
            orphans = try findOrphans()
        } catch {
            SentryReporter.breadcrumb(
                category: "photo-orphan",
                level: .error,
                message: "scan failed: \(error)"
            )
            return (0, 0)
        }

        if orphans.isEmpty { return (0, 0) }

        var deleted = 0
        var retained = 0
        for orphan in orphans {
            let age = now.timeIntervalSince(orphan.modifiedAt)
            if age >= threshold {
                do {
                    try FileManager.default.removeItem(at: orphan.url)
                    deleted += 1
                } catch {
                    SentryReporter.breadcrumb(
                        category: "photo-orphan",
                        level: .warning,
                        message: "delete failed for \(orphan.url.lastPathComponent): \(error)"
                    )
                }
            } else {
                retained += 1
            }
        }

        SentryReporter.breadcrumb(
            category: "photo-orphan",
            level: .info,
            message: "startup scan: deleted=\(deleted) retained=\(retained)"
        )
        return (deleted, retained)
    }

    /// Returns all photo files under `vault/raw/assets/` that are not
    /// referenced by any memo's `attachments[].file` field, sorted by
    /// modification time descending (newest first). Pure read.
    static func findOrphans(fileManager: FileManager = .default) throws -> [Orphan] {
        let assetsURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")

        guard fileManager.fileExists(atPath: assetsURL.path) else { return [] }

        let photoFiles = try fileManager
            .contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { url in
                let name = url.lastPathComponent
                // Match the PhotoService naming convention: IMG_<timestamp>.jpg
                // Permissive on suffix to also catch HEIC / .jpeg in case
                // future captures change format.
                guard name.hasPrefix("IMG_") else { return false }
                let lower = name.lowercased()
                return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".heic")
            }

        if photoFiles.isEmpty { return [] }

        let referenced = try collectReferencedPhotoPaths(fileManager: fileManager)

        let orphans: [Orphan] = photoFiles.compactMap { url in
            let relative = "raw/assets/\(url.lastPathComponent)"
            guard !referenced.contains(relative) else { return nil }

            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = attrs?.contentModificationDate ?? .distantPast
            let size = Int64(attrs?.fileSize ?? 0)
            return Orphan(url: url, modifiedAt: modified, sizeBytes: size)
        }

        return orphans.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Internals

    /// Walks `vault/raw/*.md` and collects every `attachment.file` value where
    /// `kind == "photo"`. Inflight draft attachment paths are also treated as
    /// referenced so a pending submit's photo survives the sweep.
    private static func collectReferencedPhotoPaths(fileManager: FileManager) throws -> Set<String> {
        let rawURL = VaultInitializer.vaultURL.appendingPathComponent("raw")
        guard fileManager.fileExists(atPath: rawURL.path) else { return [] }

        let dayFiles = try fileManager
            .contentsOfDirectory(at: rawURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }

        var refs = Set<String>()
        for dayFile in dayFiles {
            guard let content = try? String(contentsOf: dayFile, encoding: .utf8) else {
                SentryReporter.breadcrumb(
                    category: "photo-orphan",
                    level: .warning,
                    message: "could not read \(dayFile.lastPathComponent); skipping"
                )
                continue
            }
            let memos = RawStorage.parse(fileContent: content, sourceFile: dayFile)
            for memo in memos {
                for att in memo.attachments where att.kind == "photo" {
                    refs.insert(att.file)
                }
            }
        }

        // Inflight drafts may contain staged photos whose memo never reached
        // the day file; keep their attachment paths referenced so the photo
        // survives until the user retries the submit or cancels.
        for draft in InflightDraftStore.pending() {
            for path in draft.attachmentPaths {
                refs.insert(path)
            }
        }
        return refs
    }
}
