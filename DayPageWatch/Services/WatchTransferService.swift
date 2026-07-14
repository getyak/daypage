import Foundation
import WatchConnectivity
import os
import DayPageServices

// MARK: - WatchTransferService

/// Manages transferring audio files from the Watch to the companion iPhone via WCSession.
/// WCSession activation and delegation are owned by WatchSessionManager; this service
/// only queues file transfers and listens for their completion callbacks.
@MainActor final class WatchTransferService: NSObject {

    static let shared = WatchTransferService()

    /// Per-file completion handlers keyed by file URL, so concurrent transfers are safe.
    private var pendingCompletions: [URL: (Bool) -> Void] = [:]

    private let logger = Logger(subsystem: "com.daypage.watch", category: "WatchTransferService")

    /// Retained duration (seconds) per in-flight file, so a retry re-sends the
    /// same duration metadata without the caller having to thread it back in.
    private var pendingDurations: [URL: Double] = [:]

    private override init() {
        super.init()
        // Do NOT set WCSession.default.delegate here — WatchSessionManager owns the delegate
        // and will forward didFinish events to this service.
        // Let the history page's retry button re-drive a failed transfer.
        WatchHistoryStore.shared.retryHandler = { [weak self] url in
            self?.retryTransfer(url)
        }
    }

    /// Transfer an audio file to the companion iPhone.
    /// `duration` (seconds) is forwarded in the transfer metadata so the phone
    /// can show the clip length on the voice memo card without re-probing the file.
    func transferAudioFile(_ fileURL: URL, duration: Double? = nil, completion: @escaping (Bool) -> Void) {
        guard WCSession.default.activationState == .activated else {
            logger.error("WCSession not activated — cannot transfer \(fileURL.lastPathComponent)")
            completion(false)
            return
        }

        pendingCompletions[fileURL] = completion
        if let duration { pendingDurations[fileURL] = duration }

        // Reflect the queued transfer in the history page's "in-flight" section.
        WatchHistoryStore.shared.markSending(fileURL: fileURL, duration: Int(duration ?? 0))

        WCSession.default.transferFile(fileURL, metadata: metadata(for: fileURL, duration: duration))
        logger.info("Queued transfer for \(fileURL.lastPathComponent)")
    }

    /// Re-drive a previously-failed transfer (history retry button). The source
    /// file was kept on failure precisely so this can resend it.
    func retryTransfer(_ fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // File is gone (cleaned up / already delivered) — drop it from history.
            WatchHistoryStore.shared.markDelivered(fileURL: fileURL)
            return
        }
        guard WCSession.default.activationState == .activated else {
            WatchHistoryStore.shared.markFailed(fileURL: fileURL)
            return
        }
        let duration = pendingDurations[fileURL]
        WatchHistoryStore.shared.markSending(fileURL: fileURL, duration: Int(duration ?? 0))
        WCSession.default.transferFile(fileURL, metadata: metadata(for: fileURL, duration: duration))
        logger.info("Retrying transfer for \(fileURL.lastPathComponent)")
    }

    private func metadata(for fileURL: URL, duration: Double?) -> [String: Any] {
        var metadata: [String: Any] = [
            "type": "watchAudio",
            "source": "daypage-watch",
            "timestamp": Date().timeIntervalSince1970,
            "filename": fileURL.lastPathComponent,
        ]
        if let duration { metadata["duration"] = duration }
        return metadata
    }

    /// Called by WatchSessionManager when a file transfer finishes.
    func handleTransferFinished(fileURL: URL, error: Error?) {
        let completion = pendingCompletions.removeValue(forKey: fileURL)

        if let error {
            // Keep the source file so the history retry can resend it — do NOT
            // delete on failure. It ages out per the retention policy instead.
            logger.error("Transfer failed for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            WatchHistoryStore.shared.markFailed(fileURL: fileURL)
            completion?(false)
            return
        }

        logger.info("Transfer succeeded: \(fileURL.lastPathComponent)")
        WatchHistoryStore.shared.markDelivered(fileURL: fileURL)
        pendingDurations.removeValue(forKey: fileURL)
        completion?(true)

        // Delivered — safe to remove the source file.
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            logger.warning("Failed to remove transferred file \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
