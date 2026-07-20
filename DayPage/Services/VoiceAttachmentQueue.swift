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

// MARK: - VoiceAttachmentQueue

@MainActor
final class VoiceAttachmentQueue: ObservableObject {

    static let shared = VoiceAttachmentQueue()

    private let maxAttempts = 3
    private var isProcessing = false
    private var previousOnlineState: Bool? = nil

    // Published state so TodayView / UI can observe
    @Published private(set) var pendingCount: Int = 0

    private var queueURL: URL {
        let drafts = VaultInitializer.vaultURL.appendingPathComponent("drafts", isDirectory: true)
        do { try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true) } catch { DayPageLogger.shared.error("VoiceAttachmentQueue: createDirectory: \(error)") }
        return drafts.appendingPathComponent("voice_queue.json")
    }

    private init() {
        updateCount()
        observeNetworkChanges()
        observeAppActive()
        kickOnLaunch()
    }

    /// Cold-start recovery. The exponential-backoff retry chain
    /// (`scheduleBackoffRetry`) lives entirely in an in-memory `Task.sleep`, so
    /// killing the app mid-chain strands any not-yet-`.failed` entry: only
    /// `attempts` is persisted, not the pending timer. Nothing re-drives the
    /// queue on a fresh launch except `didBecomeActive`, which may fire before
    /// or after this singleton exists. This kicks the queue once at startup
    /// (deferred off the init frame to avoid touching `vaultURL` synchronously —
    /// see the iCloud launch-watchdog fix) so a stranded card resumes instead of
    /// shimmering forever.
    private func kickOnLaunch() {
        Task { @MainActor [weak self] in
            guard let self, self.pendingCount > 0 else { return }
            await self.processQueue()
        }
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
                    Self.applyStatus(.failed, audioPath: entry.audioPath, memoDate: entry.memoDate)
                    changedThisPass = true
                    continue
                }

                if let transcript = await VoiceService.shared.transcribeAudio(at: audioURL) {
                    let written = writeTranscriptBack(transcript: transcript, entry: entry)
                    // Transcription succeeded but the write-back found no
                    // matching attachment (memo deleted / moved / date drift).
                    // Retrying can never help — the target row is gone — so drop
                    // the entry instead of leaving a card frozen at `.pending`
                    // forever while the queue silently thinks it's done. Loud
                    // breadcrumb so this stops being invisible.
                    if !written {
                        SentryReporter.breadcrumb(
                            category: "voice-queue",
                            level: .warning,
                            message: "transcript ready but no matching attachment — dropping entry \(entry.audioPath)"
                        )
                    }
                    entries.remove(at: i)
                    changedThisPass = true
                    consumedOne = true
                    break // reload after mutation so indices stay coherent
                } else {
                    entries[i].attempts += 1
                    entries[i].lastError = "transcription returned nil"
                    if entries[i].attempts >= maxAttempts {
                        entries[i].failed = true
                        // #821: exhausting retries must also write .failed
                        // into the day file — the card UI keys off the
                        // attachment's transcription_status, and leaving it
                        // `pending` froze the shimmer placeholder forever.
                        let wrote = Self.applyStatus(.failed, audioPath: entry.audioPath, memoDate: entry.memoDate)
                        if !wrote {
                            // The queue is about to mark this entry done, but the
                            // attachment status never flipped — the card would
                            // shimmer forever with no retry. Surface it instead
                            // of failing silently.
                            SentryReporter.breadcrumb(
                                category: "voice-queue",
                                level: .warning,
                                message: "retries exhausted but no matching attachment for .failed write: \(entry.audioPath)"
                            )
                        }
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
            if remaining.isEmpty { return }
            if !consumedOne {
                // #821: entries remain but this pass made no progress
                // (transient network / recognizer hiccup). Previously the
                // queue went silent until the next app activation; now it
                // self-schedules an exponential-backoff retry so a pending
                // card never waits on the user backgrounding the app.
                scheduleBackoffRetry(minAttempts: remaining.map(\.attempts).min() ?? 1)
                return
            }
        }
    }

    /// Pending Task for the next backoff-driven processQueue run.
    private var backoffTask: Task<Void, Never>?

    /// Retry pending entries after 15s · 60s · 240s (by attempt count).
    private func scheduleBackoffRetry(minAttempts: Int) {
        guard backoffTask == nil else { return }
        let delay: UInt64
        switch minAttempts {
        case ..<2:  delay = 15_000_000_000
        case 2:     delay = 60_000_000_000
        default:    delay = 240_000_000_000
        }
        backoffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.backoffTask = nil
            await self?.processQueue()
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

    /// Returns whether a matching attachment was found and rewritten. A `false`
    /// means the transcript had nowhere to land — the caller drops the entry.
    @discardableResult
    private func writeTranscriptBack(transcript: String, entry: VoiceQueueEntry) -> Bool {
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
        // Capture watch-origin info so we can send the transcript summary back
        // to the watch after a successful write (the "最近已同步" history feed).
        var watchDuration: Double?
        var isWatchSourced = false
        do {
            try RawStorage.mutate(for: date) { memos in
                let updated = memos.map { memo -> Memo in
                    var copy = memo
                    copy.attachments = memo.attachments.map { att -> Memo.Attachment in
                        guard att.file == audioPath, att.kind == "audio" else { return att }
                        matched = true
                        if memo.device == "Apple Watch" {
                            isWatchSourced = true
                            watchDuration = att.duration
                        }
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

        // Reverse channel: tell the watch this clip is synced + transcribed so
        // its history page can show it under "最近". Keyed by the source
        // filename (the shared correlation key across the WCSession boundary).
        if isWatchSourced {
            let filename = (audioPath as NSString).lastPathComponent
            Task { @MainActor in
                WatchTranscriptSender.shared.send(
                    filename: filename,
                    summary: transcript,
                    duration: watchDuration
                )
            }
        }
        return true
    }

    /// #821: write a bare transcription status onto the matching attachment
    /// (no transcript text). Used when retries are exhausted so the card UI
    /// can downgrade from the shimmer placeholder to the retry affordance.
    /// Same serialization guarantees as `applyTranscript` (RawStorage.mutate
    /// runs inside the shared writeQueue).
    @discardableResult
    nonisolated static func applyStatus(
        _ status: Memo.TranscriptionStatus,
        audioPath: String,
        memoDate: String
    ) -> Bool {
        guard let date = parseMemoDate(memoDate) else { return false }

        var matched = false
        do {
            try RawStorage.mutate(for: date) { memos in
                let updated = memos.map { memo -> Memo in
                    var copy = memo
                    copy.attachments = memo.attachments.map { att -> Memo.Attachment in
                        guard att.file == audioPath, att.kind == "audio" else { return att }
                        matched = true
                        var a = att
                        a.transcriptionStatus = status
                        return a
                    }
                    return copy
                }
                return matched ? updated : nil
            }
        } catch {
            SentryReporter.breadcrumb(
                category: "voice-queue",
                level: .error,
                message: "applyStatus: mutate failed: \(error)"
            )
            return false
        }
        return matched
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
