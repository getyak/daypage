import SwiftUI
import WatchConnectivity
import WatchKit
import os
import DayPageServices

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

/// Removes leftover audio files in the Watch tmp directory.
///
/// Every file here is, by construction, **undelivered**: a successful transfer
/// deletes its source file in `WatchTransferService.handleTransferFinished`, so
/// anything that lingers is from a failed or interrupted transfer. How long to
/// keep such a file before giving up on it is the user's `WatchRetentionPolicy`:
///
///   - `.oneDay` / `.sevenDays` — delete once older than the window
///   - `.untilDelivered`        — never age-delete; keep until the transfer
///                                confirms delivery (the paired-device model's
///                                answer to "watch was away from phone too long")
///
/// This replaces the old hardcoded 24h window, which silently dropped a memo
/// when the watch stayed away from its phone for more than a day.
enum OrphanFileCleanup {

    private static let logger = Logger(subsystem: "com.daypage.watch", category: "OrphanFileCleanup")
    private static let watchTmpDir = "com.daypage.watch"

    /// Pure age decision — `internal static` for test access. Returns true when
    /// an undelivered file created at `created` should be removed under `policy`
    /// as of `now`. `.untilDelivered` (nil max age) never age-deletes.
    static func shouldDelete(created: Date, now: Date, policy: WatchRetentionPolicy) -> Bool {
        guard let maxAge = policy.maxUndeliveredAge else { return false }
        return now.timeIntervalSince(created) > maxAge
    }

    /// `policy` defaults to the user's current setting (resolved inside the
    /// main-actor body — a default argument can't read the MainActor store).
    @MainActor
    static func run(policy: WatchRetentionPolicy? = nil) {
        let policy = policy ?? WatchSettingsStore.shared.retentionPolicy

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(watchTmpDir, isDirectory: true)

        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        // Nothing to age out — undelivered files are kept until delivered.
        guard policy.maxUndeliveredAge != nil else { return }

        let now = Date()
        var removed = 0

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
            for file in files {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if shouldDelete(created: created, now: now, policy: policy) {
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

    private nonisolated let logger = Logger(subsystem: "com.daypage.watch", category: "WatchSessionManager")

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

    // WCSessionDelegate callbacks arrive on an arbitrary background thread, so each
    // method is nonisolated; hop back to the MainActor for any isolated state.
    nonisolated func session(_ session: WCSession,
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
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let fileURL = fileTransfer.file.fileURL
        Task { @MainActor in
            WatchTransferService.shared.handleTransferFinished(
                fileURL: fileURL,
                error: error
            )
        }
    }
}
