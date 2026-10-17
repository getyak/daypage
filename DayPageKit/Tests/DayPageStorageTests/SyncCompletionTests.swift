// SyncCompletionTests.swift — #884 truthful sync completion acceptance
// (T07/T11/T14/T15/T17).
//
// "Synced" is claimable only for the CURRENT session generation with the memo
// feed drained, account-tag metadata current, a durable-empty outbox and zero
// verified media obligations. All fixtures are synthetic under
// DAYPAGE_TEST_VAULT_ROOT; no real vault/network/credentials are touched.

import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

@MainActor
final class SyncCompletionTests: XCTestCase {
    private var vault: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var service: SyncQueueService!
    private var realm: SyncRealmIdentity!

    override func setUpWithError() throws {
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-sync-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw"),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vault
        suite = "SyncCompletionTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        service = SyncQueueService.makeForTesting(defaults: defaults)
        realm = try SyncRealmTestSupport.realm()
        try SyncAccountStateStore.bind(to: realm)
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: vault)
        service = nil
        defaults = nil
    }

    // MARK: - Helpers

    private func makeObserver() -> SyncQueueObserver {
        SyncQueueObserver(
            observeNotifications: false,
            syncQueue: service,
            legacyIsConfigured: { false }
        )
    }

    private func makeSession() throws -> SyncSession {
        try SyncRealmTestSupport.session(realm: realm)
    }

    private func configure(
        _ observer: SyncQueueObserver,
        puller: RemotePuller,
        uploader: RemoteUploader = CompletionTestUploader()
    ) throws {
        try observer.configureSession(
            session: makeSession(),
            uploader: uploader,
            puller: puller,
            periodicInterval: 0
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: - T15 full success (positive + negatives)

    func testFullSuccessRequiresEveryConditionForCurrentGeneration() async throws {
        let observer = makeObserver()
        try configure(observer, puller: CompletionTestPuller(reader: EmptyCompleteTagsReader()))
        await observer.flush(reason: .manual)

        XCTAssertTrue(service.completion.isFullySynced)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        XCTAssertEqual(service.completion.metadata, .current)
        XCTAssertEqual(service.completion.pendingOutboxCount, 0)
        XCTAssertFalse(service.completion.mediaUnknown)
        XCTAssertEqual(service.completion.mediaIncompleteCount, 0)
        observer.clearSession()
    }

    func testMetadataUnavailableNeverClaimsSynced() async throws {
        let observer = makeObserver()
        // No `accountTagsReader` capability: metadata unavailable, NEVER a
        // complete empty catalogue.
        try configure(observer, puller: CompletionTestPuller(reader: nil))
        await observer.flush(reason: .manual)

        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertEqual(service.completion.metadata, .unavailable)
        XCTAssertNil(service.syncHealth.lastSuccessAt)
        observer.clearSession()
    }

    func testMetadataFailureNeverClaimsSyncedAndRetriesNextPass() async throws {
        let reader = EmptyCompleteTagsReader()
        reader.failAll = AccountTagFetchError.countChanged
        let observer = makeObserver()
        try configure(observer, puller: CompletionTestPuller(reader: reader))
        await observer.flush(reason: .manual)

        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertEqual(service.completion.metadata, .failed)
        XCTAssertNil(service.syncHealth.lastSuccessAt)

        // The next pass retries metadata even with zero memo changes.
        reader.failAll = nil
        await observer.flush(reason: .periodic)
        XCTAssertEqual(service.completion.metadata, .current)
        XCTAssertTrue(service.completion.isFullySynced)
        observer.clearSession()
    }

    func testPendingOutboxNeverClaimsSynced() async throws {
        let memo = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "pending synthetic")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
        let observer = makeObserver()
        // Attachment-deferred uploader leaves the memo pending.
        try configure(
            observer,
            puller: CompletionTestPuller(reader: EmptyCompleteTagsReader()),
            uploader: CompletionTestUploader(failsWith: AttachmentSyncError.network)
        )
        await observer.flush(reason: .manual)

        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertEqual(service.completion.pendingOutboxCount, 1)
        XCTAssertNil(service.syncHealth.lastSuccessAt)
        observer.clearSession()
    }

    /// Media obligations (failed/paused/blocked) or unverifiable media state
    /// can never be reported as synced (T14 gating).
    func testMediaObligationsAndUnknownStateNeverClaimSynced() async throws {
        // 1 failed download + 1 paused upload + 1 blocked obligation.
        try writeSidecar(
            """
            {"schema_version":1,"realm_origin":"\(realm.normalizedOrigin)","realm_user_id":"\(realm.userID.uuidString.lowercased())","records":[\(recordJSON(id: "download:1", direction: "download", status: "failed", realm: realm)),\(recordJSON(id: "upload:1", direction: "upload", status: "paused", realm: realm))],"blocked_records":[{"operation_id":"\(UUID().uuidString.lowercased())","memo_id":"\(UUID().uuidString.lowercased())","local_path":"raw/assets/blocked.png","status":"failed","error_code":"local_validation","updated_at":"2026-10-01T00:00:00Z"}]}
            """
        )
        let observer = makeObserver()
        try configure(observer, puller: CompletionTestPuller(reader: EmptyCompleteTagsReader()))
        await observer.flush(reason: .manual)

        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertFalse(service.completion.mediaUnknown)
        XCTAssertEqual(service.completion.mediaIncompleteCount, 3)
        XCTAssertNil(service.syncHealth.lastSuccessAt)

        // Unknown (corrupt sidecar) is UNKNOWN — never zero.
        try Data("{corrupt".utf8).write(to: sidecarURL)
        await observer.flush(reason: .manual)
        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertTrue(service.completion.mediaUnknown)
        observer.clearSession()
    }

    /// An old `lastSuccessAt` is HISTORY: session clear/install or new local
    /// work voids the current completion proof.
    func testCompletionProofIsInvalidatedBySessionAndNewWork() async throws {
        let observer = makeObserver()
        try configure(observer, puller: CompletionTestPuller(reader: EmptyCompleteTagsReader()))
        await observer.flush(reason: .manual)
        XCTAssertTrue(service.completion.isFullySynced)
        let historicalSuccess = service.syncHealth.lastSuccessAt
        XCTAssertNotNil(historicalSuccess)

        // New local work voids the proof immediately.
        service.enqueue(memoID: UUID().uuidString, sizeBytes: 10)
        XCTAssertFalse(service.completion.isFullySynced)

        // Session clear keeps history but never proves a new session.
        observer.clearSession()
        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)

        // A fresh install starts with NO proof even though history remains.
        try configure(observer, puller: CompletionTestPuller(reader: EmptyCompleteTagsReader()))
        XCTAssertFalse(service.completion.isFullySynced)
        observer.clearSession()
    }

    // MARK: - T07 trigger coalescing

    /// A manual demand during an in-flight periodic pass is never swallowed:
    /// it coalesces into ONE follow-up pass that forces the FULL metadata read.
    func testManualDuringBusyPassCoalescesAndForcesFullMetadata() async throws {
        let reader = EmptyCompleteTagsReader()
        let puller = SuspendedCompletionPuller(reader: reader)
        let observer = makeObserver()
        try configure(observer, puller: puller)

        let pass = Task { await observer.flush(reason: .periodic) }
        await puller.waitUntilStarted()

        // Manual + repeated demands during the busy pass.
        await observer.flush(reason: .manual)
        await observer.flush(reason: .manual)
        await observer.flush(reason: .periodic)

        await puller.finish()
        await pass.value

        // The coalesced follow-up runs exactly ONE extra pass, and it forces
        // the FULL metadata read (a stale-cache cheap probe would not fetch
        // the catalogue again).
        try await waitUntil { reader.catalogueCalls >= 2 && !service.isFlushingNow }
        XCTAssertEqual(
            reader.catalogueCalls, 2,
            "manual demand must force exactly one more FULL fetch, never be swallowed"
        )
        let pulls = await puller.calls
        XCTAssertEqual(pulls, 2, "merged demands coalesce into one follow-up pass")
        XCTAssertTrue(service.completion.isFullySynced)
        observer.clearSession()
    }

    // MARK: - T11 failure preserves durable progress

    /// Metadata failure after a multi-page raw drain preserves raw + cursor,
    /// keeps acked operation IDs acknowledged (no rollback/replay), keeps the
    /// previous cache bytes and does NOT record success — and the next empty
    /// memo page still retries metadata.
    func testMetadataFailurePreservesRawCursorOutboxAndOldCache() async throws {
        // Established old cache.
        let oldSnapshot = AccountTagProjectionSnapshot(
            normalizedOrigin: realm.normalizedOrigin,
            ownerUUID: realm.userID,
            receiptCount: 1,
            catalogue: [AccountTagCatalogueRow(label: ExactTagLabel("#old")!, inImportCatalog: true)],
            links: [AccountTagLinkRow(memoID: UUID(), label: ExactTagLabel("#old")!)],
            sourceMarkers: [
                AccountTagImportMarker(
                    sourceSHA256: String(repeating: "a", count: 64),
                    payloadHash: String(repeating: "a", count: 64),
                    version: 1
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        try AccountTagProjectionStore.install(oldSnapshot, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        let cacheBefore = try Data(
            contentsOf: AccountTagProjectionStore.cacheFileURL(vaultRoot: vault)
        )

        let memo = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "op synthetic")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
        let operation = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)
        let originalOperationID = operation.operationID

        let reader = EmptyCompleteTagsReader()
        reader.failAll = AccountTagFetchError.countChanged
        let puller = SequencedCompletionPuller(pages: 3, perPage: 2, reader: reader)
        let uploader = CompletionTestUploader()
        let observer = makeObserver()
        try configure(observer, puller: puller, uploader: uploader)

        await observer.flush(reason: .manual)

        // Raw pages applied and cursor durable…
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: realm), 6)
        // …the pushed operation stayed acknowledged (no rollback/replay)…
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
        XCTAssertEqual(service.completion.pendingOutboxCount, 0)
        // …old cache bytes untouched, and no fake completion.
        XCTAssertEqual(
            try Data(contentsOf: AccountTagProjectionStore.cacheFileURL(vaultRoot: vault)),
            cacheBefore
        )
        XCTAssertNil(service.syncHealth.lastSuccessAt)
        XCTAssertFalse(service.completion.isFullySynced)
        XCTAssertEqual(service.completion.metadata, .failed)

        // The next pass sees empty memo pages but STILL retries metadata.
        reader.failAll = nil
        await observer.flush(reason: .periodic)
        XCTAssertEqual(service.completion.metadata, .current)
        XCTAssertTrue(service.completion.isFullySynced)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: realm), 6)
        // The acknowledged operation was never replayed or re-issued.
        let uploads = await uploader.count
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(operation.operationID, originalOperationID)
        observer.clearSession()
    }

    // MARK: - Health-review regressions (NTH-01 / NTH-02)

    /// NTH-01: a failed durable-outbox read on a LATER pass voids the current
    /// generation's completion proof — unknown counts must never leave the
    /// previous proof standing while `endFlush` restores the presentation.
    /// `lastSuccessAt` stays history.
    func testFailedOutboxReadNeverRevivesPreviousGenerationProof() async throws {
        let observer = makeObserver()
        try configure(observer, puller: CompletionTestPuller(reader: EmptyCompleteTagsReader()))
        await observer.flush(reason: .manual)
        XCTAssertTrue(service.completion.isFullySynced)
        let historical = service.syncHealth.lastSuccessAt
        XCTAssertNotNil(historical)

        // Corrupt the durable outbox: the next pass's first read throws.
        let outbox = SyncOutboxStore.outboxURL
        try FileManager.default.createDirectory(
            at: outbox.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{corrupt".utf8).write(to: outbox)

        await observer.flush(reason: .periodic)
        XCTAssertFalse(
            service.completion.isFullySynced,
            "unknown durable-outbox truth must never show Synced"
        )
        XCTAssertEqual(
            service.syncHealth.lastSuccessAt, historical,
            "the old timestamp stays history, never current proof"
        )

        // Recovery: with the outbox readable again, a verified pass re-proves.
        try FileManager.default.removeItem(at: outbox)
        await observer.flush(reason: .periodic)
        XCTAssertTrue(service.completion.isFullySynced)
        observer.clearSession()
    }

    /// NTH-02: a replacement generation's INITIAL demand survives a busy
    /// stale pass and runs immediately after it unwinds — even with a coarse
    /// host reason and periodicInterval == 0 — through the real installer
    /// path, with no stale-generation publication.
    func testReplacementSessionInitialDemandSurvivesBusyStalePass() async throws {
        let pullerA = SuspendedCompletionPuller(reader: EmptyCompleteTagsReader())
        let observer = makeObserver()
        try configure(observer, puller: pullerA)

        // Pass A (old generation) starts and suspends inside its pull.
        let passA = Task { await observer.flush(reason: .automatic) }
        await pullerA.waitUntilStarted()

        // Same-realm token refresh installs generation B through the real
        // session installer while A is still busy.
        let readerB = EmptyCompleteTagsReader()
        let pullerB = CompletionTestPuller(reader: readerB)
        let boundUser = try XCTUnwrap(realm.userID as UUID?)
        var currentUser: UUID? = boundUser
        let reservation = observer.sessionInstaller.reserve(expectedUserID: boundUser)
        let installed = await observer.sessionInstaller.install(
            reservation: reservation,
            currentUserID: { currentUser },
            prove: { try self.makeSession() },
            makeUploader: { _ in CompletionTestUploader() },
            makePuller: { _ in pullerB },
            periodicInterval: 0,
            onFlush: {
                // Coarse host reason (like the readonly RootView default)
                // plus the explicit initial demand from the install.
                Task { await self.service.flushIfOnline(reason: .initial) }
            }
        )
        XCTAssertTrue(installed)

        // Stale A unwinds late: it must publish nothing.
        await pullerA.finish()
        await passA.value

        // The initial demand survives the busy window and reschedules
        // immediately (no 30s periodic wait): B runs a full metadata read.
        try await waitUntil { readerB.catalogueCalls >= 1 && !service.isFlushingNow }
        XCTAssertGreaterThanOrEqual(readerB.catalogueCalls, 1)
        let pullsB = await pullerB.calls
        XCTAssertGreaterThanOrEqual(pullsB, 1)
        XCTAssertEqual(service.completion.metadata, .current)
        XCTAssertTrue(service.completion.isFullySynced)
        XCTAssertEqual(service.syncHealth.consecutiveFailureCount, 0)
        observer.clearSession()
    }

    // MARK: - T17 stable owning-day + UUID routing

    /// Detail routing is `(memoID, owning dayString)`: the raw file's day is
    /// authoritative, never a recomputation from `created`/timezone. Deleted
    /// memos become unavailable instead of resurrecting.
    func testDetailLookupUsesOwningDayAndUUIDNotCreatedTimezone() async throws {
        let store = MemoRecordStore()
        let memoID = UUID()
        let body = "full original body — selectable & copyable\n\nsecond line with #body-only"
        let memo = Memo(
            id: memoID,
            type: .text,
            created: Date(timeIntervalSince1970: 1_767_222_000), // 2025-12-31T23:00:00Z
            body: body
        )
        // The owning raw file is 2026-01-01 although `created` maps to
        // 2025-12-31 in several timezones.
        let dayFile = vault.appendingPathComponent("raw/2026-01-01.md")
        try RawStorage.serialize([memo]).write(to: dayFile, atomically: true, encoding: .utf8)

        let found = try await store.memo(id: memoID, dayString: "2026-01-01", vaultRoot: vault)
        XCTAssertEqual(found.id, memoID)
        // Full body round-trips byte-exact (no silent trimming of storage).
        XCTAssertEqual(found.body, body)

        // The created-derived day is NOT a valid route.
        do {
            _ = try await store.memo(id: memoID, dayString: "2025-12-31", vaultRoot: vault)
            XCTFail("route must follow the owning raw file, not created")
        } catch let error as MemoRecordStoreError {
            XCTAssertEqual(error, .notFound(memoID))
        }

        // External deletion → detail becomes unavailable, never resurrected.
        try await store.delete(id: memoID, dayString: "2026-01-01", vaultRoot: vault)
        do {
            _ = try await store.memo(id: memoID, dayString: "2026-01-01", vaultRoot: vault)
            XCTFail("deleted memo must be unavailable")
        } catch let error as MemoRecordStoreError {
            XCTAssertEqual(error, .notFound(memoID))
        }
    }

    // MARK: - Sidecar fixtures

    private var sidecarURL: URL {
        AttachmentTransferStore.stateURL
    }

    private func writeSidecar(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: sidecarURL)
    }

    private func recordJSON(
        id: String,
        direction: String,
        status: String,
        realm: SyncRealmIdentity
    ) -> String {
        let memoID = UUID().uuidString.lowercased()
        let sha = String(repeating: "c", count: 64)
        return """
        {"id":"\(id)","memo_id":"\(memoID)","local_path":"raw/assets/sync/\(sha)-sample.png","descriptor":{"position":0,"kind":"photo","content_sha256":"\(sha)","size_bytes":8,"mime_type":"image/png","object_key":"\(realm.userID.uuidString.lowercased())/\(memoID)/\(sha).png","original_filename":"sample.png","duration_ms":null,"transcript":null,"transcription_status":null},"direction":"\(direction)","status":"\(status)","resumable_url":null,"upload_offset":0,"last_error":"synthetic","updated_at":"2026-10-01T00:00:00Z"}
        """
    }
}

// MARK: - Fakes

private final class EmptyCompleteTagsReader: RemoteAccountTagsReader, @unchecked Sendable {
    private let lock = NSLock()
    private var _catalogueCalls = 0
    var failAll: AccountTagFetchError?

    var catalogueCalls: Int {
        lock.lock(); defer { lock.unlock() }; return _catalogueCalls
    }

    func exactReceiptCount() async throws -> Int {
        if let failAll { throw failAll }
        return 0
    }

    func importMarkers() async throws -> [AccountTagImportMarker] {
        if let failAll { throw failAll }
        return []
    }

    func catalogueRows() async throws -> [AccountTagCatalogueRow] {
        lock.lock()
        _catalogueCalls += 1
        lock.unlock()
        if let failAll { throw failAll }
        return []
    }

    func linkRows() async throws -> [AccountTagLinkRow] {
        if let failAll { throw failAll }
        return []
    }
}

private final class CompletionTestUploader: RemoteUploader, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Error?
    private var _count = 0

    init(failsWith failure: Error? = nil) {
        self.failure = failure
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return _count
    }

    func upload(operation: SyncOutboxOperation) async throws -> Int {
        lock.lock()
        _count += 1
        lock.unlock()
        if let failure { throw failure }
        return operation.sizeBytes
    }
}

private actor CompletionTestPuller: RemotePuller {
    private(set) var calls = 0
    nonisolated let accountTagsReader: RemoteAccountTagsReader?

    init(reader: RemoteAccountTagsReader?) {
        self.accountTagsReader = reader
    }

    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        calls += 1
        return SyncPullPage(changes: [], nextCursor: cursor, hasMore: false)
    }
}

private actor SuspendedCompletionPuller: RemotePuller {
    nonisolated let accountTagsReader: RemoteAccountTagsReader?
    private(set) var calls = 0
    private var suspendedOnce = false
    private var pending: CheckedContinuation<SyncPullPage, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(reader: RemoteAccountTagsReader?) {
        self.accountTagsReader = reader
    }

    /// Only the FIRST pull suspends (the "in-flight response" window); later
    /// passes see a quiet account.
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        calls += 1
        if suspendedOnce {
            return SyncPullPage(changes: [], nextCursor: cursor, hasMore: false)
        }
        suspendedOnce = true
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: SyncPullPage(changes: [], nextCursor: 0, hasMore: false))
        pending = nil
    }
}

/// Deterministic multi-page remote change source for the T11 drain test.
private actor SequencedCompletionPuller: RemotePuller {
    nonisolated let accountTagsReader: RemoteAccountTagsReader?
    private let pages: Int
    private let perPage: Int
    private(set) var calls = 0

    init(pages: Int, perPage: Int, reader: RemoteAccountTagsReader?) {
        self.pages = pages
        self.perPage = perPage
        self.accountTagsReader = reader
    }

    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        calls += 1
        // After the scripted pages the remote has nothing new: an empty page
        // with the cursor unchanged (no replayed sequences).
        guard calls <= pages else {
            return SyncPullPage(changes: [], nextCursor: cursor, hasMore: false)
        }
        let page = calls
        let start = Int64((page - 1) * perPage) + 1
        let changes = (0..<perPage).map { index -> SyncRemoteChange in
            let sequence = start + Int64(index)
            let created = Date(timeIntervalSince1970: 1_787_000_000 + Double(sequence))
            return SyncRemoteChange(
                id: UUID(),
                type: "text",
                body: "page \(page) item \(index)",
                createdAt: created,
                pinnedAt: nil,
                location: nil,
                weather: nil,
                device: "Synthetic A",
                source: "synthetic",
                vaultPath: nil,
                sourceModifiedAt: created,
                contentHash: nil,
                syncRevision: sequence,
                lastSyncDeviceId: nil,
                deletedAt: nil,
                changeSequence: sequence
            )
        }
        return SyncPullPage(
            changes: changes,
            nextCursor: start + Int64(perPage) - 1,
            hasMore: page < pages
        )
    }
}
