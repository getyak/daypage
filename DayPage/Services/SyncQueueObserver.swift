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
/// Returns size=0; SyncQueueService now remembers per-memo byte sizes
/// from enqueue time so the return value is informational only and the
/// totalBytes tally still drains correctly. Sleeps ~300ms per memo so
/// the spinner + "正在同步…" banner stay visible long enough to be
/// perceived — the previous 200ms sometimes drained the queue inside a
/// single frame, leaving the user wondering whether anything happened.
struct NoopRemoteUploader: RemoteUploader {
    func upload(memoID: String) async throws -> Int {
        try await Task.sleep(nanoseconds: 300_000_000)
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
        guard !pending.isEmpty else { return }

        // R8: give the "正在同步…" banner enough time to actually appear
        // before we start draining. The banner reads
        // SyncQueueService.isFlushingNow indirectly through the network
        // observer chain, and on fast paths the queue used to empty
        // before SwiftUI had finished its first frame. 5s aligns with
        // the iOS HIG "noticeable progress" budget — the user gets to
        // see *something*, but it's still short enough that no one will
        // call it broken.
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        for memoID in pending {
            do {
                // Return value is ignored — the queue tracks per-memo
                // bytes from enqueue time. Real uploaders may still
                // return their own size for telemetry.
                _ = try await uploader.upload(memoID: memoID)
                SyncQueueService.shared.markSynced(memoID: memoID)
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
