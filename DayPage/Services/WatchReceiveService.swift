import Foundation
import WatchConnectivity
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - WatchReceiveService

/// Receives audio files transferred from the DayPageWatch app on Apple Watch.
/// Moves received files into the DayPage vault (raw/assets/) for processing.
@MainActor
final class WatchReceiveService: NSObject, ObservableObject {

    static let shared = WatchReceiveService()

    @Published var lastReceivedFile: URL?
    @Published var lastError: String?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchReceiveService: WCSessionDelegate {

    // WCSessionDelegate callbacks arrive on an arbitrary background thread.
    // Mark each method nonisolated and hop back to MainActor only for @Published mutations.

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            DayPageLogger.log(level: "ERROR", message: "WatchReceiveService activation error: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Called when the iPhone receives a file transfer from the Watch.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let sourceURL = file.fileURL
        let metadata = file.metadata ?? [:]

        guard let type = metadata["type"] as? String, type == "watchAudio" else {
            DayPageLogger.log(level: "WARN", message: "WatchReceiveService ignored file with type: \(metadata["type"] ?? "nil")")
            return
        }

        // Strip any path separators / ".." segments to prevent path traversal.
        let rawFilename = metadata["filename"] as? String ?? sourceURL.lastPathComponent
        let filename = (rawFilename as NSString).lastPathComponent

        // Move to vault: raw/assets/watch_<filename>
        do {
            let assetsURL = try VaultInitializer.assetsDirectory()
            let destURL = assetsURL.appendingPathComponent("watch_\(filename)")
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destURL)

            DayPageLogger.log(level: "INFO", message: "WatchReceiveService saved watch audio to: \(destURL.lastPathComponent)")

            // Vault-relative path: raw/assets/watch_<filename>
            let vaultRoot = VaultInitializer.vaultURL
            let audioPath = destURL.path.hasPrefix(vaultRoot.path)
                ? String(destURL.path.dropFirst(vaultRoot.path.count + 1))
                : "raw/assets/\(destURL.lastPathComponent)"

            // A single `now` shared by the memo's `created` date and the
            // transcription enqueue: `VoiceAttachmentQueue.applyTranscript`
            // resolves the day file from `memoDate`, and it must land on the
            // same day as the memo we append below or the transcript can never
            // match the attachment (att.file == audioPath) and would exhaust
            // retries into `.failed`.
            let now = Date()
            let duration = metadata["duration"] as? Double

            // Bug fix: the receiver previously only enqueued transcription,
            // which bumped the "N pending" count but never created a memo — so
            // the audio file arrived and the count showed, yet no card ever
            // appeared in Today. Mirror the phone-side capture path by writing
            // a voice memo into today's raw file.
            Self.appendVoiceMemo(audioPath: audioPath, duration: duration, created: now)

            Task { @MainActor in
                self.lastReceivedFile = destURL
                VoiceAttachmentQueue.shared.enqueue(audioPath: audioPath, memoDate: now)
            }
        } catch {
            DayPageLogger.log(level: "ERROR", message: "WatchReceiveService failed to move file: \(error.localizedDescription)")
            Task { @MainActor in
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Build and persist the voice memo for a received watch audio clip.
    ///
    /// Mirrors the phone-side capture path (`TodayViewModel.submit` →
    /// `RawStorage.append`): a `.voice` memo carrying one `audio` attachment in
    /// the `.pending` transcription state, so the Today timeline shows a card
    /// immediately and `VoiceAttachmentQueue` can later patch the transcript
    /// onto the exact attachment whose `file` matches `audioPath`.
    ///
    /// `internal static` and returns the memo purely for test access — the
    /// production caller ignores the return value.
    @discardableResult
    nonisolated static func appendVoiceMemo(audioPath: String, duration: Double?, created: Date) -> Memo {
        let attachment = Memo.Attachment(
            file: audioPath,
            kind: "audio",
            duration: duration,
            transcript: nil,
            transcriptionStatus: .pending
        )
        let memo = Memo(
            type: .voice,
            created: created,
            device: "Apple Watch",
            attachments: [attachment]
        )
        do {
            try RawStorage.append(memo)
            DayPageLogger.log(level: "INFO", message: "WatchReceiveService appended voice memo \(memo.id) to \(created)")
        } catch {
            DayPageLogger.log(level: "ERROR", message: "WatchReceiveService failed to append memo: \(error.localizedDescription)")
        }
        return memo
    }
}
