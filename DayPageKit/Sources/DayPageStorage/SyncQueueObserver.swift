// SyncQueueObserver.swift — Round 6 (R6-HIGH: flush 占位 service)
//
// Listens for `.syncQueueFlushRequested` (local write, network recovery,
// foreground activation, periodic poll, or manual retry). It uploads the
// durable outbox first, acknowledges only exact RPC receipts, then pulls and
// applies the authenticated account's monotonic remote change pages.
//
// Why this lives in its own file:
//   - SyncQueueService deliberately doesn't import any networking layer,
//     so the flush trigger is a NotificationCenter post. Some component
//     has to observe that post and perform the work — that's us.
//   - `NoopRemoteUploader` is deliberately fail-closed. Before auth/session
//     configuration it can never drain the outbox or imply cloud durability.

import Foundation

/// Pluggable contract for uploading one durable outbox operation. The exact
/// operation ID must be echoed by the server before the observer removes it.
public protocol RemoteUploader: Sendable {
    func upload(operation: SyncOutboxOperation) async throws -> Int
}

/// Fail-closed fallback used before an authenticated Supabase session exists.
/// It must never remove an outbox operation or imply that data reached cloud.
public struct NoopRemoteUploader: RemoteUploader {
    public init() {}

    public func upload(operation: SyncOutboxOperation) async throws -> Int {
        throw MemoSyncError.notConfigured
    }
}

@MainActor
public final class SyncQueueObserver {
    public static let shared = SyncQueueObserver()
    /// Monotonic install-attempt coordination for the asynchronous session
    /// installers (iOS RootView / macOS MacCloudAuthService). Shared so every
    /// success/catch/UI/health/flush action is bound to one attempt token.
    public lazy var sessionInstaller = SyncSessionInstallCoordinator(observer: self)

    private var observer: NSObjectProtocol?
    private var isFlushing = false
    /// Coalesced follow-up demand while a pass is busy. `manual`/`initial`
    /// survive busy passes and page-bound yields; overlapping demands merge
    /// into ONE follow-up run (never concurrent full fetches).
    private var pendingReason: SyncRefreshReason?
    /// Fresh-install flag: the first metadata phase of a new session
    /// generation must always run the FULL read (cheap probes are only for
    /// later periodic/online passes). Bound to the generation — cleared on
    /// session clear/reinstall, kept across page-bound yields.
    private var pendingInitialMetadata = false
    private var puller: RemotePuller?
    private var realm: SyncRealmIdentity?
    private var periodicTask: Task<Void, Never>?
    private var rejectedConfiguration = false
    /// Generation lease of the currently installed uploader/puller session
    /// (or of a test/diagnostic uploader injection). Every durable effect
    /// commits through this lease; replacing or clearing the session
    /// invalidates it.
    private var lease: SyncSessionLease?
    private let syncQueue: SyncQueueService
    private let legacyIsConfigured: () -> Bool

    /// Injected by the app after it has a Supabase session. The unconfigured
    /// uploader always fails closed and therefore can never falsely drain data.
    private var uploader: RemoteUploader = NoopRemoteUploader()

    init(
        observeNotifications: Bool = true,
        syncQueue: SyncQueueService? = nil,
        legacyIsConfigured: @escaping () -> Bool = { SyncSettings.isConfigured }
    ) {
        self.syncQueue = syncQueue ?? .shared
        self.legacyIsConfigured = legacyIsConfigured
        guard observeNotifications else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .syncQueueFlushRequested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[SyncQueueService.flushReasonUserInfoKey] as? String)
                .flatMap(SyncRefreshReason.init(rawValue:)) ?? .automatic
            // Capture the installed generation at notification delivery,
            // before the asynchronous task can cross logout/replacement.
            MainActor.assumeIsolated {
                self?.scheduleFollowUpFlush(reason: reason)
            }
        }
    }

    /// Test/diagnostic uploader-only injection. NOT compiled into production
    /// builds, so it cannot become a bypass around realm/session isolation.
    #if DEBUG
    public func setUploader(_ uploader: RemoteUploader) {
        installBareUploader(uploader)
    }
    #endif

    /// Installs the complete push + pull session after binding the local Vault
    /// to the verified (origin, user) realm. A different account or backend
    /// origin fails closed, keeps every durable file untouched, and leaves the
    /// rejected configuration in place.
    public func configureSession(
        session: SyncSession,
        uploader: RemoteUploader,
        puller: RemotePuller,
        periodicInterval: TimeInterval = 30
    ) throws {
        do {
            try SyncAccountStateStore.bind(to: session.identity)
        } catch {
            session.lease.invalidate()
            clearSession(rejectedConfiguration: true)
            throw error
        }
        pendingReason = nil
        lease?.invalidate()
        rejectedConfiguration = false
        self.realm = session.identity
        self.lease = session.lease
        self.uploader = uploader
        self.puller = puller
        // A new generation starts with NO completion proof: an old
        // `lastSuccessAt` is history, never evidence for this session.
        syncQueue.noteSessionInstalled()
        pendingInitialMetadata = true
        if isFlushing {
            // A pass for the PREVIOUS generation is still busy: the fresh
            // generation's initial/full demand must survive that window and
            // reschedule immediately when the stale pass ends — even if the
            // host's onFlush reason is coarser and periodicInterval is 0.
            pendingReason = pendingReason.map { $0.coalesced(with: .initial) } ?? .initial
        }
        startPeriodicSync(interval: periodicInterval)
    }

    /// Explicit sign-out clears the rejection. A failed session setup keeps
    /// automatic/legacy sync blocked until a valid session is configured.
    /// Invalidating the lease linearizes against any in-flight commit: a
    /// commit that already entered the gate may finish (documented ordering),
    /// every later one is refused.
    public func clearSession(rejectedConfiguration: Bool = false) {
        pendingReason = nil
        lease?.invalidate()
        lease = nil
        self.rejectedConfiguration = rejectedConfiguration
        periodicTask?.cancel()
        periodicTask = nil
        realm = nil
        puller = nil
        uploader = NoopRemoteUploader()
        // Session gone → current completion proof is void.
        pendingInitialMetadata = false
        syncQueue.noteSessionCleared()
    }

    /// Whether the last configuration attempt was rejected. Hosts preserve
    /// this across transient nil-session events instead of reopening legacy
    /// upload.
    public var isConfigurationRejected: Bool { rejectedConfiguration }

    /// #785: pick the right uploader based on the user's sync configuration.
    /// Legacy API-key bridge retained for pristine, never-bound Vaults only:
    /// a bound, unknown, legacy-unverified or rejected Vault can never fall
    /// back to legacy upload (or report fake "synced" success).
    public func installConfiguredUploader() {
        guard realm == nil, !rejectedConfiguration else { return }
        guard legacyIsConfigured(), SyncAccountStateStore.isUnclaimedVault() else {
            installBareUploader(NoopRemoteUploader())
            return
        }
        installBareUploader(MemoSyncUploader())
    }

    private func installBareUploader(_ uploader: RemoteUploader) {
        pendingReason = nil
        _ = syncQueue.takePendingDemand()
        lease?.invalidate()
        lease = SyncSessionLease()
        realm = nil
        puller = nil
        self.uploader = uploader
    }

    /// A legacy uploader may only act — and only report empty-queue success —
    /// for a genuinely pristine, unclaimed Vault that is not rejected.
    private func legacyFallbackPermitted() -> Bool {
        realm == nil
            && !rejectedConfiguration
            && legacyIsConfigured()
            && SyncAccountStateStore.isUnclaimedVault()
    }

    /// Walk every pending ID once. We grab the snapshot up-front so a
    /// concurrent enqueue (e.g. user types a new memo mid-flush) doesn't
    /// mutate the set under our feet; the new memo will be picked up by
    /// the next flush trigger anyway.
    ///
    /// `reason` distinguishes session-initial / manual / periodic / online /
    /// automatic passes. While a pass is busy, further demands are coalesced
    /// and replayed as ONE follow-up run — a `manual`/`initial` full metadata
    /// request can never be swallowed by the busy early-return.
    public func flush(reason: SyncRefreshReason = .automatic) async {
        guard !rejectedConfiguration else { return }
        guard !isFlushing else {
            // Busy pass: `manual`/`initial` demands are COALESCED and replayed
            // once — they can never be swallowed. Routine triggers are covered
            // by the running pass (e.g. a page-bound continuation re-entering
            // while its successor already drains) and do not duplicate passes.
            if reason.forcesFullMetadata {
                pendingReason = pendingReason.map { $0.coalesced(with: reason) } ?? reason
            }
            return
        }
        isFlushing = true
        defer {
            isFlushing = false
            // ONE merged follow-up: the observer's own coalesced demand plus
            // any busy/offline demand the service recorded during this pass
            // (e.g. a replacement session's initial demand arriving while the
            // stale pass was still unwinding). Never duplicated passes.
            let serviceDemand = syncQueue.takePendingDemand()
            let pending = pendingReason
            pendingReason = nil
            let merged = pending.map { p in serviceDemand.map { p.coalesced(with: $0) } ?? p }
                ?? serviceDemand
            if let merged {
                scheduleFollowUpFlush(reason: merged)
            }
        }
        let lease = self.lease
        let uploader = self.uploader
        let puller = self.puller
        let realm = self.realm

        guard syncQueue.beginFlush() else { return }
        defer { syncQueue.endFlush() }

        // A pass starts by VOIDING the current completion proof: only the
        // verified completion gate below may re-establish it. A failed or
        // partially verified pass (e.g. the durable outbox read throwing)
        // therefore can never leave the previous generation's "已同步" proof
        // standing while its counts are unknown.
        syncQueue.invalidateCompletionProof()

        // A freshly installed generation always gets the full metadata read,
        // regardless of the trigger that fired first.
        let effectiveReason = pendingInitialMetadata
            ? reason.coalesced(with: .initial)
            : reason

        let correlationID = UUID()
        syncQueue.recordSyncAttempt(
            correlationID: correlationID,
            pendingCount: syncQueue.pendingCount
        )

        let operations: [SyncOutboxOperation]
        do {
            operations = try SyncOutboxStore.pendingOperations()
        } catch {
            recordFailure(stage: "outbox_read", error: error, correlationID: correlationID)
            return
        }

        uploadLoop: for operation in operations {
            do {
                _ = try await uploader.upload(operation: operation)
                guard isCurrentSession(lease) else { return }
                // Outbox ack is a durable effect: it commits inside the
                // generation gate so an old receipt can never drain intent
                // after the session changed.
                try withLease(lease) {
                    try SyncOutboxStore.acknowledge(operationID: operation.operationID)
                    if operation.kind == .delete, let realm {
                        try? AttachmentTransferStore.discardTransfers(
                            memoIDs: [operation.memoID],
                            realm: realm
                        )
                    }
                }
                syncQueue.reloadFromOutbox()
            } catch is AttachmentSyncError {
                guard isCurrentSession(lease) else { return }
                // Media has its own durable sidecar. Leave this memo pending,
                // continue unrelated text operations, and still pull remote
                // changes so a large or unsupported file cannot stall sync.
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "attachment deferred for \(operation.memoID)"
                )
                continue uploadLoop
            } catch let error as MemoSyncError {
                guard isCurrentSession(lease) else { return }
                recordFailure(stage: "push", error: error, correlationID: correlationID)
                if case .conflict = error {
                    // Keep the operation until pull preserves the local variant
                    // and installs the newer remote canonical revision.
                    break uploadLoop
                }
                return
            } catch {
                guard isCurrentSession(lease) else { return }
                // Network/server problem — stop this pass so we don't
                // burn through retries pointlessly. The next online
                // transition or manual trigger will resume.
                recordFailure(stage: "push", error: error, correlationID: correlationID)
                return
            }
        }

        guard let puller, let realm, let lease else {
            // Legacy empty-queue "success" is only truthful for a pristine,
            // unclaimed Vault with a real legacy uploader installed. A bound,
            // unknown or rejected Vault must never display fake success.
            if legacyFallbackPermitted(), !(uploader is NoopRemoteUploader) {
                syncQueue.recordSyncSuccess()
            }
            return
        }
        do {
            let completed = try await pullAllChanges(using: puller, realm: realm, lease: lease)
            guard isCurrentSession(lease) else { return }
            if completed {
                await finishDrainedPass(
                    reason: effectiveReason,
                    puller: puller,
                    realm: realm,
                    lease: lease,
                    correlationID: correlationID
                )
            } else {
                // Work is still pending across a page-boundary: reschedule
                // instead of truncating or falsely reporting synced. The
                // follow-up keeps this pass's reason so a manual/initial
                // full-metadata demand survives a budget yield.
                syncQueue.reloadFromOutbox()
                syncQueue.updateCompletion { $0.memoDrained = false }
                // Use the same end-of-pass slot as busy/manual demands,
                // so a page yield cannot enqueue a second drained pass.
                pendingReason = pendingReason.map { $0.coalesced(with: effectiveReason) } ?? effectiveReason
            }
        } catch {
            guard isCurrentSession(lease) else { return }
            syncQueue.updateCompletion { $0.memoDrained = false }
            recordFailure(stage: "pull", error: error, correlationID: correlationID)
        }
    }

    /// Post-drain completion gate (#884). TRUE completion requires ALL of:
    /// current generation lease, memo feed drained, account-tag metadata
    /// current, durable outbox empty and every verified media obligation
    /// finished. Anything unknown/failed/pending keeps the old cache and
    /// never claims synced.
    private func finishDrainedPass(
        reason: SyncRefreshReason,
        puller: RemotePuller,
        realm: SyncRealmIdentity,
        lease: SyncSessionLease,
        correlationID: UUID
    ) async {
        syncQueue.updateCompletion { $0.memoDrained = true }

        // Metadata phase runs only AFTER the memo feed drained.
        let metadataState = await refreshAccountMetadata(
            reason: reason,
            puller: puller,
            realm: realm,
            lease: lease,
            correlationID: correlationID
        )
        guard isCurrentSession(lease) else { return }

        // Durable outbox truth — never the in-memory hint alone.
        let pendingOperations: [SyncOutboxOperation]
        do {
            pendingOperations = try SyncOutboxStore.pendingOperations()
        } catch {
            recordFailure(stage: "outbox_read", error: error, correlationID: correlationID)
            syncQueue.updateCompletion {
                $0.metadata = metadataState
                $0.mediaUnknown = true
            }
            syncQueue.invalidateCompletionProof()
            return
        }

        // Verified media obligations. Errors are UNKNOWN, never zero.
        let media: AttachmentTransferStore.TransferProgress
        do {
            media = try AttachmentTransferStore.progress(realm: realm)
        } catch {
            recordFailure(stage: "media_progress", error: error, correlationID: correlationID)
            syncQueue.updateCompletion {
                $0.metadata = metadataState
                $0.pendingOutboxCount = pendingOperations.count
                $0.mediaUnknown = true
                $0.mediaIncompleteCount = 0
            }
            syncQueue.invalidateCompletionProof()
            return
        }

        let fullyComplete = pendingOperations.isEmpty
            && metadataState == .current
            && !media.hasIncomplete
        syncQueue.updateCompletion {
            $0.metadata = metadataState
            $0.pendingOutboxCount = pendingOperations.count
            $0.mediaUnknown = false
            $0.mediaIncompleteCount = media.unfinishedTotal
        }
        if fullyComplete {
            syncQueue.recordSyncSuccess()
        } else {
            // Incomplete work voids any previous proof for this generation.
            syncQueue.invalidateCompletionProof()
        }
    }

    /// Account-tag metadata phase: complete consistency-verified projection
    /// for the current realm, or typed unavailable/failed. Failures preserve
    /// raw/cursor progress AND the previous cache bytes — no rollback and no
    /// replayed operation IDs.
    private func refreshAccountMetadata(
        reason: SyncRefreshReason,
        puller: RemotePuller,
        realm: SyncRealmIdentity,
        lease: SyncSessionLease,
        correlationID: UUID
    ) async -> SyncMetadataState {
        guard let reader = puller.accountTagsReader else {
            // Capability absent = metadata unavailable — never an empty
            // "complete" catalogue.
            return .unavailable
        }
        // The initial full-read demand is consumed once the metadata phase
        // actually runs under the current generation.
        pendingInitialMetadata = false
        syncQueue.updateCompletion { $0.metadata = .loading }

        let cached = try? AccountTagProjectionStore.read(
            realm: realm,
            vaultRoot: VaultInitializer.vaultURL
        )
        var needsFullFetch = reason.forcesFullMetadata || cached == nil
        if !needsFullFetch, let cached {
            // periodic/online/automatic: cheap count + marker probe reuses a
            // valid matched-realm complete cache when nothing changed.
            do {
                if try await AccountTagProjectionRefresh.isCacheFresh(
                    reader: reader,
                    cached: cached
                ) {
                    return .current
                }
                needsFullFetch = true
            } catch {
                guard isCurrentSession(lease) else { return .failed }
                // A failed probe is never "fresh" and never full success.
                recordFailure(stage: "metadata_probe", error: error, correlationID: correlationID)
                return .failed
            }
        }
        guard needsFullFetch else { return .current }

        do {
            let snapshot = try await AccountTagProjectionRefresh.fetch(
                reader: reader,
                realm: realm
            )
            guard isCurrentSession(lease) else {
                // Stale generation: clean up nothing foreign — the old task
                // may only discard its own in-memory work.
                return .failed
            }
            try AccountTagProjectionStore.install(
                snapshot,
                realm: realm,
                lease: lease,
                vaultRoot: VaultInitializer.vaultURL
            )
            return .current
        } catch {
            guard isCurrentSession(lease) else { return .failed }
            recordFailure(stage: "metadata", error: error, correlationID: correlationID)
            return .failed
        }
    }

    /// True while `lease` is still the installed session generation AND that
    /// lease has not been invalidated. A pass without any session may still
    /// record its own diagnostics, but never once a newer session exists.
    private func isCurrentSession(_ lease: SyncSessionLease?) -> Bool {
        if let lease {
            return !rejectedConfiguration && lease === self.lease && lease.isValid
        }
        return self.lease == nil && !rejectedConfiguration
    }

    /// Synchronous check + effect gate for durable commits.
    private func withLease<T>(
        _ lease: SyncSessionLease?,
        _ body: () throws -> T
    ) throws -> T {
        guard let lease else { throw SyncRealmError.sessionInvalidated }
        return try lease.withValidity(body)
    }

    private func recordFailure(stage: String, error: Error, correlationID: UUID) {
        let diagnostic: (code: String, httpStatus: Int?)
        if let syncError = error as? MemoSyncError {
            diagnostic = (syncError.diagnosticCode, syncError.diagnosticHTTPStatus)
        } else if let fetchError = error as? AccountTagFetchError {
            diagnostic = ("tags_\(fetchError)", nil)
        } else if let cacheError = error as? AccountTagCacheError {
            diagnostic = ("tags_\(cacheError)", nil)
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                diagnostic = ("network_unavailable", nil)
            case .timedOut:
                diagnostic = ("network_timeout", nil)
            default:
                diagnostic = ("network_error", nil)
            }
        } else {
            diagnostic = ("unexpected", nil)
        }

        let queue = syncQueue
        let networkState: OperationalEvent.NetworkState = NetworkMonitor.shared.isOnline ? .online : .offline
        let boundedEvent = OperationalEvent(
            area: "sync",
            stage: stage,
            code: diagnostic.code,
            correlationID: correlationID,
            level: diagnostic.code == "unexpected" ? .error : .warning,
            httpStatus: diagnostic.httpStatus,
            networkState: networkState,
            pendingCount: queue.pendingCount
        )
        let shouldReport = queue.recordSyncFailure(
            stage: boundedEvent.stage,
            code: boundedEvent.code,
            httpStatus: boundedEvent.httpStatus
        )
        let safeMessage = "stage=\(boundedEvent.stage) code=\(boundedEvent.code) correlation=\(boundedEvent.correlationID)"
        DayPageLogger.shared.warn("[Sync] \(safeMessage)")
        SentryReporter.breadcrumb(
            category: "syncqueue",
            level: .warning,
            message: safeMessage
        )
        guard shouldReport else { return }
        SentryReporter.captureOperationalEvent(OperationalEvent(
            area: "sync",
            stage: boundedEvent.stage,
            code: boundedEvent.code,
            correlationID: correlationID,
            level: boundedEvent.level,
            httpStatus: boundedEvent.httpStatus,
            networkState: boundedEvent.networkState,
            pendingCount: queue.pendingCount,
            consecutiveFailureCount: queue.syncHealth.consecutiveFailureCount
        ))
    }

    /// Pages drained per flush pass. This is a scheduling valve, NOT a data
    /// limit: accounts with thousands of notes legitimately span 25+ pages,
    /// and a pass that reaches the bound with `hasMore` still set ends
    /// without reporting synced and reschedules — it never truncates the
    /// drain and never lifts the advancing/malformed-page guards.
    static var maximumPagesPerFlushPass = 250

    private func scheduleFollowUpFlush(reason: SyncRefreshReason) {
        guard let scheduledLease = lease, scheduledLease.isValid else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentSession(scheduledLease) else { return }
            await self.flush(reason: reason)
        }
    }

    /// Returns `true` when the remote change stream is fully drained
    /// (`hasMore == false`); `false` when the per-pass page bound was reached
    /// with work still pending.
    private func pullAllChanges(
        using puller: RemotePuller,
        realm: SyncRealmIdentity,
        lease: SyncSessionLease
    ) async throws -> Bool {
        var pages = 0
        while true {
            guard isCurrentSession(lease) else { throw CancellationError() }
            let cursor = try SyncAccountStateStore.pullCursor(for: realm)
            let page = try await puller.pull(after: cursor, limit: 200)
            guard isCurrentSession(lease) else { throw CancellationError() }
            guard page.isValid(after: cursor) else {
                throw MemoSyncError.invalidResponse
            }
            if !page.changes.isEmpty {
                // Raw apply is a durable commit: `applyRemoteChanges` runs the
                // whole raw write inside the same generation gate.
                _ = try await Task.detached(priority: .utility) {
                    try RawStorage.applyRemoteChanges(page.changes, sessionLease: lease)
                }.value
                guard isCurrentSession(lease) else { throw CancellationError() }
                try lease.withValidity {
                    try SyncAccountStateStore.advancePullCursor(
                        to: page.nextCursor,
                        for: realm
                    )
                }
                syncQueue.reloadFromOutbox()
            }
            if !page.hasMore { return true }
            guard !page.changes.isEmpty else { throw MemoSyncError.invalidResponse }
            pages += 1
            if pages >= Self.maximumPagesPerFlushPass {
                return false
            }
        }
    }

    private func startPeriodicSync(interval: TimeInterval) {
        periodicTask?.cancel()
        guard interval > 0 else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled, NetworkMonitor.shared.isOnline else { continue }
                await self?.flush(reason: .periodic)
            }
        }
    }

    deinit {
        periodicTask?.cancel()
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Async install attempt coordination

/// Monotonic attempt tokens for asynchronous session installation.
///
/// Every installer success/catch/UI/health/flush action is bound to one
/// token; a newer install, logout, nil-session event or explicit rejection
/// invalidates all older tokens. Stale attempts therefore cause ZERO current
/// context/UI/health mutations. Task cancellation is supplementary — the
/// token check is the authoritative gate because suspension inside a proof
/// can outlive any cancellation request.
@MainActor
public final class SyncInstallAttemptGate {
    private var current: UInt = 0

    public init() {}

    /// Starts a new attempt, invalidating every earlier one.
    public func begin() -> UInt {
        current &+= 1
        return current
    }

    public func isCurrent(_ token: UInt) -> Bool {
        token == current
    }

    /// Invalidates every outstanding attempt (logout, nil session, rejection).
    public func invalidateAll() {
        current &+= 1
    }
}

/// Coordinates the asynchronous session installation shared by the iOS and
/// macOS hosts.
///
/// Ordering contract: hosts MUST `reserve()` synchronously on the auth event
/// BEFORE scheduling any async work. The reservation begins the monotonic
/// attempt generation AND invalidates the previous session lease at that same
/// synchronous boundary, so an older proof continuation that resumes before
/// the newer attempt's async installer even starts is already stale and can
/// bind nothing, clear nothing and write no UI/health state. Completion also
/// re-validates the CURRENT auth snapshot (not just proven-vs-expected UUID),
/// which closes delayed SwiftUI `onChange` gaps and same-UUID refresh/
/// duplicate events via the reservation ordering.
@MainActor
public final class SyncSessionInstallCoordinator {
    /// An immutable, synchronously reserved install attempt.
    public struct Reservation: Sendable {
        public let token: UInt
        public let expectedUserID: UUID?
    }

    private let observer: SyncQueueObserver
    private let gate: SyncInstallAttemptGate

    public init(
        observer: SyncQueueObserver,
        gate: SyncInstallAttemptGate? = nil
    ) {
        self.observer = observer
        self.gate = gate ?? SyncInstallAttemptGate()
    }

    /// Invalidates every outstanding attempt at the synchronous host boundary
    /// (logout, nil session, invalid configuration).
    public func invalidateAllAttempts() {
        gate.invalidateAll()
    }

    /// Called synchronously before publishing a changed SDK auth snapshot.
    /// Token refresh can keep the same UUID, so a later SwiftUI UUID observer
    /// is insufficient to invalidate an in-flight proof for the old token.
    /// Exact duplicate snapshots need no new generation.
    public func authSessionWillChange(
        previousUserID: UUID?, previousAccessToken: String?,
        userID: UUID?, accessToken: String?
    ) {
        guard previousUserID != userID || previousAccessToken != accessToken else { return }
        gate.invalidateAll()
        observer.clearSession(
            rejectedConfiguration: userID != nil || observer.isConfigurationRejected
        )
    }

    /// Synchronous reservation boundary. Call this on the synchronous auth
    /// event, BEFORE `Task` scheduling: it begins the new attempt generation
    /// and invalidates the previous session context up front (non-nil A→B
    /// included) so no durable effect can commit under the old lease while
    /// the new session is being proven.
    public func reserve(expectedUserID: UUID?) -> Reservation {
        let token = gate.begin()
        observer.clearSession(rejectedConfiguration: true)
        return Reservation(token: token, expectedUserID: expectedUserID)
    }

    /// Completes a previously reserved attempt. Returns true only when this
    /// reservation is still current AND the live auth snapshot still matches
    /// at completion. Stale attempts perform no observer, UI, health or flush
    /// mutations at all.
    @discardableResult
    public func install(
        reservation: Reservation,
        currentUserID: @MainActor @escaping () -> UUID?,
        prove: @MainActor @escaping () async throws -> SyncSession,
        makeUploader: @escaping (SyncSession) -> RemoteUploader,
        makePuller: @escaping (SyncSession) -> RemotePuller,
        periodicInterval: TimeInterval = 30,
        onSuccess: @MainActor @escaping (SyncSession) -> Void = { _ in },
        onFailure: @MainActor @escaping (Error) -> Void = { _ in },
        onFlush: @MainActor @escaping () -> Void = {}
    ) async -> Bool {
        do {
            let session = try await prove()
            // No suspension between the currency check and the synchronous
            // configuration commit: a newer reservation can not interleave.
            guard isCurrent(reservation, currentUserID: currentUserID),
                  session.identity.userID == currentUserID() else {
                return false
            }
            if let expectedUserID = reservation.expectedUserID,
               expectedUserID != session.identity.userID {
                throw SyncRealmError.serverUserMismatch
            }
            try observer.configureSession(
                session: session,
                uploader: makeUploader(session),
                puller: makePuller(session),
                periodicInterval: periodicInterval
            )
            guard isCurrent(reservation, currentUserID: currentUserID) else { return false }
            onSuccess(session)
        } catch {
            // A stale failure must never clear a newer session, latch a
            // rejection or write UI/health state.
            guard isCurrent(reservation, currentUserID: currentUserID) else { return false }
            observer.clearSession(rejectedConfiguration: true)
            gate.invalidateAll()
            onFailure(error)
            return false
        }
        onFlush()
        return true
    }

    private func isCurrent(
        _ reservation: Reservation,
        currentUserID: @MainActor () -> UUID?
    ) -> Bool {
        guard gate.isCurrent(reservation.token) else { return false }
        // The live auth snapshot is authoritative: a logged-out or changed
        // host invalidates the attempt even before any newer reservation.
        guard let current = currentUserID() else { return false }
        if let expectedUserID = reservation.expectedUserID, current != expectedUserID {
            return false
        }
        return true
    }
}
