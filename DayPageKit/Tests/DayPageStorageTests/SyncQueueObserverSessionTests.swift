import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

@MainActor
final class SyncQueueObserverSessionTests: XCTestCase {
    private var vault: URL!
    private var previousVault: URL?
    private var defaults: UserDefaults!
    private var suite: String!
    private var service: SyncQueueService!
    private let boundAccount = UUID()
    private let boundOrigin = "https://realm-a.example"
    private var boundRealm: SyncRealmIdentity!

    override func setUpWithError() throws {
        previousVault = VaultInitializer.testOverrideURL
        vault = SyncRealmTestSupport.fixtureRoot.appendingPathComponent("observer-session-\(UUID())")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("raw"), withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = vault
        suite = "SyncQueueObserverSessionTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        service = SyncQueueService.makeForTesting(defaults: defaults)
        boundRealm = try makeRealm(user: boundAccount, origin: boundOrigin)
        try SyncAccountStateStore.bind(to: boundRealm)
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousVault
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: vault)
        service = nil
    }

    func testRejectedBindingBlocksPendingAndExplicitUploaderUntilValidSession() async throws {
        try seedPendingMemo()
        let uploader = SessionTestUploader()
        let puller = SessionTestPuller()
        let observer = makeObserver(legacyConfigured: true)
        rejectBinding(observer, uploader: uploader, puller: puller)
        let failure = service.syncHealth

        observer.installConfiguredUploader()
        observer.setUploader(uploader)
        await observer.flush()

        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        let blockedUploads = await uploader.count
        XCTAssertEqual(blockedUploads, 0)

        try observer.configureSession(
            session: makeSession(realm: boundRealm),
            uploader: uploader,
            puller: puller,
            periodicInterval: 0
        )
        await observer.flush()

        XCTAssertEqual(service.syncHealth.consecutiveFailureCount, 0)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
        let uploads = await uploader.count
        let pulls = await puller.count
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(pulls, 1)
        observer.clearSession()
    }

    /// A bound Vault must never fall back to the legacy uploader — or report
    /// empty-queue "success" — even after an explicit sign-out. Only a
    /// genuinely pristine, unclaimed Vault keeps the legacy bridge.
    func testBoundVaultCannotFallBackToLegacyAfterSignOut() async throws {
        let observer = makeObserver(legacyConfigured: true)
        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        let failure = service.syncHealth

        // Explicit signed-out reset clears the rejection flag…
        observer.clearSession()
        // …but the Vault is bound, so legacy upload stays blocked.
        observer.installConfiguredUploader()
        await observer.flush()

        XCTAssertNil(service.syncHealth.lastSuccessAt)
        XCTAssertEqual(service.syncHealth.consecutiveFailureCount, failure.consecutiveFailureCount)
        XCTAssertEqual(service.syncHealth.lastFailureCode, failure.lastFailureCode)
    }

    /// The legacy bridge still works for a first unclaimed Vault with legacy
    /// configuration; the empty queue records a truthful success.
    func testPristineVaultKeepsLegacyEmptyQueueSuccess() async throws {
        // A pristine Vault has no account binding at all.
        try FileManager.default.removeItem(at: SyncAccountStateStore.stateURL)
        XCTAssertNil(try SyncAccountStateStore.boundRealm())
        XCTAssertTrue(SyncAccountStateStore.isUnclaimedVault())

        let observer = makeObserver(legacyConfigured: true)
        observer.clearSession()
        observer.installConfiguredUploader()
        await observer.flush()

        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        XCTAssertEqual(service.syncHealth.consecutiveFailureCount, 0)
    }

    func testUploaderOnlyInjectionStillDrainsOrdinaryUnrejectedQueue() async throws {
        try seedPendingMemo()
        let uploader = SessionTestUploader()
        let observer = makeObserver(legacyConfigured: false)
        observer.setUploader(uploader)
        await observer.flush()
        let uploads = await uploader.count
        XCTAssertEqual(uploads, 1)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }

    func testOldPullCompletionCannotEraseRejectedBindingFailure() async throws {
        let puller = SuspendedSessionPuller()
        let observer = makeObserver(legacyConfigured: true)
        try observer.configureSession(
            session: makeSession(realm: boundRealm),
            uploader: SessionTestUploader(),
            puller: puller,
            periodicInterval: 0
        )
        let flush = Task { await observer.flush() }
        await puller.waitUntilStarted()

        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        let failure = service.syncHealth
        await puller.finish()
        await flush.value

        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertNil(service.syncHealth.lastSuccessAt)
        XCTAssertFalse(service.isFlushingNow)
    }

    func testOldUploadReceiptCannotDrainAfterRejectedBinding() async throws {
        try seedPendingMemo()
        let uploader = SuspendedSessionUploader()
        let observer = makeObserver(legacyConfigured: true)
        try observer.configureSession(
            session: makeSession(realm: boundRealm),
            uploader: uploader,
            puller: SessionTestPuller(),
            periodicInterval: 0
        )
        let flush = Task { await observer.flush() }
        await uploader.waitUntilStarted()

        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        let failure = service.syncHealth
        await uploader.finish()
        await flush.value

        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        XCTAssertFalse(service.isFlushingNow)
    }

    /// Same-realm session replacement (token refresh): the old lease is
    /// invalidated, so a mid-flight upload receipt from the old lease can not
    /// ack the outbox, while a later retry under the new lease succeeds and
    /// keeps the operation ID/revision untouched.
    func testMidflightUploadReceiptIsNotAckedAfterSameRealmReplacement() async throws {
        try seedPendingMemo()
        let pendingBefore = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)
        let suspended = SuspendedSessionUploader()
        let observer = makeObserver(legacyConfigured: false)
        let firstSession = try makeSession(realm: boundRealm)
        try observer.configureSession(
            session: firstSession,
            uploader: suspended,
            puller: SessionTestPuller(),
            periodicInterval: 0
        )
        let flush = Task { await observer.flush() }
        await suspended.waitUntilStarted()

        // Refresh replaces the session generation (same realm).
        let replacement = SessionTestUploader()
        try observer.configureSession(
            session: makeSession(realm: boundRealm),
            uploader: replacement,
            puller: SessionTestPuller(),
            periodicInterval: 0
        )
        await suspended.finish()
        await flush.value

        // The stale receipt was consumed under a dead lease: it can neither
        // ack the operation nor change its identity. The NEW generation's
        // own immediate retry (initial demand surviving the busy pass — item
        // 10) or an explicit flush is the ONLY ack, and it reuses the exact
        // operation ID/revision.
        if try !SyncOutboxStore.pendingOperations().isEmpty {
            await observer.flush()
        }
        let deadline = Date().addingTimeInterval(3)
        while try !SyncOutboxStore.pendingOperations().isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
        let uploads = await replacement.operations
        XCTAssertEqual(uploads.count, 1, "exactly one retry — stale receipts never ack or replay")
        XCTAssertEqual(uploads.first?.operationID, pendingBefore.operationID)
        XCTAssertEqual(uploads.first?.revision, pendingBefore.revision)
        observer.clearSession()
    }

    func testLogoutDropsBusyManualDemandWithoutChangingClearedHealth() async throws {
        let suspended = SuspendedSessionPuller()
        let observer = makeObserver(legacyConfigured: false)
        try observer.configureSession(
            session: makeSession(realm: boundRealm), uploader: SessionTestUploader(),
            puller: suspended, periodicInterval: 0
        )
        let active = Task { await observer.flush(reason: .initial) }
        await suspended.waitUntilStarted()
        await observer.flush(reason: .manual)
        await service.flushIfOnline(reason: .manual)
        observer.clearSession()
        let clearedHealth = service.syncHealth
        await suspended.finish()
        await active.value
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(service.syncHealth, clearedHealth)
        XCTAssertNil(service.takePendingDemand())
        XCTAssertFalse(service.isFlushingNow)
        observer.clearSession()
    }

    func testQueuedNotificationCannotFlushReplacementButItsOwnInitialRunsOnce() async throws {
        let observer = SyncQueueObserver(observeNotifications: true, syncQueue: service, legacyIsConfigured: { false })
        let old = SessionTestPuller()
        let current = SessionTestPuller()
        try observer.configureSession(
            session: makeSession(realm: boundRealm), uploader: SessionTestUploader(), puller: old, periodicInterval: 0
        )
        // The host's synchronous service entry posts/captures A before its
        // callback returns; there is no unbound host Task before delivery.
        service.requestFlushIfOnline(reason: .manual)
        observer.clearSession()
        try observer.configureSession(
            session: makeSession(realm: boundRealm), uploader: SessionTestUploader(), puller: current, periodicInterval: 0
        )
        for _ in 0..<30 { await Task.yield() }
        let oldCount = await old.count
        let beforeOwnDemand = await current.count
        XCTAssertEqual(oldCount, 0)
        XCTAssertEqual(beforeOwnDemand, 0, "A's queued notification must not become C's full refresh")

        service.requestFlushIfOnline(reason: .initial)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await current.count == 1, !service.isFlushingNow { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<30 { await Task.yield() }
        let completed = await current.count
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(service.isFlushingNow)
        observer.clearSession()
    }

    func testServiceInitialDemandDuringReplacementRunsExactlyOnce() async throws {
        let observer = SyncQueueObserver(observeNotifications: true, syncQueue: service, legacyIsConfigured: { false })
        let suspended = SuspendedSessionPuller()
        let replacement = SessionTestPuller()
        try observer.configureSession(
            session: makeSession(realm: boundRealm), uploader: SessionTestUploader(), puller: suspended, periodicInterval: 0
        )
        let active = Task { await observer.flush(reason: .initial) }
        await suspended.waitUntilStarted()
        try observer.configureSession(
            session: makeSession(realm: boundRealm), uploader: SessionTestUploader(), puller: replacement, periodicInterval: 0
        )
        await service.flushIfOnline(reason: .initial)
        await suspended.finish()
        await active.value
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await replacement.count == 1, !service.isFlushingNow { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<30 { await Task.yield() }
        let completed = await replacement.count
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(service.isFlushingNow)
        observer.clearSession()
    }

    /// A page awaited under an old lease never installs raw changes nor
    /// advances the cursor after the session was replaced.
    func testMidflightPullResultDoesNotApplyOrAdvanceCursorAfterReplacement() async throws {
        let puller = SuspendedSessionPuller()
        let observer = makeObserver(legacyConfigured: false)
        try observer.configureSession(
            session: makeSession(realm: boundRealm),
            uploader: SessionTestUploader(),
            puller: puller,
            periodicInterval: 0
        )
        let cursorBefore = try SyncAccountStateStore.pullCursor(for: boundRealm)
        let flush = Task { await observer.flush() }
        await puller.waitUntilStarted()

        try observer.configureSession(
            session: makeSession(realm: boundRealm),
            uploader: SessionTestUploader(),
            puller: SessionTestPuller(),
            periodicInterval: 0
        )
        await puller.finish()
        await flush.value

        // The STALE pass must not install raw changes nor advance the cursor.
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: boundRealm), cursorBefore)
        // The replacement generation legitimately schedules its OWN initial
        // pass immediately (the item-10 demand survives a busy stale pass,
        // periodicInterval == 0 included). Await that pass to quiesce, then
        // assert no flush bookkeeping is left stuck.
        let deadline = Date().addingTimeInterval(3)
        while service.isFlushingNow, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(service.isFlushingNow)
        // The follow-up ran against the NEW generation only — cursor unchanged.
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: boundRealm), cursorBefore)
        observer.clearSession()
    }

    /// Non-nil A→B host reinstall: the other realm's context fails closed on
    /// a bound Vault, keeps the outbox, and latches the rejection so legacy
    /// upload cannot reopen.
    func testRealmChangeOnBoundVaultIsRejectedAndHoldsOutbox() async throws {
        try seedPendingMemo()
        let observer = makeObserver(legacyConfigured: true)
        let foreignRealm = try makeRealm(user: boundAccount, origin: "https://realm-b.example")
        let uploader = SessionTestUploader()

        XCTAssertThrowsError(
            try observer.configureSession(
                session: makeSession(realm: foreignRealm),
                uploader: uploader,
                puller: SessionTestPuller(),
                periodicInterval: 0
            )
        ) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .originMismatch(
                expected: boundRealm.normalizedOrigin,
                actual: foreignRealm.normalizedOrigin
            ))
        }
        // Match RootView's rejected-configuration cleanup.
        observer.clearSession(rejectedConfiguration: true)
        observer.installConfiguredUploader()
        await observer.flush()

        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        let uploads = await uploader.count
        XCTAssertEqual(uploads, 0)
        XCTAssertNil(service.syncHealth.lastSuccessAt)
    }

    // MARK: - Async install attempt coordination (stale-task isolation)

    func testStaleInstallFailureCannotInvalidateNewerInstall() async throws {
        let observer = makeObserver(legacyConfigured: false)
        let prove = SuspendedProve()
        var currentUser: UUID? = boundAccount
        var successes: [Int] = []
        var failures: [Int] = []

        let sessionA = try makeSession(realm: boundRealm)
        let uploaderA = SessionTestUploader()
        let reservationA = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let taskA = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationA,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in uploaderA },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(1) },
                onFailure: { _ in failures.append(1) }
            )
        }
        await prove.waitUntilStarted(1)

        let uploaderB = SessionTestUploader()
        let reservationB = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let taskB = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationB,
                currentUserID: { currentUser },
                prove: { try await prove.prove(2) },
                makeUploader: { _ in uploaderB },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(2) },
                onFailure: { _ in failures.append(2) }
            )
        }
        await prove.waitUntilStarted(2)
        await prove.succeed(2, session: sessionA)
        let bInstalled = await taskB.value
        XCTAssertTrue(bInstalled)

        // A fails AFTER B was installed: zero current mutations.
        await prove.fail(1, error: MemoSyncError.unauthorized)
        let aInstalled = await taskA.value
        XCTAssertFalse(aInstalled)
        XCTAssertEqual(successes, [2])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(observer.isConfigurationRejected)

        // B's session is still live and drains normally.
        try seedPendingMemo()
        await observer.flush()
        let uploadsB = await uploaderB.count
        let uploadsA = await uploaderA.count
        XCTAssertEqual(uploadsB, 1)
        XCTAssertEqual(uploadsA, 0)
        observer.clearSession()
    }

    func testStaleSuccessCannotOverwriteNewerRejection() async throws {
        let observer = makeObserver(legacyConfigured: true)
        let prove = SuspendedProve()
        var currentUser: UUID? = boundAccount
        var successes: [Int] = []
        var failures: [Int] = []

        let uploaderA = SessionTestUploader()
        let reservationA = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let taskA = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationA,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in uploaderA },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(1) },
                onFailure: { _ in failures.append(1) }
            )
        }
        await prove.waitUntilStarted(1)

        // A newer attempt fails and latches the rejection.
        let reservationB = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let taskB = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationB,
                currentUserID: { currentUser },
                prove: { throw MemoSyncError.unauthorized },
                makeUploader: { _ in SessionTestUploader() },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(2) },
                onFailure: { _ in failures.append(2) }
            )
        }
        let bInstalled = await taskB.value
        XCTAssertFalse(bInstalled)
        XCTAssertEqual(failures, [2])
        XCTAssertTrue(observer.isConfigurationRejected)

        // A's late success must not install over the newer rejection.
        await prove.succeed(1, session: try makeSession(realm: boundRealm))
        let aInstalled = await taskA.value
        XCTAssertFalse(aInstalled)
        XCTAssertEqual(successes, [])
        XCTAssertTrue(observer.isConfigurationRejected)

        try seedPendingMemo()
        await observer.flush()
        let uploads = await uploaderA.count
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        observer.clearSession(rejectedConfiguration: true)
    }

    /// The regression window from the review: the NEWER attempt is already
    /// RESERVED synchronously but its async installer has NOT started yet.
    /// The old attempt's ready continuation must already be stale.
    func testReservationInvalidatesOldSuccessBeforeNewInstallerRuns() async throws {
        let observer = makeObserver(legacyConfigured: true)
        let prove = SuspendedProve()
        var currentUser: UUID? = boundAccount
        var successes: [Int] = []
        var flushes = 0

        let uploaderA = SessionTestUploader()
        let reservationA = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let taskA = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationA,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in uploaderA },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(1) },
                onFlush: { flushes += 1 }
            )
        }
        await prove.waitUntilStarted(1)

        // B's synchronous auth event happens NOW (same user): reservation
        // only — B's async installer has not entered at all.
        let uploaderB = SessionTestUploader()
        let reservationB = observer.sessionInstaller.reserve(expectedUserID: boundAccount)

        // A's proof continuation was already queued and resumes first.
        await prove.succeed(1, session: try makeSession(realm: boundRealm))
        let aInstalled = await taskA.value
        XCTAssertFalse(aInstalled)
        XCTAssertEqual(successes, [])
        XCTAssertEqual(flushes, 0)
        let uploadsA = await uploaderA.count
        XCTAssertEqual(uploadsA, 0)

        // B (started later) is the only attempt that may install.
        let taskB = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationB,
                currentUserID: { currentUser },
                prove: { try await prove.prove(2) },
                makeUploader: { _ in uploaderB },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(2) }
            )
        }
        await prove.waitUntilStarted(2)
        await prove.succeed(2, session: try makeSession(realm: boundRealm))
        let bInstalled = await taskB.value
        XCTAssertTrue(bInstalled)
        XCTAssertEqual(successes, [2])
        try seedPendingMemo()
        await observer.flush()
        let uploadsB = await uploaderB.count
        XCTAssertEqual(uploadsB, 1)
        observer.clearSession()
    }

    func testReservationSwallowsOldFailureBeforeNewInstallerRuns() async throws {
        let observer = makeObserver(legacyConfigured: true)
        let prove = SuspendedProve()
        var currentUser: UUID? = boundAccount
        var failures: [Int] = []

        let reservationA = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let taskA = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservationA,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in SessionTestUploader() },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onFailure: { _ in failures.append(1) }
            )
        }
        await prove.waitUntilStarted(1)

        // Newer synchronous reservation; its async installer never starts.
        _ = observer.sessionInstaller.reserve(expectedUserID: boundAccount)

        await prove.fail(1, error: MemoSyncError.serverError(status: 503))
        let aInstalled = await taskA.value
        XCTAssertFalse(aInstalled)
        // Stale failure: no UI/health/rejection writes from the old attempt.
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(service.syncHealth.lastFailureCode, nil)
        observer.sessionInstaller.invalidateAllAttempts()
        observer.clearSession(rejectedConfiguration: true)
    }

    func testSameUserTokenPublicationInvalidatesProofBeforeViewCallback() async throws {
        for proofFails in [false, true] {
            let observer = makeObserver(legacyConfigured: true)
            let prove = SuspendedProve()
            var completions = 0
            let reservation = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
            let oldAttempt = Task { @MainActor in
                await observer.sessionInstaller.install(
                    reservation: reservation,
                    currentUserID: { self.boundAccount },
                    prove: { try await prove.prove(1) },
                    makeUploader: { _ in SessionTestUploader() },
                    makePuller: { _ in SessionTestPuller() },
                    periodicInterval: 0,
                    onSuccess: { _ in completions += 1 },
                    onFailure: { _ in completions += 1 },
                    onFlush: { completions += 1 }
                )
            }
            await prove.waitUntilStarted(1)
            let healthBefore = service.syncHealth

            // The SDK publishes T1 for the SAME UUID. No SwiftUI callback or
            // replacement reservation has run yet; T0 must already be stale.
            observer.sessionInstaller.authSessionWillChange(
                previousUserID: boundAccount, previousAccessToken: "synthetic-T0",
                userID: boundAccount, accessToken: "synthetic-T1"
            )
            if proofFails {
                await prove.fail(1, error: MemoSyncError.serverError(status: 503))
            } else {
                await prove.succeed(1, session: try makeSession(realm: boundRealm))
            }
            let oldInstalled = await oldAttempt.value
            XCTAssertFalse(oldInstalled)
            XCTAssertEqual(completions, 0)
            XCTAssertEqual(service.syncHealth, healthBefore)

            // The later view callback can reinstall the same realm without
            // rebinding or dropping the existing Vault/cursor.
            let refreshed = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
            let newInstalled = await observer.sessionInstaller.install(
                reservation: refreshed,
                currentUserID: { self.boundAccount },
                prove: { try self.makeSession(realm: self.boundRealm) },
                makeUploader: { _ in SessionTestUploader() },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0
            )
            XCTAssertTrue(newInstalled)
            observer.clearSession()
        }
    }

    func testExactDuplicateAuthSnapshotDoesNotStrandPendingInstall() async throws {
        let observer = makeObserver(legacyConfigured: true)
        let reservation = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        observer.sessionInstaller.authSessionWillChange(
            previousUserID: boundAccount, previousAccessToken: "synthetic-T0",
            userID: boundAccount, accessToken: "synthetic-T0"
        )
        let installed = await observer.sessionInstaller.install(
            reservation: reservation,
            currentUserID: { self.boundAccount },
            prove: { try self.makeSession(realm: self.boundRealm) },
            makeUploader: { _ in SessionTestUploader() },
            makePuller: { _ in SessionTestPuller() },
            periodicInterval: 0
        )
        XCTAssertTrue(installed)
        observer.clearSession()
    }

    func testCurrentAuthSnapshotChangeInvalidatesCompletion() async throws {
        let observer = makeObserver(legacyConfigured: true)
        let prove = SuspendedProve()
        // The live auth snapshot flips to another account while the proof for
        // the reserved attempt is suspended (delayed SwiftUI onChange gap).
        var currentUser: UUID? = boundAccount
        var successes = 0
        var failures = 0

        let reservation = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let task = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservation,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in SessionTestUploader() },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes += 1 },
                onFailure: { _ in failures += 1 }
            )
        }
        await prove.waitUntilStarted(1)
        currentUser = UUID()
        await prove.succeed(1, session: try makeSession(realm: boundRealm))

        let installed = await task.value
        XCTAssertFalse(installed)
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(failures, 0)
        observer.sessionInstaller.invalidateAllAttempts()
        observer.clearSession(rejectedConfiguration: true)
    }

    func testSignOutDuringProofCausesZeroMutations() async throws {
        let observer = makeObserver(legacyConfigured: true)
        let prove = SuspendedProve()
        var currentUser: UUID? = boundAccount
        var successes = 0
        var flushes = 0
        let uploader = SessionTestUploader()

        let reservation = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let task = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservation,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in uploader },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes += 1 },
                onFlush: { flushes += 1 }
            )
        }
        await prove.waitUntilStarted(1)

        // Explicit sign-out during the suspended proof (synchronous boundary).
        currentUser = nil
        observer.sessionInstaller.invalidateAllAttempts()
        observer.clearSession()

        await prove.succeed(1, session: try makeSession(realm: boundRealm))
        let installed = await task.value
        XCTAssertFalse(installed)
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(flushes, 0)
        XCTAssertFalse(observer.isConfigurationRejected)

        try seedPendingMemo()
        await observer.flush()
        let uploads = await uploader.count
        XCTAssertEqual(uploads, 0)
    }

    func testOverlappingSameUserInstallsKeepOnlyNewest() async throws {
        let observer = makeObserver(legacyConfigured: false)
        let prove = SuspendedProve()
        var currentUser: UUID? = boundAccount
        var successes: [Int] = []

        let uploader1 = SessionTestUploader()
        let reservation1 = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let task1 = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservation1,
                currentUserID: { currentUser },
                prove: { try await prove.prove(1) },
                makeUploader: { _ in uploader1 },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(1) }
            )
        }
        await prove.waitUntilStarted(1)

        let uploader2 = SessionTestUploader()
        let reservation2 = observer.sessionInstaller.reserve(expectedUserID: boundAccount)
        let task2 = Task { @MainActor in
            await observer.sessionInstaller.install(
                reservation: reservation2,
                currentUserID: { currentUser },
                prove: { try await prove.prove(2) },
                makeUploader: { _ in uploader2 },
                makePuller: { _ in SessionTestPuller() },
                periodicInterval: 0,
                onSuccess: { _ in successes.append(2) }
            )
        }
        await prove.waitUntilStarted(2)
        await prove.succeed(2, session: try makeSession(realm: boundRealm))
        _ = await task2.value
        // Duplicate/older same-UUID event resolves late.
        await prove.succeed(1, session: try makeSession(realm: boundRealm))
        let firstInstalled = await task1.value

        XCTAssertFalse(firstInstalled)
        XCTAssertEqual(successes, [2])
        try seedPendingMemo()
        await observer.flush()
        let uploads2 = await uploader2.count
        let uploads1 = await uploader1.count
        XCTAssertEqual(uploads2, 1)
        XCTAssertEqual(uploads1, 0)
        observer.clearSession()
    }

    // MARK: - Large-account pull drain (25+ pages)

    func testPageBudgetAndBusyInitialMergeIntoExactlyOneContinuation() async throws {
        let previousBound = SyncQueueObserver.maximumPagesPerFlushPass
        SyncQueueObserver.maximumPagesPerFlushPass = 2
        defer { SyncQueueObserver.maximumPagesPerFlushPass = previousBound }
        let observer = makeObserver(legacyConfigured: false)
        let puller = SequencedPagePuller(pages: 3, perPage: 1)
        try observer.configureSession(
            session: makeSession(realm: boundRealm), uploader: SessionTestUploader(), puller: puller, periodicInterval: 0
        )
        // Whichever MainActor pass starts first, the other full demand is
        // queued while it awaits a page. The bounded yield shares that slot.
        let initial = Task { await observer.flush(reason: .initial) }
        await observer.flush(reason: .manual)
        await initial.value
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if await puller.calls >= 3, !service.isFlushingNow { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<30 { await Task.yield() }
        let calls = await puller.calls
        XCTAssertEqual(calls, 3, "one page-budget continuation, without another already-drained pass")
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: boundRealm), 3)
        XCTAssertFalse(service.isFlushingNow)
        observer.clearSession()
    }

    func testObserverDrainsMoreThanTwentyPagesWithoutTruncation() async throws {
        // This account profile legitimately spans 25 pages; the old 20-page
        // cap failed mid-drain or reported a false completion.
        let puller = SequencedPagePuller(pages: 25, perPage: 2)
        let observer = makeObserver(legacyConfigured: false)
        try observer.configureSession(
            session: try makeSession(realm: boundRealm),
            uploader: SessionTestUploader(),
            puller: puller,
            periodicInterval: 0
        )
        await observer.flush()

        let calls = await puller.calls
        XCTAssertEqual(calls, 25)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: boundRealm), 50)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        observer.clearSession()
    }

    func testPageBoundReschedulesInsteadOfTruncatingOrFakingSuccess() async throws {
        let previousBound = SyncQueueObserver.maximumPagesPerFlushPass
        SyncQueueObserver.maximumPagesPerFlushPass = 2
        defer { SyncQueueObserver.maximumPagesPerFlushPass = previousBound }

        let puller = SequencedPagePuller(pages: 5, perPage: 1)
        let observer = makeObserver(legacyConfigured: false)
        try observer.configureSession(
            session: try makeSession(realm: boundRealm),
            uploader: SessionTestUploader(),
            puller: puller,
            periodicInterval: 0
        )

        // First pass stops at the bound with work still pending: it must NOT
        // report synced and must NOT truncate the drain.
        await observer.flush()
        XCTAssertNil(service.syncHealth.lastSuccessAt)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: boundRealm), 2)

        // Follow-up passes complete the drain; synced is reported only when
        // `hasMore` became false.
        await observer.flush()
        await observer.flush()
        let calls = await puller.calls
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: boundRealm), 5)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        observer.clearSession()
    }

    // MARK: - Rejection hold across invalid configuration

    func testRejectedVaultHoldsThroughInvalidConfigWithLegacyConfigured() async throws {
        try seedPendingMemo()
        let observer = makeObserver(legacyConfigured: true)
        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        XCTAssertTrue(observer.isConfigurationRejected)

        // RootView's invalid/missing-configuration path retains the rejection
        // instead of clearing it and reopening legacy upload.
        observer.clearSession(
            rejectedConfiguration: observer.isConfigurationRejected
        )
        observer.installConfiguredUploader()
        await observer.flush()

        XCTAssertTrue(observer.isConfigurationRejected)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        XCTAssertNil(service.syncHealth.lastSuccessAt)
    }

    // MARK: - Helpers

    private func makeRealm(user: UUID, origin: String) throws -> SyncRealmIdentity {
        try SyncRealmIdentity(
            originURL: XCTUnwrap(URL(string: origin)),
            userID: user
        )
    }

    private func makeSession(realm: SyncRealmIdentity) throws -> SyncSession {
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: "sb_test_key"
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: realm.userID,
            serverVerifiedAt: Date()
        )
        return SyncSession(context: context)
    }

    private func makeObserver(legacyConfigured: Bool) -> SyncQueueObserver {
        SyncQueueObserver(observeNotifications: false, syncQueue: service, legacyIsConfigured: { legacyConfigured })
    }

    private func seedPendingMemo() throws {
        let memo = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "synthetic session fixture")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
    }

    private func rejectBinding(_ observer: SyncQueueObserver, uploader: RemoteUploader, puller: RemotePuller) {
        XCTAssertThrowsError(
            try observer.configureSession(
                session: makeSession(realm: SyncRealmIdentity(
                    origin: boundRealm.origin,
                    userID: UUID()
                )),
                uploader: uploader,
                puller: puller,
                periodicInterval: 0
            )
        )
        // Match RootView's rejected-configuration cleanup and bounded failure.
        observer.clearSession(rejectedConfiguration: true)
        service.recordSyncFailure(stage: "preflight", code: "conflict", httpStatus: nil)
    }
}

private actor SuspendedProve {
    private var waits: [Int: CheckedContinuation<SyncSession, Error>] = [:]
    private var starts: [Int: CheckedContinuation<Void, Never>] = [:]

    func prove(_ id: Int) async throws -> SyncSession {
        try await withCheckedThrowingContinuation { continuation in
            waits[id] = continuation
            starts[id]?.resume()
            starts[id] = nil
        }
    }

    func waitUntilStarted(_ id: Int) async {
        if waits[id] != nil { return }
        await withCheckedContinuation { starts[id] = $0 }
    }

    func succeed(_ id: Int, session: SyncSession) {
        waits[id]?.resume(returning: session)
        waits[id] = nil
    }

    func fail(_ id: Int, error: Error) {
        waits[id]?.resume(throwing: error)
        waits[id] = nil
    }
}

/// Complete-empty account metadata explicitly injected by the session fakes:
/// an empty COMPLETE account (zero receipts, empty catalogue/links), never a
/// missing capability. Missing capability would mean "metadata unavailable"
/// and can never prove full completion.
private struct SessionEmptyMetadataReader: RemoteAccountTagsReader {
    func exactReceiptCount() async throws -> Int { 0 }
    func importMarkers() async throws -> [AccountTagImportMarker] { [] }
    func catalogueRows() async throws -> [AccountTagCatalogueRow] { [] }
    func linkRows() async throws -> [AccountTagLinkRow] { [] }
}

/// Deterministic multi-page remote change source for the pull drain tests.
private actor SequencedPagePuller: RemotePuller {
    nonisolated let accountTagsReader: RemoteAccountTagsReader? = SessionEmptyMetadataReader()
    private let pages: Int
    private let perPage: Int
    private(set) var calls = 0

    init(pages: Int, perPage: Int) {
        self.pages = pages
        self.perPage = perPage
    }

    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        calls += 1
        let page = min(calls, pages)
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
                device: "Mac A",
                source: "macos",
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

private actor SessionTestUploader: RemoteUploader {
    private(set) var count = 0
    private(set) var operations: [SyncOutboxOperation] = []
    func upload(operation: SyncOutboxOperation) async throws -> Int {
        count += 1
        operations.append(operation)
        return operation.sizeBytes
    }
}

private actor SessionTestPuller: RemotePuller {
    nonisolated let accountTagsReader: RemoteAccountTagsReader? = SessionEmptyMetadataReader()
    private(set) var count = 0
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        count += 1
        return SyncPullPage(changes: [], nextCursor: cursor, hasMore: false)
    }
}

private actor SuspendedSessionPuller: RemotePuller {
    nonisolated let accountTagsReader: RemoteAccountTagsReader? = SessionEmptyMetadataReader()
    private var pending: CheckedContinuation<SyncPullPage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        await withCheckedContinuation { continuation in
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

private actor SuspendedSessionUploader: RemoteUploader {
    private var pending: CheckedContinuation<Int, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func upload(operation: SyncOutboxOperation) async throws -> Int {
        await withCheckedContinuation { continuation in
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
        pending?.resume(returning: 0)
        pending = nil
    }
}
