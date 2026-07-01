import Foundation
import DayPageStorage

// MARK: - OrphanedVoiceScanner

/// Reconciles `vault/raw/assets/voice_*.m4a` files against memos that reference
/// them. Orphans appear when:
///
///   1. The user starts a recording, then the OS or user kills the app before
///      `stopAndTranscribe` returns — the .m4a is on disk but no memo was
///      ever created.
///   2. `stopAndTranscribe` succeeds and stages a pending attachment, but the
///      user backgrounds / kills the app before tapping Send — pendingAttachments
///      lives in memory only.
///   3. `cancelRecording`'s `try? removeItem` silently fails.
///
/// Without a sweep, every such event leaves a permanent file in the vault
/// counting against iCloud quota and confusing future grep / Spotlight hits.
///
/// First-pass strategy (Beta v1.0):
///
///   • Stale orphans (older than `garbageCollectThreshold`, default 24h) are
///     deleted silently with a Sentry breadcrumb. This bounds long-tail
///     accumulation without requiring UI.
///   • Recent orphans (within `garbageCollectThreshold`) are reported via
///     `findOrphans()` so a future UI pass can surface a "recover unsaved
///     recording?" prompt without re-walking the disk.
///
/// Pure functions over `FileManager` + `RawStorage`; safe to call from any
/// thread/actor. No I/O happens at module load — runStartupScan() must be
/// called explicitly from app launch.
public enum OrphanedVoiceScanner {

    // MARK: - Public surface

    public struct Orphan: Equatable {
        public let url: URL
        public let modifiedAt: Date
        public let sizeBytes: Int64

        public init(url: URL, modifiedAt: Date, sizeBytes: Int64) {
            self.url = url
            self.modifiedAt = modifiedAt
            self.sizeBytes = sizeBytes
        }
    }

    /// Default age threshold above which orphans are eligible for silent GC.
    /// 24 hours strikes a balance between "user might still remember and want
    /// to recover" and "long-tail iCloud bloat".
    public static let garbageCollectThreshold: TimeInterval = 24 * 3600

    /// Scan + GC entry point for app launch.
    ///
    /// Returns the count of (deletedStale, retainedRecent) for telemetry.
    /// Errors during individual file delete are swallowed and breadcrumbed;
    /// errors during the directory walk propagate.
    @discardableResult
    public static func runStartupScan(
        now: Date = Date(),
        threshold: TimeInterval = garbageCollectThreshold
    ) -> (deletedStale: Int, retainedRecent: Int) {
        let orphans: [Orphan]
        do {
            orphans = try findOrphans()
        } catch {
            SentryReporter.breadcrumb(
                category: "voice-orphan",
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
                        category: "voice-orphan",
                        level: .warning,
                        message: "delete failed for \(orphan.url.lastPathComponent): \(error)"
                    )
                }
            } else {
                retained += 1
            }
        }

        SentryReporter.breadcrumb(
            category: "voice-orphan",
            level: .info,
            message: "startup scan: deleted=\(deleted) retained=\(retained)"
        )
        return (deleted, retained)
    }

    /// Returns all voice files under `vault/raw/assets/` that are not
    /// referenced by any memo's `attachments[].file` field, sorted by
    /// modification time descending (newest first).
    ///
    /// Pure read: never mutates the vault. Suitable for both the startup
    /// sweep and a future UI surface.
    public static func findOrphans(fileManager: FileManager = .default) throws -> [Orphan] {
        let assetsURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")

        guard fileManager.fileExists(atPath: assetsURL.path) else { return [] }

        let voiceFiles = try fileManager
            .contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("voice_") && name.hasSuffix(".m4a")
            }

        if voiceFiles.isEmpty { return [] }

        let referenced = try collectReferencedAudioPaths(fileManager: fileManager)

        let orphans: [Orphan] = voiceFiles.compactMap { url in
            // Compare the vault-relative path the same way memos store it
            // (e.g. "raw/assets/voice_20260415_143000.m4a"), so a memo whose
            // attachment.file matches is correctly recognized as a reference.
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
    /// `kind == "audio"`. Returns a set of vault-relative paths.
    ///
    /// Parsing failures on individual day files are logged and skipped — a
    /// corrupt day file must not cause us to delete recordings that *are*
    /// referenced from other days.
    private static func collectReferencedAudioPaths(fileManager: FileManager) throws -> Set<String> {
        let rawURL = VaultInitializer.vaultURL.appendingPathComponent("raw")
        guard fileManager.fileExists(atPath: rawURL.path) else { return [] }

        let dayFiles = try fileManager
            .contentsOfDirectory(at: rawURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }

        var refs = Set<String>()
        for dayFile in dayFiles {
            guard let content = try? String(contentsOf: dayFile, encoding: .utf8) else {
                SentryReporter.breadcrumb(
                    category: "voice-orphan",
                    level: .warning,
                    message: "could not read \(dayFile.lastPathComponent); skipping"
                )
                continue
            }
            let memos = RawStorage.parse(fileContent: content, sourceFile: dayFile)
            for memo in memos {
                for att in memo.attachments where att.kind == "audio" {
                    refs.insert(att.file)
                }
            }
        }

        // An inflight draft (issue #23) has staged audio attachments whose
        // memo never reached the day file — if we ignore them here, the
        // startup GC could delete the recording right before the user
        // retries the submit. Treat every inflight attachment path as
        // referenced so the voice file survives long enough for recovery.
        refs.formUnion(InflightDraftRefsHook.referencedPaths())
        return refs
    }
}
