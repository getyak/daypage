import Foundation
import WatchConnectivity

// MARK: - WatchTransferService

/// Manages transferring audio files from the Watch to the companion iPhone via WCSession.
/// WCSession activation and delegation are owned by WatchSessionManager; this service
/// only queues file transfers and listens for their completion callbacks.
@MainActor final class WatchTransferService: NSObject {

    static let shared = WatchTransferService()

    /// Per-file completion handlers keyed by file URL, so concurrent transfers are safe.
    private var pendingCompletions: [URL: (Bool) -> Void] = [:]

    private override init() {
        super.init()
        // Do NOT set WCSession.default.delegate here — WatchSessionManager owns the delegate
        // and will forward didFinish events to this service.
    }

    /// Transfer an audio file to the companion iPhone.
    func transferAudioFile(_ fileURL: URL, completion: @escaping (Bool) -> Void) {
        guard WCSession.default.activationState == .activated else {
            print("[WatchTransferService] WCSession not activated")
            completion(false)
            return
        }

        pendingCompletions[fileURL] = completion

        let metadata: [String: Any] = [
            "type": "watchAudio",
            "source": "daypage-watch",
            "timestamp": Date().timeIntervalSince1970,
            "filename": fileURL.lastPathComponent,
        ]

        WCSession.default.transferFile(fileURL, metadata: metadata)
        print("[WatchTransferService] Queued transfer for \(fileURL.lastPathComponent)")
    }

    /// Called by WatchSessionManager when a file transfer finishes.
    func handleTransferFinished(fileURL: URL, error: Error?) {
        guard let completion = pendingCompletions.removeValue(forKey: fileURL) else { return }
        if let error {
            print("[WatchTransferService] Transfer failed: \(error.localizedDescription)")
            completion(false)
        } else {
            print("[WatchTransferService] Transfer succeeded: \(fileURL.lastPathComponent)")
            completion(true)
        }
        // Safe to remove the source file now that the transfer is confirmed finished.
        try? FileManager.default.removeItem(at: fileURL)
    }
}
