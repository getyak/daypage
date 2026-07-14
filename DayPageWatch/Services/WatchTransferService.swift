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

    private override init() {
        super.init()
        // Do NOT set WCSession.default.delegate here — WatchSessionManager owns the delegate
        // and will forward didFinish events to this service.
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

        var metadata: [String: Any] = [
            "type": "watchAudio",
            "source": "daypage-watch",
            "timestamp": Date().timeIntervalSince1970,
            "filename": fileURL.lastPathComponent,
        ]
        if let duration {
            metadata["duration"] = duration
        }

        WCSession.default.transferFile(fileURL, metadata: metadata)
        logger.info("Queued transfer for \(fileURL.lastPathComponent)")
    }

    /// Called by WatchSessionManager when a file transfer finishes.
    func handleTransferFinished(fileURL: URL, error: Error?) {
        guard let completion = pendingCompletions.removeValue(forKey: fileURL) else { return }
        if let error {
            logger.error("Transfer failed for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            completion(false)
        } else {
            logger.info("Transfer succeeded: \(fileURL.lastPathComponent)")
            completion(true)
        }
        // Safe to remove the source file now that the transfer is confirmed finished.
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            logger.warning("Failed to remove transferred file \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
