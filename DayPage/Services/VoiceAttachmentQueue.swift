import Foundation
import UIKit

// MARK: - Queue Entry

private struct VoiceQueueEntry: Codable {
    var id: String
    var audioPath: String   // vault-relative: raw/assets/...
    var createdAt: Date
    var memoDate: String    // yyyy-MM-dd
    var attempts: Int
    var lastError: String?
    var failed: Bool        // true after 3 failed attempts
}

// MARK: - VoiceAttachmentQueue

@MainActor
final class VoiceAttachmentQueue: ObservableObject {

    static let shared = VoiceAttachmentQueue()

    private let maxAttempts = 3
    private var isProcessing = false
    private var previousOnlineState: Bool? = nil

    // Published count so TodayView can observe
    @Published private(set) var pendingCount: Int = 0

    private var queueURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let drafts = docs.appendingPathComponent("vault/drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
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

        var entries = load()
        var changed = false

        for i in entries.indices {
            guard !entries[i].failed else { continue }
            let entry = entries[i]

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let audioURL = docs.appendingPathComponent("vault").appendingPathComponent(entry.audioPath)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                entries[i].failed = true
                entries[i].lastError = "audio file not found"
                changed = true
                continue
            }

            if let transcript = await VoiceService.shared.transcribeAudio(at: audioURL) {
                writeTranscriptBack(transcript: transcript, entry: entry)
                entries.remove(at: i)
                changed = true
                break // reload after mutation
            } else {
                entries[i].attempts += 1
                entries[i].lastError = "transcription returned nil"
                if entries[i].attempts >= maxAttempts {
                    entries[i].failed = true
                }
                changed = true
            }
        }

        if changed {
            save(entries)
            updateCount()
        }

        // If there are still pending non-failed entries, recurse
        let remaining = entries.filter { !$0.failed }
        if !remaining.isEmpty {
            await processQueue()
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let vaultDir = docs.appendingPathComponent("vault")
        let memoFile = vaultDir.appendingPathComponent("raw/\(entry.memoDate).md")
        guard let content = try? String(contentsOf: memoFile, encoding: .utf8) else { return }
        // Replace the first occurrence of the audio path with transcript appended
        let audioPath = entry.audioPath
        let updated = content.replacingOccurrences(
            of: "file: \(audioPath)\n  kind: audio",
            with: "file: \(audioPath)\n  kind: audio\n  transcript: \"\(transcript.replacingOccurrences(of: "\"", with: "\\\""))\""
        )
        guard updated != content else { return }
        try? RawStorage.atomicWrite(string: updated, to: memoFile)
    }

    private func load() -> [VoiceQueueEntry] {
        guard let data = try? Data(contentsOf: queueURL),
              let entries = try? JSONDecoder().decode([VoiceQueueEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func save(_ entries: [VoiceQueueEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }

    private func updateCount() {
        pendingCount = load().filter { !$0.failed }.count
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
