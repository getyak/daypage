import Foundation
import WatchConnectivity

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

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            print("[WatchReceiveService] activation error: \(error.localizedDescription)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Called when the iPhone receives a file transfer from the Watch.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let sourceURL = file.fileURL
        let metadata = file.metadata ?? [:]

        guard let type = metadata["type"] as? String, type == "watchAudio" else {
            print("[WatchReceiveService] Ignored file with type: \(metadata["type"] ?? "nil")")
            return
        }

        let filename = metadata["filename"] as? String ?? sourceURL.lastPathComponent

        // Move to vault: raw/assets/watch_<filename>
        let assetsURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")

        do {
            try FileManager.default.createDirectory(at: assetsURL,
                                                    withIntermediateDirectories: true)
            let destURL = assetsURL.appendingPathComponent("watch_\(filename)")
            // Remove any existing file at destination
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destURL)

            print("[WatchReceiveService] Saved watch audio to: \(destURL.path)")

            Task { @MainActor in
                lastReceivedFile = destURL
            }
        } catch {
            print("[WatchReceiveService] Failed to move file: \(error.localizedDescription)")
            Task { @MainActor in
                lastError = error.localizedDescription
            }
        }
    }
}
