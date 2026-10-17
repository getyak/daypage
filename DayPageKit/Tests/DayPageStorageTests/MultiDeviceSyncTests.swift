import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

final class MultiDeviceSyncTests: XCTestCase {
    private var temporaryVault: URL!
    private let userA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let userB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    override func setUpWithError() throws {
        let baseDirectory = SyncRealmTestSupport.fixtureRoot
        temporaryVault = baseDirectory
            .appendingPathComponent("daypage-multidevice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryVault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = temporaryVault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let temporaryVault {
            try? FileManager.default.removeItem(at: temporaryVault)
        }
    }

    func testVaultBindingRejectsAnotherAccountAndCursorIsMonotonic() throws {
        let realmA = try SyncRealmTestSupport.realm(origin: "https://a.example", user: userA)
        let realmB = try SyncRealmTestSupport.realm(origin: "https://a.example", user: userB)
        XCTAssertEqual(try SyncAccountStateStore.bind(to: realmA), 0)
        try SyncAccountStateStore.advancePullCursor(to: 42, for: realmA)
        try SyncAccountStateStore.advancePullCursor(to: 12, for: realmA)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: realmA), 42)

        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: realmB)) { error in
            guard case SyncAccountStateError.accountMismatch(let expected, let actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, self.userA)
            XCTAssertEqual(actual, self.userB)
        }
    }

    func testRemoteChangeBecomesLocalWithoutOutboundEcho() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        let change = makeChange(
            id: memoID,
            body: "from the other Mac",
            createdAt: created,
            revision: 1,
            sequence: 10
        )

        let result = try RawStorage.applyRemoteChanges([change])

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertTrue(result.conflictCopies.isEmpty)
        XCTAssertEqual(try RawStorage.read(for: created).first?.id, memoID)
        XCTAssertEqual(try RawStorage.read(for: created).first?.body, "from the other Mac")
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)

        var edited = try XCTUnwrap(try RawStorage.read(for: created).first)
        edited.body = "edited on this Mac"
        try RawStorage.rewrite([edited], for: created)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().first?.revision, 2)
    }

    func testConcurrentEditPreservesLocalCopyAndInstallsRemoteCanonical() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "base",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])

        var local = try XCTUnwrap(try RawStorage.read(for: created).first)
        local.body = "local concurrent edit"
        try RawStorage.rewrite([local], for: created)

        let result = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "remote concurrent edit",
            createdAt: created,
            revision: 2,
            sequence: 2,
            contentHash: "remote-hash"
        )])

        let memos = try RawStorage.read(for: created)
        XCTAssertEqual(memos.first(where: { $0.id == memoID })?.body, "remote concurrent edit")
        let conflictID = try XCTUnwrap(result.conflictCopies.first)
        XCTAssertEqual(memos.first(where: { $0.id == conflictID })?.body, "local concurrent edit")
        let pending = try SyncOutboxStore.pendingOperations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.memoID, conflictID)
        XCTAssertEqual(pending.first?.revision, 1)
    }

    func testMatchingTextHashCannotAcknowledgeDifferentMediaManifest() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "same metadata",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])
        var local = try XCTUnwrap(try RawStorage.read(for: created).first)
        local.attachments = [Memo.Attachment(
            file: "raw/assets/local.png",
            kind: "photo"
        )]
        try RawStorage.rewrite([local], for: created)
        let pendingHash = try XCTUnwrap(
            SyncOutboxStore.pendingOperations().first?.contentHash
        )
        let remoteHash = String(repeating: "a", count: 64)
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: remoteHash,
            sizeBytes: 8,
            mimeType: "image/png",
            objectKey: "\(userA.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(remoteHash).png",
            originalFilename: "remote.png"
        )

        let result = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "same metadata",
            createdAt: created,
            revision: 2,
            sequence: 2,
            contentHash: pendingHash,
            attachmentManifestHash: AttachmentManifest.hash([descriptor]),
            attachments: [descriptor]
        )])

        let conflictID = try XCTUnwrap(result.conflictCopies.first)
        let conflict = try XCTUnwrap(
            try RawStorage.read(for: created).first(where: { $0.id == conflictID })
        )
        XCTAssertEqual(conflict.attachments.first?.file, "raw/assets/local.png")
        XCTAssertEqual(
            try SyncOutboxStore.pendingOperations().first?.memoID,
            conflictID
        )
    }

    func testRemoteTombstoneDeletesCanonicalWithoutEcho() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "delete on device A",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])
        let deletion = makeChange(
            id: memoID,
            body: "",
            createdAt: created,
            revision: 2,
            sequence: 2,
            deletedAt: Date(timeIntervalSince1970: 1_787_500_900)
        )

        let result = try RawStorage.applyRemoteChanges([deletion])

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(try RawStorage.read(for: created).isEmpty)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }

    func testRemoteTombstonePreservesPendingLocalUpsertEvenWhenHashMatches() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "base",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])
        var local = try XCTUnwrap(try RawStorage.read(for: created).first)
        local.body = "keep this local text"
        try RawStorage.rewrite([local], for: created)
        let localHash = try XCTUnwrap(
            SyncOutboxStore.pendingOperations().first?.contentHash
        )

        let result = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "",
            createdAt: created,
            revision: 2,
            sequence: 2,
            contentHash: localHash,
            deletedAt: Date(timeIntervalSince1970: 1_787_500_900)
        )])

        XCTAssertNil(try RawStorage.read(for: created).first(where: { $0.id == memoID }))
        let conflictID = try XCTUnwrap(result.conflictCopies.first)
        XCTAssertEqual(
            try RawStorage.read(for: created).first(where: { $0.id == conflictID })?.body,
            "keep this local text"
        )
    }

    private func makeChange(
        id: UUID,
        body: String,
        createdAt: Date,
        revision: Int64,
        sequence: Int64,
        contentHash: String? = nil,
        deletedAt: Date? = nil,
        attachmentManifestHash: String? = nil,
        attachments: [SyncAttachmentDescriptor]? = nil
    ) -> SyncRemoteChange {
        SyncRemoteChange(
            id: id,
            type: "text",
            body: body,
            createdAt: createdAt,
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: "Mac A",
            source: "macos",
            vaultPath: "raw/2026-08-24.md",
            sourceModifiedAt: createdAt,
            contentHash: contentHash,
            syncRevision: revision,
            lastSyncDeviceId: UUID().uuidString.lowercased(),
            deletedAt: deletedAt,
            changeSequence: sequence,
            attachmentManifestHash: attachmentManifestHash,
            attachments: attachments
        )
    }
}

private struct PullStubTransport: HTTPTransport {
    let data: Data
    let status: Int

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

final class SupabaseSyncPullerTests: XCTestCase {
    private var temporaryVault: URL!

    override func setUpWithError() throws {
        temporaryVault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-puller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryVault,
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = temporaryVault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let temporaryVault {
            try? FileManager.default.removeItem(at: temporaryVault)
        }
    }

    func testDecodesMonotonicPullPageAndSendsCursor() async throws {
        let memoID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "changes": [[
                "id": memoID.uuidString.lowercased(),
                "type": "text",
                "body": "remote",
                "created_at": "2026-08-24T00:00:00.123Z",
                "pinned_at": NSNull(),
                "location": NSNull(),
                "weather": NSNull(),
                "device": NSNull(),
                "source": "macos",
                "vault_path": "raw/2026-08-24.md",
                "source_modified_at": "2026-08-24T00:00:00Z",
                "content_hash": "hash",
                "sync_revision": 3,
                "last_sync_device_id": NSNull(),
                "deleted_at": NSNull(),
                "change_sequence": 91,
            ]],
            "next_cursor": 91,
            "has_more": false,
        ])
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let puller = SupabaseSyncPuller(
            session: session,
            transport: PullStubTransport(data: data, status: 200),
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
        )

        let page = try await puller.pull(after: 90, limit: 50)

        XCTAssertEqual(page.nextCursor, 91)
        XCTAssertEqual(page.changes.first?.id, memoID)
        XCTAssertEqual(page.changes.first?.syncRevision, 3)
        XCTAssertTrue(page.isValid(after: 90))
    }

    func testRejectsCursorThatCouldSkipOrReplayChanges() throws {
        let change = SyncRemoteChange(
            id: UUID(),
            type: "text",
            body: "remote",
            createdAt: Date(),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "macos",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 91
        )

        XCTAssertFalse(SyncPullPage(
            changes: [change],
            nextCursor: 92,
            hasMore: false
        ).isValid(after: 90))
        XCTAssertFalse(SyncPullPage(
            changes: [],
            nextCursor: 90,
            hasMore: true
        ).isValid(after: 90))
    }

    func testDecodesLegacyStringWeatherWithoutRejectingWholePage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "changes": [[
                "id": UUID().uuidString,
                "type": "text",
                "body": "legacy weather",
                "created_at": "2026-08-24T00:00:00Z",
                "weather": "晴",
                "source": "web",
                "sync_revision": 0,
                "change_sequence": 1,
            ]],
            "next_cursor": 1,
            "has_more": false,
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let page = try decoder.decode(SyncPullPage.self, from: data)

        XCTAssertEqual(page.changes.first?.weather?.condition, "晴")
    }
}

private actor MediaThenTextUploader: RemoteUploader {
    private var attemptedMemoIDs: [UUID] = []

    func upload(operation: SyncOutboxOperation) async throws -> Int {
        attemptedMemoIDs.append(operation.memoID)
        if attemptedMemoIDs.count == 1 { throw AttachmentSyncError.network }
        return operation.sizeBytes
    }

    func attempts() -> [UUID] { attemptedMemoIDs }
}

private actor PullCounter: RemotePuller {
    private var count = 0

    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        count += 1
        return SyncPullPage(changes: [], nextCursor: cursor, hasMore: false)
    }

    func calls() -> Int { count }
}

@MainActor
final class IndependentMediaSchedulingTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-independent-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: vault)
    }

    func testDeferredMediaDoesNotBlockLaterTextOrPull() async throws {
        let mediaMemo = Memo(body: "media operation")
        let textMemo = Memo(body: "later text operation")
        try SyncOutboxStore.recordUpsert(
            mediaMemo,
            vaultPath: "raw/2026-08-26.md",
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        try SyncOutboxStore.recordUpsert(
            textMemo,
            vaultPath: "raw/2026-08-26.md",
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let uploader = MediaThenTextUploader()
        let puller = PullCounter()
        let observer = SyncQueueObserver(observeNotifications: false)
        let realm = try SyncRealmTestSupport.realm()
        try observer.configureSession(
            session: try SyncRealmTestSupport.session(realm: realm),
            uploader: uploader,
            puller: puller,
            periodicInterval: 0
        )

        await observer.flush()

        let attemptedMemoIDs = await uploader.attempts()
        let pullCount = await puller.calls()
        XCTAssertEqual(attemptedMemoIDs, [mediaMemo.id, textMemo.id])
        XCTAssertEqual(pullCount, 1)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().map(\.memoID), [mediaMemo.id])
        observer.clearSession()
    }
}

/// Mid-flight generation barriers for the durable effects a replaced session
/// must never commit: raw apply and media install. Uses real
/// `RawStorage.applyRemoteChanges` and `SupabaseAttachmentDownloader` with the
/// real lease gate.
@MainActor
final class SyncRealmBarrierTests: XCTestCase {
    private var vault: URL!
    private var previousVault: URL?

    override func setUpWithError() throws {
        previousVault = VaultInitializer.testOverrideURL
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-realm-barriers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw/assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousVault
        if let vault {
            try? FileManager.default.removeItem(at: vault)
        }
    }

    func testRawApplyCommitIsRefusedAfterInvalidation() throws {
        let lease = SyncSessionLease()
        let applied = barrierChange(id: UUID(), body: "applied while valid", sequence: 1)
        let refused = barrierChange(id: UUID(), body: "must not install", sequence: 2)

        let result = try RawStorage.applyRemoteChanges([applied], sessionLease: lease)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertNotNil(RawStorage.memo(id: applied.id))

        lease.invalidate()
        XCTAssertThrowsError(
            try RawStorage.applyRemoteChanges([refused], sessionLease: lease)
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        // The refused page installed nothing and left no partial raw state.
        XCTAssertNil(RawStorage.memo(id: refused.id))
    }

    /// Documented ordering: a commit that already entered the gate may finish
    /// (here the invalidation is requested mid-commit); only later commits
    /// are refused.
    func testRawCommitFinishesDocumentedOrderingThenRefuses() throws {
        let lease = SyncSessionLease()
        let applied = barrierChange(id: UUID(), body: "finishes mid invalidation", sequence: 3)
        let refused = barrierChange(id: UUID(), body: "refused later", sequence: 4)

        let result = try RawStorage.applyRemoteChanges(
            [applied],
            sessionLease: lease,
            afterWrite: { stage in
                if stage == .canonicalMemo {
                    lease.invalidate()
                }
            }
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertNotNil(RawStorage.memo(id: applied.id))
        XCTAssertThrowsError(try RawStorage.applyRemoteChanges([refused], sessionLease: lease))
        XCTAssertNil(RawStorage.memo(id: refused.id))
    }

    /// A download that completes AFTER the session was invalidated must not
    /// install media or rewrite the durable obligation.
    func testMidflightDownloadDoesNotInstallAfterInvalidation() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let lease = session.lease
        let memoID = UUID()

        let relativePath = "raw/assets/barrier-source.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 5, 4, 3, 2])
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "barrier.png"
        )
        let item = try XCTUnwrap(try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID,
            descriptors: [descriptor],
            realm: realm
        ).first)

        let transport = InvalidatingDownloadTransport(
            sourceURL: vault.appendingPathComponent(relativePath),
            lease: lease
        )
        let downloader = SupabaseAttachmentDownloader(
            session: session,
            fileTransport: transport
        )
        try await downloader.persistAndAttempt(changes: [], token: try SyncRealmTestSupport.verifiedToken("token", realm: realm))

        // The stale download never installed media and never closed or
        // rewrote the obligation: it is held for a later same-realm retry.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(item.relativePath).path
        ))
        let summary = AttachmentTransferStore.summary(memoIDs: [memoID.uuidString])
        XCTAssertTrue(summary.hasMedia)
        XCTAssertEqual(summary.transferred, 0)
        let attempts = await transport.attempts
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Send-start linearization (NATIVE-EFFECTS-001)

    /// Invalidations that linearize before the actual request start must mean
    /// ZERO request starts on data, upload and download paths.
    func testRequestStartsAreLinearizedWithInvalidation() async throws {
        let lease = SyncSessionLease()
        let starter = BlockingStartStarter()
        let network = SyncSessionNetwork(lease: lease, starter: starter)

        lease.invalidate()

        do {
            _ = try await network.data(for: URLRequest(url: URL(string: "https://example.supabase.co/rest/v1/rpc/x")!))
            XCTFail("stale data send must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        do {
            _ = try await network.uploadFile(
                for: URLRequest(url: URL(string: "https://example.supabase.co/storage/v1/object/x")!),
                from: vault.appendingPathComponent("raw/x.bin")
            )
            XCTFail("stale upload send must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        do {
            _ = try await network.downloadFile(
                for: URLRequest(url: URL(string: "https://example.supabase.co/storage/v1/object/y")!)
            )
            XCTFail("stale download send must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        let starts = starter.starts
        XCTAssertEqual(starts, 0, "invalidation must prevent any request start")
    }

    /// A request that already STARTED may finish, but its result must never
    /// commit local state; and the components really route sends through the
    /// gated starter (real `SupabaseSyncUploader` flow, delete operation).
    func testUploaderRoutesSendsThroughGatedStarter() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let receipt = try JSONSerialization.data(withJSONObject: [
            "accepted": [[
                "operation_id": UUID().uuidString.lowercased(),
                "status": "applied",
            ]],
            "rejected": [],
        ])
        _ = receipt
        let starter = RecordingStartStarter()
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: starter,
            fileTransport: starter,
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
        )
        let operationID = UUID()
        let operation = SyncOutboxOperation(
            operationID: operationID,
            memoID: UUID(),
            kind: .delete,
            revision: 1,
            modifiedAt: Date(),
            contentHash: nil,
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: 0
        )
        let applied = try JSONSerialization.data(withJSONObject: [
            "accepted": [["operation_id": operationID.uuidString, "status": "applied"]],
            "rejected": [],
        ])
        starter.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (applied, response)
        }
        _ = try await uploader.upload(operation: operation)
        let started = starter.requests
        XCTAssertEqual(started.count, 1, "one gated start for the RPC send")

        // Now invalidate BEFORE the next send: zero starts again.
        session.lease.invalidate()
        let nextOperation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: UUID(),
            kind: .delete,
            revision: 2,
            modifiedAt: Date(),
            contentHash: nil,
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: 0
        )
        do {
            _ = try await uploader.upload(operation: nextOperation)
            XCTFail("invalidated session must not send")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        let afterInvalidation = starter.requests
        XCTAssertEqual(afterInvalidation.count, 1, "no request may start after invalidation")
    }

    // MARK: - Transient download ownership (repair2 EFFECTS-001)

    func testOwnedTransientDownloadsAreAdoptedAndDiscarded() throws {
        // adopt() retains the bytes BEFORE the (callback) source vanishes.
        let source = vault.appendingPathComponent("raw/assets/adopt-source.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 4, 3])
        try bytes.write(to: source)
        let owned = try SyncNetworkTempFile.adopt(source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: owned), bytes, "owned copy survives the source")

        XCTAssertTrue(SyncNetworkTempFile.isOwned(owned))
        let attributes = try FileManager.default.attributesOfItem(atPath: owned.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)

        // discard() cleans the owned file and its owned directory…
        SyncNetworkTempFile.discard(owned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: owned.deletingLastPathComponent().path)
        )
        // …and is a no-op for foreign (fixture) URLs.
        SyncNetworkTempFile.discard(source)
        XCTAssertFalse(SyncNetworkTempFile.isOwned(source))
    }

    func testFailedTransientAdoptionRemovesOnlyItsNewOwnerDirectory() throws {
        let root = SyncNetworkTempFile.rootDirectory()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        let missing = vault.appendingPathComponent("missing-download.bin")
        XCTAssertThrowsError(try SyncNetworkTempFile.adopt(missing))
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        XCTAssertEqual(after, before)
    }

    func testDownloaderCleansOwnedTempsOnSuccessFailureAndStaleLease() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let namespaceBefore = try tempNamespaceEntries()

        // Success: the adopted temp is consumed into the Vault and cleaned.
        let relativePath = "raw/assets/owned-success.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 2, 2, 2])
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "owned.png"
        )
        let item = try XCTUnwrap(try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID,
            descriptors: [descriptor],
            realm: realm
        ).first)
        let downloader = SupabaseAttachmentDownloader(
            session: session,
            fileTransport: FlakyDownloadTransport(sourceURL: vault.appendingPathComponent(relativePath))
        )
        try await downloader.persistAndAttempt(
            changes: [],
            token: try SyncRealmTestSupport.verifiedToken("token", realm: realm)
        )
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent(item.relativePath)),
            bytes
        )

        // Stale lease: a fresh session for the SAME realm (new lease) whose
        // lease is invalidated mid-download; the adopted temp is cleaned and
        // nothing is installed.
        let staleSession = try SyncRealmTestSupport.session(realm: realm)
        let staleMemoID = UUID()
        let staleDescriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(staleMemoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "stale.png"
        )
        let staleItem = try XCTUnwrap(try AttachmentTransferStore.recordPendingDownloads(
            memoID: staleMemoID,
            descriptors: [staleDescriptor],
            realm: realm
        ).first)
        let invalidator = InvalidatingDownloadTransport(
            sourceURL: vault.appendingPathComponent(relativePath),
            lease: staleSession.lease
        )
        let staleDownloader = SupabaseAttachmentDownloader(
            session: staleSession,
            fileTransport: invalidator
        )
        try await staleDownloader.persistAndAttempt(
            changes: [],
            token: try SyncRealmTestSupport.verifiedToken("token", realm: realm)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(staleItem.relativePath).path
        ))

        // No owned transient file leaked on any path.
        let namespaceAfter = try tempNamespaceEntries()
        XCTAssertEqual(namespaceAfter, namespaceBefore)
    }

    func testUploaderVerificationCleansOwnedTemp() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let namespaceBefore = try tempNamespaceEntries()

        let relativePath = "raw/assets/owned-verify.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 7, 7, 7])
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: relativePath, kind: "photo")],
            body: "verify ownership"
        )
        try RawStorage.append(memo)
        let memoID = memo.id
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "owned-verify.png"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memoID,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: SyncMemoPayload(
                type: "photo",
                body: "verify ownership",
                createdAt: memo.created,
                pinnedAt: nil,
                location: nil,
                weather: nil,
                device: nil,
                source: "ios",
                vaultPath: "raw/verify.md"
            ),
            sizeBytes: memo.toMarkdown().utf8.count
        )
        _ = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            realm: realm
        )
        let manifestHash = AttachmentManifest.hash([descriptor])
        let recorder = ExistsThenReceiptTransport(
            prepareKey: descriptor.objectKey,
            operationID: operation.operationID,
            manifestHash: manifestHash,
            downloadSource: vault.appendingPathComponent(relativePath)
        )
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: recorder,
            fileTransport: recorder,
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: realm) }
        )
        _ = try await uploader.upload(operation: operation)

        // verifyRemoteObject consumed the adopted temp and cleaned it.
        XCTAssertEqual(AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).transferred, 1)
        XCTAssertEqual(try tempNamespaceEntries(), namespaceBefore)
    }

    private func tempNamespaceEntries() throws -> [String] {
        let root = SyncNetworkTempFile.rootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    // MARK: - Staging partial preservation (NATIVE-EFFECTS-002)

    func testStaleDownloadPreservesExistingPartialBytes() async throws {
        let realm = try SyncRealmTestSupport.realm()
        let session = try SyncRealmTestSupport.session(realm: realm)
        let memoID = UUID()

        let relativePath = "raw/assets/preserved-source.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9, 9, 9])
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let inspected = try AttachmentFileInspector.inspect(relativePath: relativePath, kind: "photo")
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(realm.userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "preserved.png"
        )
        let item = try XCTUnwrap(try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID,
            descriptors: [descriptor],
            realm: realm
        ).first)
        let stagingURL = SupabaseAttachmentDownloader.stagingURL(recordID: item.recordID)
        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: stagingURL)
        let stateBefore = try Data(contentsOf: AttachmentTransferStore.stateURL)

        // The session is stale before ANY staging mutation may run.
        session.lease.invalidate()
        let downloader = SupabaseAttachmentDownloader(
            session: session,
            fileTransport: InvalidatingDownloadTransport(
                sourceURL: vault.appendingPathComponent(relativePath),
                lease: session.lease
            )
        )
        do {
            try await downloader.persistAndAttempt(
                changes: [],
                token: try SyncRealmTestSupport.verifiedToken("token", realm: realm)
            )
            XCTFail("stale session must not touch staging state")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        // Existing partial bytes and sidecar state are preserved untouched.
        XCTAssertEqual(try Data(contentsOf: stagingURL), bytes)
        XCTAssertEqual(try Data(contentsOf: AttachmentTransferStore.stateURL), stateBefore)
    }

    private func barrierChange(id: UUID, body: String, sequence: Int64) -> SyncRemoteChange {
        let created = Date(timeIntervalSince1970: 1_787_500_000 + Double(sequence))
        return SyncRemoteChange(
            id: id,
            type: "text",
            body: body,
            createdAt: created,
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: "Mac A",
            source: "macos",
            vaultPath: "raw/2026-09-01.md",
            sourceModifiedAt: created,
            contentHash: nil,
            syncRevision: sequence,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: sequence
        )
    }
}

/// Records each synchronous start; used to prove that invalidation before
/// the start means ZERO request starts.
/// Serves prepare (already_exists), the receipt RPC and a downloadable
/// source file for the ownership-cleanup test.
private final class ExistsThenReceiptTransport: HTTPTransport, AttachmentFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let prepareKey: String
    private let operationID: UUID
    private let manifestHash: String
    private let downloadSource: URL

    init(prepareKey: String, operationID: UUID, manifestHash: String, downloadSource: URL) {
        self.prepareKey = prepareKey
        self.operationID = operationID
        self.manifestHash = manifestHash
        self.downloadSource = downloadSource
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        if url.absoluteString.contains("daypage_prepare_attachment_upload") {
            let body = try JSONSerialization.data(withJSONObject: [
                "reservation_id": UUID().uuidString.lowercased(),
                "object_key": prepareKey,
                "expires_at": "2026-10-16T00:00:00Z",
                "already_exists": true,
            ])
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, response)
        }
        if url.absoluteString.contains("daypage_apply_sync_operations_v2") {
            let body = try JSONSerialization.data(withJSONObject: [
                "accepted": [[
                    "operation_id": operationID.uuidString,
                    "status": "applied",
                    "attachment_manifest_hash": manifestHash,
                ]],
                "rejected": [],
            ])
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, response)
        }
        throw AttachmentSyncError.network
    }

    func uploadFile(for request: URLRequest, from fileURL: URL) async throws -> (Data, URLResponse) {
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (downloadSource, response)
    }
}

private final class FlakyDownloadTransport: AttachmentFileTransport, @unchecked Sendable {
    private let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func uploadFile(for request: URLRequest, from fileURL: URL) async throws -> (Data, URLResponse) {
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (sourceURL, response)
    }
}

private final class BlockingStartStarter: SyncRequestStarter, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var starts: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func startData(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        lock.lock(); count += 1; lock.unlock()
        return SyncPendingResult<(Data, URLResponse)>()
    }

    func startUpload(
        _ request: URLRequest,
        from fileURL: URL
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        lock.lock(); count += 1; lock.unlock()
        return SyncPendingResult<(Data, URLResponse)>()
    }

    func startDownload(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(URL, URLResponse)> {
        lock.lock(); count += 1; lock.unlock()
        return SyncPendingResult<(URL, URLResponse)>()
    }
}

/// Records synchronous request starts and serves canned results.
private final class RecordingStartStarter: SyncRequestStarter, HTTPTransport, AttachmentFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))?

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func startData(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        lock.lock()
        recorded.append(request.url?.absoluteString ?? "")
        let handler = self.handler
        lock.unlock()
        return .started {
            guard let handler else { throw AttachmentSyncError.network }
            return try handler(request)
        }
    }

    func startUpload(
        _ request: URLRequest,
        from fileURL: URL
    ) throws -> SyncPendingResult<(Data, URLResponse)> {
        lock.lock()
        recorded.append(request.url?.absoluteString ?? "")
        lock.unlock()
        throw AttachmentSyncError.network
    }

    func startDownload(
        _ request: URLRequest
    ) throws -> SyncPendingResult<(URL, URLResponse)> {
        lock.lock()
        recorded.append(request.url?.absoluteString ?? "")
        lock.unlock()
        throw AttachmentSyncError.network
    }

    // Legacy async seams (components still accept the narrow protocols).
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await startData(request).value()
    }

    func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await startUpload(request, from: fileURL).value()
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await startDownload(request).value()
    }
}

private actor InvalidatingDownloadTransport: AttachmentFileTransport {
    private let sourceURL: URL
    private let lease: SyncSessionLease
    private(set) var attempts = 0

    init(sourceURL: URL, lease: SyncSessionLease) {
        self.sourceURL = sourceURL
        self.lease = lease
    }

    func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        attempts += 1
        // The download "finishes" only after the session generation changed.
        lease.invalidate()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (sourceURL, response)
    }
}
