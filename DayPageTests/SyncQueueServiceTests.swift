// SyncQueueServiceTests.swift — Round 5 (R5-FEATURE: 离线同步队列)
//
// Validates the metadata-queue contract:
//   - enqueue grows count + totalBytes + stamps oldestPendingDate
//   - markSynced shrinks count + clears oldestPendingDate when emptied
//   - state survives a "process restart" (new instance, same defaults)
//   - duplicate enqueue de-duplicates (Set semantics + byte tally)
//   - Uses an isolated UserDefaults suite per test so cases don't pollute
//     `.standard` or each other.
//
// Why Swift Testing: matches the existing test target style (see
// `KeychainHelperTests`, `LocationServiceLRUTests`).

import Testing
import Foundation
@testable import DayPage

@MainActor
struct SyncQueueServiceTests {

    // MARK: - Helpers

    /// Build a fresh service bound to a private UserDefaults suite and
    /// nuke any leftover values from previous runs. Each test calls this
    /// with its own suite name so state can't bleed between cases.
    private func makeService(suite: String = UUID().uuidString) -> SyncQueueService {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SyncQueueService.makeForTesting(defaults: defaults)
    }

    /// Build a service bound to a *named* suite — used by the restart
    /// test where the first instance writes to suite "X" and a second
    /// instance reads from suite "X" to simulate a process restart.
    private func makeService(suite: String, fresh: Bool) -> SyncQueueService {
        let defaults = UserDefaults(suiteName: suite)!
        if fresh { defaults.removePersistentDomain(forName: suite) }
        return SyncQueueService.makeForTesting(defaults: defaults)
    }

    // MARK: - enqueue

    @Test
    func enqueueGrowsCountAndBytes() {
        let svc = makeService()
        #expect(svc.isEmpty)
        #expect(svc.pendingCount == 0)
        #expect(svc.totalBytes == 0)
        #expect(svc.oldestPendingDate == nil)

        svc.enqueue(memoID: "memo-A", sizeBytes: 1024)

        #expect(svc.pendingCount == 1)
        #expect(svc.totalBytes == 1024)
        #expect(svc.oldestPendingDate != nil)
        #expect(!svc.isEmpty)
    }

    // MARK: - markSynced

    @Test
    func markSyncedClearsStateWhenEmptied() {
        let svc = makeService()
        svc.enqueue(memoID: "memo-A", sizeBytes: 500)
        svc.enqueue(memoID: "memo-B", sizeBytes: 700)
        #expect(svc.pendingCount == 2)
        #expect(svc.totalBytes == 1200)

        svc.markSynced(memoID: "memo-A")
        // Still one outstanding — clock should stay set.
        #expect(svc.pendingCount == 1)
        #expect(svc.totalBytes == 700)
        #expect(svc.oldestPendingDate != nil)

        svc.markSynced(memoID: "memo-B")
        // Queue drained — clock + bytes must reset.
        #expect(svc.pendingCount == 0)
        #expect(svc.totalBytes == 0)
        #expect(svc.oldestPendingDate == nil)
        #expect(svc.isEmpty)
    }

    // MARK: - persistence

    @Test
    func stateSurvivesRestart() {
        let suite = "SyncQueueServiceTests.restart.\(UUID().uuidString)"

        // First "process": enqueue 2 memos and drop the reference.
        do {
            let svc = makeService(suite: suite, fresh: true)
            svc.enqueue(memoID: "memo-A", sizeBytes: 100)
            svc.enqueue(memoID: "memo-B", sizeBytes: 200)
            _ = svc  // silence unused warning
        }

        // Second "process": rehydrate from the same suite without
        // wiping. The new instance must see both memos.
        let restored = makeService(suite: suite, fresh: false)
        #expect(restored.pendingCount == 2)
        #expect(restored.pendingMemoIDs.contains("memo-A"))
        #expect(restored.pendingMemoIDs.contains("memo-B"))
        #expect(restored.totalBytes == 300)
        #expect(restored.oldestPendingDate != nil)

        // Cleanup — don't leak a named suite onto the simulator/disk.
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    // MARK: - dedupe

    @Test
    func duplicateEnqueueDeduplicates() {
        let svc = makeService()
        svc.enqueue(memoID: "memo-A", sizeBytes: 1000)
        let firstClock = svc.oldestPendingDate

        // Same ID twice — count must stay at 1, bytes must NOT
        // double-count, oldestPendingDate must NOT shift.
        svc.enqueue(memoID: "memo-A", sizeBytes: 1000)
        svc.enqueue(memoID: "memo-A", sizeBytes: 1000)

        #expect(svc.pendingCount == 1)
        #expect(svc.totalBytes == 1000)
        #expect(svc.oldestPendingDate == firstClock)
    }

    // MARK: - oldestPendingDate stamping

    @Test
    func oldestPendingDateStampedOnceUntilDrained() {
        let svc = makeService()
        svc.enqueue(memoID: "memo-A", sizeBytes: 100)
        let firstStamp = svc.oldestPendingDate
        #expect(firstStamp != nil)

        // A second, distinct enqueue must NOT push the clock forward —
        // the "已等待 N 小时" banner is meaningful only when it tracks
        // the oldest still-pending memo.
        svc.enqueue(memoID: "memo-B", sizeBytes: 200)
        #expect(svc.oldestPendingDate == firstStamp)

        // Drain the queue — the clock should clear.
        svc.markSynced(memoID: "memo-A")
        svc.markSynced(memoID: "memo-B")
        #expect(svc.oldestPendingDate == nil)

        // A new enqueue after drain should stamp a *fresh* clock,
        // strictly later-or-equal than the original (clock resolution
        // may be coarse, so use >= rather than >).
        svc.enqueue(memoID: "memo-C", sizeBytes: 50)
        if let firstStamp, let newStamp = svc.oldestPendingDate {
            #expect(newStamp >= firstStamp)
        } else {
            Issue.record("expected a fresh oldestPendingDate after drain+enqueue")
        }
    }

    // MARK: - size tracking (R8 fix)

    /// Regression test for the R8 SyncQueue fix: callers (e.g. the Noop
    /// uploader) used to be trusted to pass `sizeBytes` back into
    /// `markSynced`, but the placeholder uploader returns 0, which left
    /// `totalBytes` stuck at the original enqueue value. The new
    /// `markSynced(memoID:)` form looks the size up from the dict
    /// populated at enqueue, so a partial drain produces an accurate
    /// running total.
    @Test
    func markSyncedDecrementsByEnqueueRecordedSize() {
        let svc = makeService()
        svc.enqueue(memoID: "memo-A", sizeBytes: 1000)
        svc.enqueue(memoID: "memo-B", sizeBytes: 250)
        #expect(svc.totalBytes == 1250)

        // Caller passes no size — service must subtract 1000 (memo-A's
        // recorded size), not leave totalBytes at 1250.
        svc.markSynced(memoID: "memo-A")
        #expect(svc.pendingCount == 1)
        #expect(svc.totalBytes == 250)

        svc.markSynced(memoID: "memo-B")
        #expect(svc.totalBytes == 0)
        #expect(svc.isEmpty)
    }
}
