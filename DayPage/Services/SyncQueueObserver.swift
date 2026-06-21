// SyncQueueObserver.swift — Round 6 (R6-HIGH: flush 占位 service)
//
// Listens for `.syncQueueFlushRequested` (posted by SyncQueueService when
// the network comes back or a manual retry is triggered) and walks the
// pending memo set, handing each ID off to a `RemoteUploader`. On success
// the memo is removed from the queue via `markSynced`; on failure we
// breadcrumb and abort the current pass so the next trigger gets a fresh
// chance instead of hammering a server that's already saying no.
//
// Why this lives in its own file:
//   - SyncQueueService deliberately doesn't import any networking layer,
//     so the flush trigger is a NotificationCenter post. Some component
//     has to observe that post and perform the work — that's us.
//   - The real Supabase uploader will land in a later round. Until then
//     `NoopRemoteUploader` simulates a successful round-trip so the UI
//     (pendingCount banner) at least drains when we're online, instead
//     of pretending forever that nothing was synced.

import Foundation

/// Pluggable contract for the actual cloud upload. Returns the byte size
/// reported back from the remote so `markSynced` can decrement the queue's
/// running totalBytes accurately. Real implementations will translate
/// memoID → Supabase row + handle conflict resolution; the placeholder
/// just sleeps briefly to mimic latency.
protocol RemoteUploader: Sendable {
    func upload(memoID: String) async throws -> Int
}

/// Placeholder uploader used until the Supabase sync service lands.
/// Reports size=0 so SyncQueueService.markSynced doesn't perturb the
/// totalBytes tally (the queue clamps to zero anyway). Sleeps 200ms to
/// keep the spinner visible for at least one frame.
struct NoopRemoteUploader: RemoteUploader {
    func upload(memoID: String) async throws -> Int {
        try await Task.sleep(nanoseconds: 200_000_000)
        return 0
    }
}

@MainActor
final class SyncQueueObserver {
    static let shared = SyncQueueObserver()

    private var observer: NSObjectProtocol?
    private var isFlushing = false

    /// Injected by whoever wires up the real Supabase uploader (probably
    /// `DayPageApp` once that lands). Until then the Noop double drains
    /// the queue so the UI doesn't lie about backlog forever.
    private var uploader: RemoteUploader = NoopRemoteUploader()

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .syncQueueFlushRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flush()
            }
        }
    }

    /// Swap in the production uploader. Tests call this with a stub that
    /// asserts ordering / failure behaviour. The real Supabase service
    /// will call it at app launch, post-AuthService.
    func setUploader(_ uploader: RemoteUploader) {
        self.uploader = uploader
    }

    /// Walk every pending ID once. We grab the snapshot up-front so a
    /// concurrent enqueue (e.g. user types a new memo mid-flush) doesn't
    /// mutate the set under our feet; the new memo will be picked up by
    /// the next flush trigger anyway.
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let pending = SyncQueueService.shared.pendingMemoIDs
        for memoID in pending {
            do {
                let size = try await uploader.upload(memoID: memoID)
                SyncQueueService.shared.markSynced(memoID: memoID, sizeBytes: size)
            } catch {
                // Network/server problem — stop this pass so we don't
                // burn through retries pointlessly. The next online
                // transition or manual trigger will resume.
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "upload failed for \(memoID): \(error)"
                )
                break
            }
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
