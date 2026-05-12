import SwiftUI
import WatchConnectivity
import WatchKit
import os

@main
struct DayPageWatchApp: App {

    init() {
        // Initialize WCSession on launch
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - WCSession Manager

@MainActor final class WatchSessionManager: NSObject, ObservableObject {

    static let shared = WatchSessionManager()

    private let logger = Logger(subsystem: "com.daypage.watch", category: "WatchSessionManager")

    private override init() {}

    func activate() {
        guard WCSession.isSupported() else {
            logger.error("WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            logger.error("Activation error: \(error.localizedDescription)")
        } else {
            logger.info("Activated with state: \(activationState.rawValue)")
        }
    }

    /// Forward file transfer completion to WatchTransferService so it can
    /// call the per-file completion handler and clean up the source file.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        WatchTransferService.shared.handleTransferFinished(
            fileURL: fileTransfer.file.fileURL,
            error: error
        )
    }
}
