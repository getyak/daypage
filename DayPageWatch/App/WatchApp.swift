import SwiftUI
import WatchConnectivity
import WatchKit
import os

@main
struct DayPageWatchApp: App {

    init() {
        // Initialize WCSession on launch
        WatchSessionManager.shared.activate()
        // Purge stale tmp audio files from failed/interrupted transfers
        OrphanFileCleanup.run()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - OrphanFileCleanup

/// Deletes audio files in the Watch tmp directory that are older than 24 hours.
/// These accumulate when transfers fail and the app is terminated before cleanup.
enum OrphanFileCleanup {

    private static let logger = Logger(subsystem: "com.daypage.watch", category: "OrphanFileCleanup")
    private static let watchTmpDir = "com.daypage.watch"
    private static let maxAge: TimeInterval = 86_400  // 24 hours

    static func run() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(watchTmpDir, isDirectory: true)

        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        var removed = 0

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
            for file in files {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if created < cutoff {
                    try? FileManager.default.removeItem(at: file)
                    removed += 1
                }
            }
        } catch {
            logger.error("Failed to enumerate tmp dir: \(error.localizedDescription)")
            return
        }

        if removed > 0 {
            logger.info("Cleaned up \(removed) orphan file(s) from tmp/\(watchTmpDir)")
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
