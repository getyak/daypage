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

/// Why a sync pass was requested. Typed so UI/manual actions, network
/// recovery, periodic polling and session setup can never be conflated — and
/// so `initial`/`manual` demands can never be swallowed by a busy pass.
public enum SyncRefreshReason: String, Codable, Sendable, Equatable {
    /// First full sync after a session was installed: always full metadata.
    case initial
    /// Explicit user action (retry/refresh button): always full metadata.
    case manual
    /// Background periodic poll.
    case periodic
    /// Network recovery.
    case online
    /// Local enqueue / any other automatic trigger.
    case automatic

    /// initial/manual always force a complete metadata read.
    public var forcesFullMetadata: Bool { self == .initial || self == .manual }

    /// Strongest of two overlapping demands (manual/initial survive).
    public func coalesced(with other: SyncRefreshReason) -> SyncRefreshReason {
        Self.precedence.first { $0 == self || $0 == other } ?? .automatic
    }

    private static let precedence: [SyncRefreshReason] = [
        .initial, .manual, .online, .periodic, .automatic
    ]
}

/// Account-tag metadata health for the CURRENT session generation.
public enum SyncMetadataState: String, Codable, Sendable, Equatable {
    /// No metadata reader capability (legacy/unclaimed vault, or a puller
    /// without one). Never a complete empty catalogue.
    case unavailable
    /// Session active; not verified yet this generation.
    case pending
    /// Fetch in flight.
    case loading
    /// Complete, consistency-verified metadata for the current realm.
    case current
    /// Fetch failed / inconsistent / over budget; old cache preserved.
    case failed
}

/// Concise, testable presentation of TRUE sync completion (#884).
///
/// "已同步/Synced" is claimable ONLY when every condition holds for the
/// CURRENT session generation: memo feed drained, metadata current, durable
/// outbox empty, and every verified media obligation finished. Unknown or
/// errored media counts never show synced, and the proof is invalidated by
/// session clear/install or any new local work — an old `lastSuccessAt` is
/// history, not proof for a new session.
public struct SyncCompletionPresentation: Equatable, Sendable {
    public var sessionActive: Bool
    /// True completion was recorded for the CURRENT session generation and no
    /// new work has appeared since.
    public var generationCurrent: Bool
    public var isFlushing: Bool
    /// Memo change feed fully drained (`hasMore == false`).
    public var memoDrained: Bool
    public var metadata: SyncMetadataState
    /// Durable outbox operations still pending.
    public var pendingOutboxCount: Int
    /// Verified unfinished + blocked media obligations (0 when verified zero).
    public var mediaIncompleteCount: Int
    /// Media health could not be verified (sidecar unreadable/foreign).
    public var mediaUnknown: Bool

    public init(
        sessionActive: Bool = false,
        generationCurrent: Bool = false,
        isFlushing: Bool = false,
        memoDrained: Bool = false,
        metadata: SyncMetadataState = .pending,
        pendingOutboxCount: Int = 0,
        mediaIncompleteCount: Int = 0,
        mediaUnknown: Bool = true
    ) {
        self.sessionActive = sessionActive
        self.generationCurrent = generationCurrent
        self.isFlushing = isFlushing
        self.memoDrained = memoDrained
        self.metadata = metadata
        self.pendingOutboxCount = pendingOutboxCount
        self.mediaIncompleteCount = mediaIncompleteCount
        self.mediaUnknown = mediaUnknown
    }

    /// Freshly installed session: nothing proven yet.
    public static let unknown = SyncCompletionPresentation()

    /// The ONLY state in which product copy may claim full sync completion.
    public var isFullySynced: Bool {
        sessionActive
            && generationCurrent
            && !isFlushing
            && memoDrained
            && metadata == .current
            && pendingOutboxCount == 0
            && !mediaUnknown
            && mediaIncompleteCount == 0
    }
}

/// Small, content-free diagnostic state for the most recent cloud-sync runs.
/// This is metadata only and is persisted in UserDefaults, never in the Vault.
public struct SyncHealthSnapshot: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastFailureStage: String?
    public var lastFailureCode: String?
    public var lastHTTPStatus: Int?
    public var lastCorrelationID: String?
    public var pendingCountAtLastAttempt: Int
    public var consecutiveFailureCount: Int
    public var lastRemoteReportAt: Date?

    public init(
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        lastFailureStage: String? = nil,
        lastFailureCode: String? = nil,
        lastHTTPStatus: Int? = nil,
        lastCorrelationID: String? = nil,
        pendingCountAtLastAttempt: Int = 0,
        consecutiveFailureCount: Int = 0,
        lastRemoteReportAt: Date? = nil
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastFailureStage = lastFailureStage
        self.lastFailureCode = lastFailureCode
        self.lastHTTPStatus = lastHTTPStatus
        self.lastCorrelationID = lastCorrelationID
        self.pendingCountAtLastAttempt = pendingCountAtLastAttempt
        self.consecutiveFailureCount = consecutiveFailureCount
        self.lastRemoteReportAt = lastRemoteReportAt
    }
}

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

    /// Durable, privacy-safe state rendered by Settings diagnostics.
    @Published public private(set) var syncHealth = SyncHealthSnapshot()

    /// Testable truth for "已同步/Synced" presentation. Updated by
    /// `SyncQueueObserver` as sessions/memo drain/metadata/media change.
    @Published public private(set) var completion = SyncCompletionPresentation.unknown

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
    private let healthKey       = "syncQueue.health.v1"

    /// Allows tests to inject a private UserDefaults suite so they don't
    /// pollute the shared standard suite. Production callers use
    /// `SyncQueueService.shared`, which captures `.standard`.
    private let defaults: UserDefaults

    private var cancellables = Set<AnyCancellable>()

    private let usesVaultOutbox: Bool

    private init(defaults: UserDefaults = .standard, usesVaultOutbox: Bool = true) {
        self.defaults = defaults
        self.usesVaultOutbox = usesVaultOutbox
        restoreFromDisk()
        if usesVaultOutbox, FileManager.default.fileExists(atPath: SyncOutboxStore.outboxURL.path) {
            reloadFromOutbox()
        }
        observeNetwork()
    }

    /// Test-only constructor — lets `SyncQueueServiceTests` create a
    /// fresh instance bound to a throwaway `UserDefaults(suiteName:)` so
    /// state can't bleed across test cases. Not for production use.
    public static func makeForTesting(defaults: UserDefaults) -> SyncQueueService {
        SyncQueueService(defaults: defaults, usesVaultOutbox: false)
    }

    // MARK: - Public mutation API

    public func recordSyncAttempt(
        correlationID: UUID,
        pendingCount: Int,
        at date: Date = Date()
    ) {
        syncHealth.lastAttemptAt = date
        syncHealth.lastCorrelationID = correlationID.uuidString.lowercased()
        syncHealth.pendingCountAtLastAttempt = min(max(pendingCount, 0), 100_000)
        persistToDisk()
    }

    public func recordSyncSuccess(at date: Date = Date()) {
        syncHealth.lastSuccessAt = date
        syncHealth.consecutiveFailureCount = 0
        // Callers must only reach this on TRUE completion (current generation,
        // memo drained, metadata current, outbox 0, verified media 0).
        completion.generationCurrent = true
        completion.memoDrained = true
        persistToDisk()
    }

    // MARK: - Completion presentation updates (observer-driven)

    /// Applies one completion-state transition. Pure state plumbing; the
    /// observer computes the facts (see `SyncCompletionPresentation`).
    public func updateCompletion(
        _ mutate: (inout SyncCompletionPresentation) -> Void
    ) {
        mutate(&completion)
    }

    /// A new session generation was installed: the old completion proof is
    /// history and can never prove the new session.
    public func noteSessionInstalled() {
        pendingDemand = nil
        completion.sessionActive = true
        completion.generationCurrent = false
        completion.memoDrained = false
        completion.metadata = .pending
        completion.isFlushing = false
        completion.mediaUnknown = true
        completion.mediaIncompleteCount = 0
    }

    /// Session cleared / rejected: current completion proof invalidated.
    public func noteSessionCleared() {
        pendingDemand = nil
        completion = .unknown
    }

    /// New local work (enqueue/outbox growth) invalidates the current
    /// completion proof immediately — pending work is never "已同步".
    public func invalidateCompletionProof() {
        completion.generationCurrent = false
    }

    /// Records the latest failure and returns whether it should also become a
    /// remote Sentry event. Repeats of the same stage/code are reported at most
    /// once per throttle window; a success or changed failure starts a new burst.
    @discardableResult
    public func recordSyncFailure(
        stage: String,
        code: String,
        httpStatus: Int?,
        at date: Date = Date(),
        remoteThrottle: TimeInterval = 15 * 60
    ) -> Bool {
        let sameFailure = syncHealth.lastFailureStage == stage
            && syncHealth.lastFailureCode == code
            && syncHealth.consecutiveFailureCount > 0
        let reportWindowElapsed = syncHealth.lastRemoteReportAt.map {
            date.timeIntervalSince($0) >= max(0, remoteThrottle)
        } ?? true
        let shouldReport = !sameFailure || reportWindowElapsed

        syncHealth.lastFailureAt = date
        syncHealth.lastFailureStage = stage
        syncHealth.lastFailureCode = code
        syncHealth.lastHTTPStatus = httpStatus.map { min(max($0, 100), 599) }
        syncHealth.consecutiveFailureCount = sameFailure
            ? min(syncHealth.consecutiveFailureCount + 1, 10_000)
            : 1
        if shouldReport {
            syncHealth.lastRemoteReportAt = date
        }
        persistToDisk()
        return shouldReport
    }

    /// Add a memo to the queue. Idempotent: re-enqueuing the same ID is
    /// a no-op for the count + byte tally (Set semantics dedupe the ID;
    /// we early-return so the byte counter doesn't double-count).
    public func enqueue(memoID: String, sizeBytes: Int) {
        guard !pendingMemoIDs.contains(memoID) else { return }
        pendingMemoIDs.insert(memoID)
        let clamped = max(0, sizeBytes)
        memoSizes[memoID] = clamped
        totalBytes += clamped
        // New work invalidates any current completion proof right away.
        invalidateCompletionProof()
        // Only stamp the oldest-pending clock when transitioning from
        // empty → non-empty. Subsequent enqueues should not push the
        // “已等待 N 小时” counter back to zero.
        if oldestPendingDate == nil {
            oldestPendingDate = Date()
        }
        persistToDisk()
        Task { @MainActor [weak self] in
            await self?.flushIfOnline(reason: .automatic)
        }
    }

    /// Reload UI state from the durable Vault sidecar. UserDefaults remains a
    /// backwards-compatible display cache; it is no longer the source of
    /// truth for cloud acknowledgements.
    public func reloadFromOutbox() {
        guard usesVaultOutbox,
              let operations = try? SyncOutboxStore.pendingOperations() else { return }
        pendingMemoIDs = Set(operations.map { $0.memoID.uuidString })
        memoSizes = [:]
        for operation in operations {
            memoSizes[operation.memoID.uuidString] = max(0, operation.sizeBytes)
        }
        totalBytes = memoSizes.values.reduce(0, +)
        oldestPendingDate = operations.map(\.modifiedAt).min()
        // Durable work still outstanding can never keep a current completion
        // proof alive.
        if !operations.isEmpty {
            invalidateCompletionProof()
        }
        persistToDisk()
    }

    /// Full Vault reconciliation runs off the main actor so a large archive
    /// never delays app launch or first paint.
    public func reconcileVault() async {
        guard usesVaultOutbox else { return }
        do {
            try await Task.detached(priority: .utility) {
                try SyncOutboxStore.reconcileVault()
            }.value
            reloadFromOutbox()
            await flushIfOnline(reason: .automatic)
        } catch {
            SentryReporter.breadcrumb(
                category: "syncqueue",
                level: .warning,
                message: "outbox reconciliation failed: \(error)"
            )
        }
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

    /// Trigger a sync attempt when online and not already flushing. An empty
    /// outbound queue still needs to notify the observer because another
    /// device may have remote changes waiting to be pulled. We deliberately
    /// don't perform network work here; the notification keeps this service
    /// independent of the concrete Supabase adapters.
    ///
    /// Busy/offline `manual`/`initial` demands are COALESCED and never
    /// swallowed — they are replayed as ONE merged follow-up when the current
    /// pass ends. Routine triggers (periodic/online/automatic) are covered by
    /// the running or next pass and do not pile up duplicate passes.
    public func flushIfOnline(reason: SyncRefreshReason = .automatic) async {
        requestFlushIfOnline(reason: reason)
    }

    /// Synchronous host/UI entry: posts while the caller's current session
    /// is still installed. The observer captures that lease at delivery,
    /// before scheduling work that could outlive logout or replacement.
    public func requestFlushIfOnline(reason: SyncRefreshReason = .automatic) {
        let merged = pendingDemand.map { $0.coalesced(with: reason) } ?? reason
        guard NetworkMonitor.shared.isOnline, !isFlushingNow else {
            if merged.forcesFullMetadata {
                pendingDemand = merged
            }
            return
        }
        pendingDemand = nil
        NotificationCenter.default.post(
            name: .syncQueueFlushRequested,
            object: nil,
            userInfo: [Self.flushReasonUserInfoKey: merged.rawValue]
        )
    }

    /// The typed reason a flush notification carries.
    public static let flushReasonUserInfoKey = "reason"

    /// Reason recorded while a pass was busy/offline; consumed ONCE by the
    /// observer's end-of-pass follow-up scheduling (one merged run — never
    /// two concurrent or duplicated full fetches).
    private var pendingDemand: SyncRefreshReason?

    /// Internal: drains the coalesced busy/offline demand for the observer's
    /// single end-of-pass follow-up (merged with the observer's own slot).
    func takePendingDemand() -> SyncRefreshReason? {
        let demand = pendingDemand
        pendingDemand = nil
        return demand
    }

    func beginFlush() -> Bool {
        guard !isFlushingNow else { return false }
        isFlushingNow = true
        completion.isFlushing = true
        return true
    }

    func endFlush() {
        isFlushingNow = false
        completion.isFlushing = false
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
                    await self?.flushIfOnline(reason: .online)
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
        if let data = try? JSONEncoder().encode(syncHealth) {
            defaults.set(data, forKey: healthKey)
        }
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
        if let data = defaults.data(forKey: healthKey),
           let restored = try? JSONDecoder().decode(SyncHealthSnapshot.self, from: data) {
            syncHealth = restored
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
