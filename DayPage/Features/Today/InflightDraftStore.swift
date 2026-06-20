import Foundation

// MARK: - InflightDraft

/// On-disk record of a memo whose submit Task was started but not yet
/// confirmed. Persisted before `RawStorage.append` runs and removed only
/// after a successful append. Protects against:
///
///   • App killed (OS memory pressure / user force-quit) during the await
///     chain (location → weather → append).
///   • The submit Task being explicitly cancelled mid-flight.
///   • Any throwing path that exits before append completes.
///
/// Without this record, the composer's `draftText = ""` (which runs
/// synchronously the moment the user taps Send) would silently lose the
/// user's body text.
struct InflightDraft: Equatable, Codable {
    var id: UUID
    /// User-typed body text. The thing we cannot afford to lose.
    var body: String
    /// ISO8601 timestamp the user tapped Send, so recovery can sort by age.
    var enqueuedAt: Date
    /// Vault-relative paths of attachments staged before this submit
    /// (e.g. "raw/assets/voice_…m4a", "raw/assets/IMG_…jpg"). Recovery
    /// uses these to flag attachments that may already be referenced by
    /// an inflight memo for orphan-scan exclusion.
    var attachmentPaths: [String]
}

// MARK: - InflightDraftStore

/// Inflight-draft persistence under `vault/raw/.inflight/{uuid}.json`.
///
/// Each call to `enqueue` produces exactly one file. `dequeue` removes it
/// only after the corresponding `RawStorage.append` has succeeded. On app
/// launch, `pending()` returns every inflight record whose append never
/// completed; the caller decides how to surface them to the user
/// (typically: route the most recent body into the composer's recovery
/// banner, breadcrumb the rest).
///
/// Pure `FileManager` + `JSONEncoder` — safe to call from any actor.
/// Failures are intentionally swallowed and breadcrumbed: an enqueue I/O
/// error must not block the user from submitting the memo (we'd rather
/// risk a kill-during-await loss than refuse the Send).
enum InflightDraftStore {

    // MARK: - URL helpers

    /// `vault/raw/.inflight/` — sibling of `.broken/` so both
    /// safety-net directories live under the same vault root.
    static var directory: URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent(".inflight", isDirectory: true)
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Enqueue / Dequeue

    /// Persists the draft. Returns the URL the caller should pass to
    /// `dequeue` once `RawStorage.append` succeeds. Returns `nil` on I/O
    /// failure — the caller proceeds with submit anyway; the body is just
    /// unprotected for this one attempt.
    @discardableResult
    static func enqueue(body: String, attachmentPaths: [String]) -> URL? {
        let draft = InflightDraft(
            id: UUID(),
            body: body,
            enqueuedAt: Date(),
            attachmentPaths: attachmentPaths
        )
        let url = fileURL(for: draft.id)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(draft)
            try RawStorage.atomicWrite(data: data, to: url)
            SentryReporter.breadcrumb(
                category: "inflight",
                message: "enqueued \(draft.id) body.len=\(body.count) attachments=\(attachmentPaths.count)"
            )
            return url
        } catch {
            SentryReporter.breadcrumb(
                category: "inflight",
                level: .warning,
                message: "enqueue failed: \(error)"
            )
            return nil
        }
    }

    /// Removes the on-disk record after a successful append. Idempotent:
    /// a missing file is treated as success.
    static func dequeue(_ url: URL?) {
        guard let url = url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            SentryReporter.breadcrumb(
                category: "inflight",
                message: "dequeued \(url.lastPathComponent)"
            )
        } catch {
            SentryReporter.breadcrumb(
                category: "inflight",
                level: .warning,
                message: "dequeue failed for \(url.lastPathComponent): \(error)"
            )
        }
    }

    // MARK: - Recovery

    /// Returns every persisted inflight draft, sorted newest first.
    /// Corrupted entries are skipped (and breadcrumbed) rather than
    /// blocking recovery for the healthy ones.
    static func pending() -> [InflightDraft] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var drafts: [InflightDraft] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in entries where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let draft = try decoder.decode(InflightDraft.self, from: data)
                drafts.append(draft)
            } catch {
                SentryReporter.breadcrumb(
                    category: "inflight",
                    level: .warning,
                    message: "skip corrupt inflight \(url.lastPathComponent): \(error)"
                )
            }
        }
        return drafts.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    /// Removes every inflight record. Used by the recovery flow after the
    /// caller has consumed `pending()` and routed bodies to the UI.
    static func clearAll() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }
}
