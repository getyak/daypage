import Foundation
import WatchConnectivity

// MARK: - WatchTransferService

/// Manages transferring audio files from the Watch to the companion iPhone via WCSession.
final class WatchTransferService: NSObject {

    static let shared = WatchTransferService()

    private var transferCompletion: ((Bool) -> Void)?
    private var currentFileURL: URL?

    private override init() {
        super.init()
        // Ensure the session delegate is set (WatchSessionManager in WatchApp.swift handles activation,
        // but we also need to be the delegate here for transfer callbacks).
        if WCSession.isSupported() {
            WCSession.default.delegate = self
        }
    }

    /// Transfer an audio file to the companion iPhone.
    func transferAudioFile(_ fileURL: URL, completion: @escaping (Bool) -> Void) {
        guard WCSession.default.activationState == .activated else {
            print("[WatchTransferService] WCSession not activated")
            completion(false)
            return
        }

        currentFileURL = fileURL
        transferCompletion = completion

        let metadata: [String: Any] = [
            "type": "watchAudio",
            "source": "daypage-watch",
            "timestamp": Date().timeIntervalSince1970,
            "filename": fileURL.lastPathComponent,
        ]

        WCSession.default.transferFile(fileURL, metadata: metadata)
        print("[WatchTransferService] Queued transfer for \(fileURL.lastPathComponent)")
    }
}

// MARK: - WCSessionDelegate

extension WatchTransferService: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Handled by WatchSessionManager
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error {
            print("[WatchTransferService] Transfer failed: \(error.localizedDescription)")
            transferCompletion?(false)
        } else {
            print("[WatchTransferService] Transfer succeeded: \(fileTransfer.file.fileURL.lastPathComponent)")
            transferCompletion?(true)
        }
        transferCompletion = nil
        currentFileURL = nil
    }
}
