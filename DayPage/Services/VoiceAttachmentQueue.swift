import Foundation
import UIKit
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - Queue Entry

private struct VoiceQueueEntry: Codable {
    var id: String
    var audioPath: String   // vault-relative: raw/assets/...
    var createdAt: Date
    var memoDate: String    // yyyy-MM-dd
    var attempts: Int
    var lastError: String?
    var failed: Bool        // true after maxAttempts failed attempts
}

// MARK: - Public Failed Entry (for UI)

struct FailedVoiceEntry: Identifiable {
    let id: String
    let audioPath: String
    let memoDate: String
    let lastError: String?
}

// MARK: - VoiceAttachmentQueue

@MainActor
final class VoiceAttachmentQueue: ObservableObject {

    static let shared = VoiceAttachmentQueue()

    private let maxAttempts = 3
    private var isProcessing = false
    private var previousOnlineState: Bool? = nil

    // Published state so TodayView / UI can observe
    @Published private(set) var pendingCount: Int = 0
    /// Entries that exhausted all retry attempts — surface these for manual retry UI.
    @Published private(set) var failedEntries: [FailedVoiceEntry] = []

    private var queueURL: URL {
        let drafts = VaultInitializer.vaultURL.appendingPathComponent("drafts", isDirectory: true)
        do { try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true) } catch { DayPageLogger.shared.error("VoiceAttachmentQueue: createDirectory: \(error)") }
        return drafts.appendingPathComponent("voice_queue.json")
    }

    private init() {
        updateCount()
        observeNetworkChanges()
        observeAppActive()
    }

    // MARK: - Public API

    func enqueue(audioPath: String, memoDate: Date) {
        var entries = load()
        let dateStr = isoDateString(memoDate)
        let entry = VoiceQueueEntry(
            id: UUID().uuidString,
            audioPath: audioPath,
            createdAt: Date(),
            memoDate: dateStr,
            attempts: 0,
            lastError: nil,
            failed: false
        )
        entries.append(entry)
        save(entries)
        updateCount()
        Task { await processQueue() }
    }

    func processQueue() async {
        guard !isProcessing, NetworkMonitor.shared.isOnline else { return }
        isProcessing = true
        defer { isProcessing = false }

        // H1 fix: the previous implementation recursed via `await processQueue()`
        // at the end. The recursive call's reentrant `isProcessing` guard
        // returned immediately, so pending entries past the first break were
        // never processed in the same session. Use a single iterative loop —
        // no stack growth, all pending entries handled before returning.
        while NetworkMonitor.shared.isOnline {
            var entries = load()
            var changedThisPass = false
            var consumedOne = false

            for i in entries.indices {
                guard !entries[i].failed else { continue }
                let entry = entries[i]

                let audioURL = VaultInitializer.vaultURL.appendingPathComponent(entry.audioPath)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    entries[i].failed = true
                    entries[i].lastError = "audio file not found"
                    changedThisPass = true
                    continue
                }

                if let transcript = await VoiceService.shared.transcribeAudio(at: audioURL) {
                    writeTranscriptBack(transcript: transcript, entry: entry)
                    entries.remove(at: i)
                    changedThisPass = true
                    consumedOne = true
                    break // reload after mutation so indices stay coherent
                } else {
                    entries[i].attempts += 1
                    entries[i].lastError = "transcription returned nil"
                    if entries[i].attempts >= maxAttempts {
                        entries[i].failed = true
                    }
                    changedThisPass = true
                }
            }

            if changedThisPass {
                save(entries)
                updateCount()
            }

            // Exit when nothing actionable remains. `consumedOne` covers the
            // success path; if the whole pass produced no transcripts and the
            // remaining entries are all failed or attempts-exhausted, stop.
            let remaining = entries.filter { !$0.failed }
            if remaining.isEmpty || !consumedOne { return }
        }
    }

    // MARK: - Private

    private func observeNetworkChanges() {
        Task {
            while true {
                let current = NetworkMonitor.shared.isOnline
                if let prev = previousOnlineState, !prev && current {
                    await processQueue()
                }
                previousOnlineState = current
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func observeAppActive() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processQueue()
            }
        }
    }

    private func writeTranscriptBack(transcript: String, entry: VoiceQueueEntry) {
        Self.applyTranscript(
            transcript: transcript,
            audioPath: entry.audioPath,
            memoDate: entry.memoDate
        )
    }

    /// Parse → mutate → rewrite the day file so the transcript is written back
    /// to the exact attachment whose `file` matches `audioPath`, regardless of
    /// other concurrent writers.
    ///
    /// Why this shape (not string replace): the previous implementation did a
    /// read-modify-atomicWrite using `replacingOccurrences` against a brittle
    /// 2-space-indented substring. That substring never matched the 4-space
    /// indentation produced by `Memo.toMarkdown`, so transcripts silently
    /// failed to land; and even if it had matched, two transcripts completing
    /// in the same window would each read the same pre-image and the second
    /// `atomicWrite` would clobber the first.
    ///
    /// `RawStorage.rewrite` runs inside the shared `writeQueue.sync`, so
    /// concurrent transcript callbacks are serialized at the storage layer
    /// and each one re-reads the latest on-disk state before mutating its
    /// own attachment. `Memo.toMarkdown` handles YAML quoting (quotes,
    /// backslashes, newlines), eliminating the prior escape bug.
    ///
    /// Returns `true` when a matching attachment was found and rewritten.
    /// `internal` for test access; not part of the public API.
    @discardableResult
    nonisolated static func applyTranscript(
        transcript: String,
        audioPath: String,
        memoDate: String
    ) -> Bool {
        guard let date = parseMemoDate(memoDate) else {
            SentryReporter.breadcrumb(
                category: "voice-queue",
                level: .warning,
                message: "applyTranscript: invalid memoDate"
            )
            return false
        }

        var matched = false
        do {
            try RawStorage.mutate(for: date) { memos in
                let updated = memos.map { memo -> Memo in
                    var copy = memo
                    copy.attachments = memo.attachments.map { att -> Memo.Attachment in
                        guard att.file == audioPath, att.kind == "audio" else { return att }
                        matched = true
                        var a = att
                        a.transcript = transcript
                        a.transcriptionStatus = .done
                        return a
                    }
                    return copy
                }
                // Skip the write entirely when no attachment matched, both
                // to avoid pointless I/O and to preserve the on-disk file's
                // mtime so caches that key off it don't see spurious churn.
                return matched ? updated : nil
            }
        } catch {
            SentryReporter.breadcrumb(
                category: "voice-queue",
                level: .error,
                message: "applyTranscript: mutate failed: \(error)"
            )
            return false
        }

        guard matched else {
            SentryReporter.breadcrumb(
                category: "voice-queue",
                level: .warning,
                message: "applyTranscript: no matching attachment on \(memoDate)"
            )
            return false
        }
        return true
    }

    nonisolated private static func parseMemoDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f.date(from: s)
    }

    private func load() -> [VoiceQueueEntry] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: queueURL)
            return try JSONDecoder().decode([VoiceQueueEntry].self, from: data)
        } catch {
            DayPageLogger.shared.error("VoiceAttachmentQueue: load: \(error)")
            return []
        }
    }

    private func save(_ entries: [VoiceQueueEntry]) {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: queueURL, options: .atomic)
        } catch {
            DayPageLogger.shared.error("VoiceAttachmentQueue: save: \(error)")
        }
    }

    private func updateCount() {
        pendingCount = load().filter { !$0.failed }.count
    }

    private func isoDateString(_ date: Date) -> String {
        // Must match RawStorage.dateFormatter timezone so the round-trip
        // (Date → memoDate string → Date in writeTranscriptBack) resolves to
        // the same day file. Using TimeZone.current here while RawStorage uses
        // AppSettings.currentTimeZone() would silently drop transcripts when
        // the user overrides the vault timezone.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f.string(from: date)
    }
}
