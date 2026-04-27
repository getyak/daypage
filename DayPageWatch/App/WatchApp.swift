import SwiftUI
import WatchConnectivity
import WatchKit

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

final class WatchSessionManager: NSObject, ObservableObject {

    static let shared = WatchSessionManager()

    private override init() {}

    func activate() {
        guard WCSession.isSupported() else {
            print("[WatchSessionManager] WCSession not supported on this device")
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
            print("[WatchSessionManager] activation error: \(error.localizedDescription)")
        } else {
            print("[WatchSessionManager] activated with state: \(activationState.rawValue)")
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}
