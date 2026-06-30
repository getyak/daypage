// SyncQueueService.swift — Round 5 (R5-FEATURE: 离线同步队列)
//
// Tracks memo IDs that were captured while the device was offline (or while
// the Supabase round-trip failed) so the Today banner can tell the user "N
// 条 memo 待同步" and an external sync service can flush them when the
// network comes back.
//
// Why this exists:
//   - Until now, an offline capture wrote to vault/raw/YYYY-MM-DD.md, but
//     nothing summarised pending Supabase writes for the user. People with
//     spotty Wi-Fi were left guessing whether their note had really made
//     it to the cloud.
//   - The queue is intentionally **metadata-only** — it holds memo IDs +
//     a rough byte counter + the oldest-pending timestamp. The actual
//     upload payload lives in vault/raw/ on disk; SyncQueueService just
//     tells the UI/sync layer what's outstanding.
//   - Flush is delegated via `Notification.Name.syncQueueFlushRequested`
//     so we don't take a build-time dependency on the Supabase sync
//     service from this file (the Supabase service can wire up the
//     observer at its own convenience).

import Foundation
import Combine
import DayPageModels

/// Process-wide, @MainActor singleton tracking memo IDs awaiting Supabase
/// sync. All published state drives SwiftUI, so it must mutate on the main
/// actor.
@MainActor
public final class SyncQueueService: ObservableObject {
    public static let shared = SyncQueueService()

    /// Memo IDs awaiting upload. Stored as a Set so duplicate enqueues
    /// (e.g. retry-after-failure) collapse to a single entry.
    @Published public private(set) var pendingMemoIDs: Set<String> = []

    /// Cumulative byte size of pending memos (rough estimate, used only
    /// for telemetry / future "X MB queued" UI). Caller passes
    /// `sizeBytes` on enqueue/markSynced — we trust the caller to provide
    /// matching values for the same memo ID.
    @Published public private(set) var totalBytes: Int = 0

    /// When the oldest currently-pending memo was enqueued. Drives the
    /// "已等待 N 小时" red-text variant in the Today banner. Reset to
    /// nil when the queue empties.
    @Published public private(set) var oldestPendingDate: Date?

    /// True while a flush attempt is in-flight. Set/cleared inside
    /// `flushIfOnline` and inspected by the banner to disable retries.
    @Published public private(set) var isFlushingNow: Bool = false

    /// Convenience accessors — these aren't `@Published` themselves but
    /// will recompute whenever `pendingMemoIDs` does because callers
    /// observe the underlying Set.
    public var pendingCount: Int { pendingMemoIDs.count }
    public var isEmpty: Bool { pendingMemoIDs.isEmpty }

    // R8 fix: remember the size each memo was enqueued with so markSynced
    // doesn't have to trust an out-of-band caller (e.g. NoopRemoteUploader
    // returns 0, which used to leave totalBytes stuck at the original
    // enqueue value). Keys = memo IDs in `pendingMemoIDs`; values = bytes
    // counted into `totalBytes`. Persisted alongside the ID set.
    private var memoSizes: [String: Int] = [:]

    // MARK: - Persistence

    // The queue must survive process restarts — if a user enqueued five
    // memos and then iOS reaped the app, those memos must still appear in
    // the banner on next launch. Stored in UserDefaults rather than
    // Vault/ because the queue is metadata about the local vault, not a
    // user-visible artifact.
    private let userDefaultsKey = "syncQueue.pendingMemoIDs"
    private let bytesKey        = "syncQueue.totalBytes"
    private let oldestKey       = "syncQueue.oldestDate"
    private let sizesKey        = "syncQueue.memoSizes"

    /// Allows tests to inject a private UserDefaults suite so they don't
    /// pollute the shared standard suite. Production callers use
    /// `SyncQueueService.shared`, which captures `.standard`.
    private let defaults: UserDefaults

    private var cancellables = Set<AnyCancellable>()

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreFromDisk()
        observeNetwork()
    }

    /// Test-only constructor — lets `SyncQueueServiceTests` create a
    /// fresh instance bound to a throwaway `UserDefaults(suiteName:)` so
    /// state can't bleed across test cases. Not for production use.
    public static func makeForTesting(defaults: UserDefaults) -> SyncQueueService {
        SyncQueueService(defaults: defaults)
    }

    // MARK: - Public mutation API

    /// Add a memo to the queue. Idempotent: re-enqueuing the same ID is
    /// a no-op for the count + byte tally (Set semantics dedupe the ID;
    /// we early-return so the byte counter doesn't double-count).
    public func enqueue(memoID: String, sizeBytes: Int) {
        guard !pendingMemoIDs.contains(memoID) else { return }
        pendingMemoIDs.insert(memoID)
        let clamped = max(0, sizeBytes)
        memoSizes[memoID] = clamped
        totalBytes += clamped
        // Only stamp the oldest-pending clock when transitioning from
        // empty → non-empty. Subsequent enqueues should not push the
        // "已等待 N 小时" counter back to zero.
        if oldestPendingDate == nil {
            oldestPendingDate = Date()
        }
        persistToDisk()
    }

    /// Mark a memo as successfully synced. Removes the ID from the set
    /// and decrements the byte tally using the size that was recorded at
    /// enqueue time, so a remote uploader returning size=0 (e.g. the
    /// placeholder Noop uploader) still produces a correct totalBytes
    /// decrement instead of leaving a phantom byte count behind. When
    /// the queue empties, the oldest-pending clock is cleared so a
    /// future enqueue starts fresh.
    public func markSynced(memoID: String) {
        guard pendingMemoIDs.contains(memoID) else { return }
        pendingMemoIDs.remove(memoID)
        // R9 fix: if a memo arrived via legacy restoreFromDisk (older
        // build wrote pendingMemoIDs but never persisted memoSizes), the
        // dict will be empty for that ID. Falling back to 0 leaves
        // totalBytes phantom-high; instead, walk vault/raw to find the
        // actual file size — slow (O(N files)) but only on first drain
        // after a legacy migration. New enqueue/markSynced cycles keep
        // hitting the dict cache.
        let recorded: Int
        if let cached = memoSizes.removeValue(forKey: memoID) {
            recorded = cached
        } else {
            recorded = estimateMemoSize(memoID)
        }
        totalBytes = max(0, totalBytes - recorded)
        if pendingMemoIDs.isEmpty {
            oldestPendingDate = nil
            // Belt-and-braces: if memoSizes ever drifts from totalBytes
            // (e.g. legacy state restored from an older build), zero out
            // here so the UI never shows a phantom byte count.
            totalBytes = 0
            memoSizes.removeAll()
        }
        persistToDisk()
    }

    /// Fallback size estimator for legacy queue entries whose `memoSizes`
    /// dict entry was lost across a build upgrade. Scans `vault/raw/*.md`
    /// for a memo whose frontmatter `id:` field matches `memoID` and
    /// returns the file's UTF-8 byte count. Returns 200 (rough average
    /// memo length) when the vault is unreachable or the memo can't be
    /// found — better to over-credit a small constant than to under-
    /// credit zero and leave a phantom byte tally behind.
    ///
    /// Intentionally O(N files): only invoked on the cold path where a
    /// markSynced lookup misses the in-memory dict, i.e. once per
    /// legacy-migrated memo during the next drain.
    private func estimateMemoSize(_ memoID: String) -> Int {
        let fallback = 200
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: rawDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return fallback
        }
        let needle = "id: \(memoID)"
        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if content.contains(needle) {
                return content.utf8.count
            }
        }
        return fallback
    }

    /// Trigger a flush attempt if (a) online, (b) not already flushing,
    /// (c) the queue is non-empty. We deliberately don't perform the
    /// upload here — instead we post `.syncQueueFlushRequested` so the
    /// Supabase sync service (or a test double) handles it. Keeps this
    /// file free of any networking imports beyond NetworkMonitor.
    public func flushIfOnline() async {
        guard NetworkMonitor.shared.isOnline,
              !isFlushingNow,
              !isEmpty else { return }
        isFlushingNow = true
        defer { isFlushingNow = false }
        NotificationCenter.default.post(name: .syncQueueFlushRequested, object: nil)
    }

    // MARK: - Network observation

    /// When the device comes back online, automatically request a flush.
    /// `removeDuplicates` keeps us from re-firing on every NWPath update
    /// when `isOnline` hasn't actually changed value.
    private func observeNetwork() {
        NetworkMonitor.shared.$isOnline
            .removeDuplicates()
            .sink { [weak self] online in
                guard online else { return }
                Task { @MainActor [weak self] in
                    await self?.flushIfOnline()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence helpers

    /// Write current state to UserDefaults. Set is serialised as an
    /// Array because UserDefaults can't store Set directly.
    private func persistToDisk() {
        defaults.set(Array(pendingMemoIDs), forKey: userDefaultsKey)
        defaults.set(totalBytes, forKey: bytesKey)
        defaults.set(oldestPendingDate, forKey: oldestKey)
        // memoSizes serialised as [String: Int] — UserDefaults can store
        // Dictionary<String, Int> natively.
        defaults.set(memoSizes, forKey: sizesKey)
    }

    /// Pull persisted state on init. Missing keys leave the @Published
    /// properties at their default (empty / 0 / nil) values.
    private func restoreFromDisk() {
        if let arr = defaults.array(forKey: userDefaultsKey) as? [String] {
            pendingMemoIDs = Set(arr)
        }
        totalBytes = defaults.integer(forKey: bytesKey)
        oldestPendingDate = defaults.object(forKey: oldestKey) as? Date
        if let dict = defaults.dictionary(forKey: sizesKey) as? [String: Int] {
            memoSizes = dict
        }
        // R9 migration: do NOT pre-seed missing IDs with size=0 — that
        // used to mask the legacy-state case where pendingMemoIDs was
        // persisted but memoSizes never was. Instead, leave the dict
        // sparse so `markSynced` falls into `estimateMemoSize` and walks
        // vault/raw for the real byte count. The fallback runs at most
        // once per legacy-migrated memo; subsequent enqueues populate
        // the dict normally.
    }
}

// MARK: - Notification name

public extension Notification.Name {
    /// Posted by: SyncQueueService.flushIfOnline (R8) — when an upload pass should run.
    /// Observed by: SyncQueueObserver.start (.addObserver) — drives Supabase upload +
    /// markSynced callbacks via SyncQueueService.shared.pendingMemoIDs. Decouples this
    /// file from the concrete sync implementation.
    public static let syncQueueFlushRequested = Notification.Name("DayPage.syncQueue.flushRequested")
}
