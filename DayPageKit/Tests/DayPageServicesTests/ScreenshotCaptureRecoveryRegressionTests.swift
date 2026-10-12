import XCTest
import Foundation
import DayPageModels
import DayPageStorage
@testable import DayPageServices

// MARK: - Fixtures

private enum ReplayFixtures {
    static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
    static let otherPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="
    )!

    static func makeVault(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-replay-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func countFiles(under root: URL) -> Int {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: base, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }
        var count = 0
        while let item = enumerator.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}

private struct OkExtractor: ScreenshotEvidenceExtracting {
    func extract(from imageData: Data) async throws -> ScreenshotEvidence { ScreenshotEvidence() }
}

/// Controllable clock for the store's dedupe window.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(by seconds: TimeInterval) {
        lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
    }
}

/// Recording provider counting understand() calls.
private final class CountingProvider: ScreenshotUnderstandingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var providerInfo: ScreenshotProviderInfo {
        .init(kind: "test", model: "counting", promptVersion: "test")
    }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        lock.lock(); _calls += 1; lock.unlock()
        return ScreenshotUnderstandingResult(
            suggestedTitle: "t",
            kind: .other,
            summary: "s",
            visualDescription: "v",
            provider: .init(kind: "test", model: "counting", promptVersion: "test")
        )
    }
}

private final class MutableCaptureConsent: AIConsentChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func revoke() { lock.lock(); allowed = false; lock.unlock() }
    func authorize() throws {
        lock.lock(); let value = allowed; lock.unlock()
        if !value { throw AIAuthorizationError.aiDisabled }
    }
}

private struct RevokingCaptureProvider: ScreenshotUnderstandingProvider {
    let policy: MutableCaptureConsent
    var providerInfo: ScreenshotProviderInfo { .init(kind: "test", model: "test", promptVersion: "test") }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        policy.revoke()
        return ScreenshotUnderstandingResult(suggestedTitle: "synthetic", kind: .other,
            summary: "synthetic", visualDescription: "synthetic", provider: providerInfo)
    }
}

final class ScreenshotResultAdmissionTests: XCTestCase {
    func testAllowedSuccessBecomesReadyAndRetainsUnderstanding() async throws {
        let root = try ReplayFixtures.makeVault("admission-allowed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenshotCaptureStore(vaultRoot: root)
        let provider = CountingProvider()
        let coordinator = ScreenshotCaptureCoordinator(store: store,
            evidenceExtractor: OkExtractor(), understandingProvider: provider,
            cloudConsent: AllowAllAIConsent())
        let outcome = try await coordinator.ingest(data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png", source: .appImport, cloudAnalysisAllowed: true)
        await coordinator.processPending(cloudAnalysisAllowed: true)
        let result = try await store.manifest(for: outcome.manifest.id)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(result.phase, .ready)
        XCTAssertEqual(result.understanding?.suggestedTitle, "t")
    }

    func testLiveRevocationDiscardsSuccessWithoutEpochNotification() async throws {
        let root = try ReplayFixtures.makeVault("admission-revoked")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = MutableCaptureConsent()
        let store = ScreenshotCaptureStore(vaultRoot: root)
        let coordinator = ScreenshotCaptureCoordinator(store: store,
            evidenceExtractor: OkExtractor(), understandingProvider: RevokingCaptureProvider(policy: policy),
            cloudConsent: policy)
        let outcome = try await coordinator.ingest(data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png", source: .appImport, cloudAnalysisAllowed: true)
        await coordinator.processPending(cloudAnalysisAllowed: true)
        let result = try await store.manifest(for: outcome.manifest.id)
        XCTAssertEqual(result.phase, .localOnly)
        XCTAssertNil(result.understanding)
    }
}

/// Gate awaited during the coordinator's PREFLIGHT window (after reservation,
/// before any provider request) so overlapping contenders are deterministic.
private final class PreflightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func hold() async {
        lock.lock()
        if released { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                c.resume()
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func releaseAll() {
        lock.lock()
        released = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

// MARK: - Suites

/// Independent-review P1 (share handoff replay): the staged item's stable UUID
/// is the durable capture identity. A crash after durable ingest but before
/// inbox removal must replay into the SAME capture/memo/original — even beyond
/// the 30-second digest window — while changed payloads and key misuse are
/// rejected outright.
@MainActor
final class ScreenshotShareReplayRegressionTests: XCTestCase {
    private var vault: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        vault = try ReplayFixtures.makeVault("share")
        previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousOverride
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    private func makeCoordinator(store: ScreenshotCaptureStore) -> ScreenshotCaptureCoordinator {
        ScreenshotCaptureCoordinator(
            store: store,
            evidenceExtractor: OkExtractor(),
            understandingProvider: nil,
            cloudConsent: AllowAllAIConsent()
        )
    }

    func testReplayBeyondDedupeWindowReusesCaptureMemoAndOriginal() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = ScreenshotCaptureStore(vaultRoot: vault, now: { clock.now })
        let coordinator = makeCoordinator(store: store)
        let itemID = UUID()

        let first = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: false,
            stableID: itemID
        )
        XCTAssertFalse(first.isDuplicate)
        let filesAfterFirst = ReplayFixtures.countFiles(under: vault)

        // Crash after durable capture+memo, BEFORE inbox removal. Replay
        // happens 60+ seconds later (outside the digest window) — possibly on
        // another day. The stable identity must win over time-based dedupe.
        clock.advance(by: 120)
        let replay = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: false,
            stableID: itemID
        )

        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.manifest.id, first.manifest.id)
        XCTAssertEqual(replay.manifest.memoID, first.manifest.memoID)
        XCTAssertEqual(ReplayFixtures.countFiles(under: vault), filesAfterFirst, "zero second original/manifest")

        let memos = try RawStorage.read(dayString: first.manifest.memoDayString, vaultRoot: vault)
        XCTAssertEqual(memos.filter { $0.id == first.manifest.memoID }.count, 1, "zero second memo")
    }

    func testReplayAfterCrashBeforeMemoAppendStillDeliversExactlyOneMemo() async throws {
        // Crash between manifest durability and memo append: the replay must
        // reconcile the memo (idempotent by memo UUID), not duplicate it.
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = ScreenshotCaptureStore(vaultRoot: vault, now: { clock.now })
        let coordinator = makeCoordinator(store: store)
        let itemID = UUID()

        let first = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: false,
            stableID: itemID
        )
        // Simulate the pre-memo crash: remove the memo but keep manifest+original.
        try RawStorage.mutate(
            dayString: first.manifest.memoDayString,
            vaultRoot: vault,
            transform: { memos in memos.filter { $0.id != first.manifest.memoID } }
        )
        clock.advance(by: 120)
        let replay = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: false,
            stableID: itemID
        )

        XCTAssertEqual(replay.manifest.id, first.manifest.id)
        let memos = try RawStorage.read(dayString: first.manifest.memoDayString, vaultRoot: vault)
        XCTAssertEqual(memos.filter { $0.id == first.manifest.memoID }.count, 1, "replay reconciles exactly one memo")
    }

    func testReplayWithChangedPayloadIsRejected() async throws {
        let store = ScreenshotCaptureStore(vaultRoot: vault)
        let coordinator = makeCoordinator(store: store)
        let itemID = UUID()

        _ = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: false,
            stableID: itemID
        )
        do {
            _ = try await coordinator.ingest(
                data: ReplayFixtures.otherPNG,
                declaredContentType: "image/png",
                source: .shareExtension,
                cloudAnalysisAllowed: false,
                stableID: itemID
            )
            XCTFail("a reused identity with different bytes must be rejected")
        } catch {
            XCTAssertEqual(error as? ScreenshotCaptureError, .stableIDConflict)
        }
    }

    func testReplayWithSourceMisuseIsRejected() async throws {
        let store = ScreenshotCaptureStore(vaultRoot: vault)
        let coordinator = makeCoordinator(store: store)
        let itemID = UUID()

        _ = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: false,
            stableID: itemID
        )
        do {
            _ = try await coordinator.ingest(
                data: ReplayFixtures.onePixelPNG,
                declaredContentType: "image/png",
                source: .actionButtonShortcut,
                cloudAnalysisAllowed: false,
                stableID: itemID
            )
            XCTFail("a reused identity with a different source must be rejected")
        } catch {
            XCTAssertEqual(error as? ScreenshotCaptureError, .stableIDConflict)
        }
    }
}

/// Independent-review P1 (single-flight preflight): the in-flight reservation
/// must be taken by (resolved Vault root, capture ID) BEFORE the first awaited
/// preflight step, so two overlapping recovery/retry passes cannot both reach
/// the provider. A copied capture UUID in two vaults stays independent.
@MainActor
final class ScreenshotPreflightReservationTests: XCTestCase {
    private var vault: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        vault = try ReplayFixtures.makeVault("preflight")
        previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousOverride
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testOverlappingPreflightsProduceExactlyOneProviderRequest() async throws {
        let gate = PreflightGate()
        let provider = CountingProvider()
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: OkExtractor(),
            understandingProvider: provider,
            cloudConsent: AllowAllAIConsent(),
            preflightGate: { await gate.hold() }
        )
        let outcome = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: true
        )

        // Two overlapping contenders (foreground pass + retry), both parked
        // inside preflight BEFORE either provider request starts.
        let firstPass = Task { @MainActor in
            await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        }
        let secondPass = Task { @MainActor in
            await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        }
        // Let both contenders reach the preflight gate.
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.releaseAll()
        _ = await firstPass.value
        _ = await secondPass.value

        let count = provider.calls
        XCTAssertEqual(count, 1, "exactly one provider request despite overlapping preflights")
    }

    func testCopiedCaptureUUIDInTwoVaultsProcessesIndependently() async throws {
        let vaultA = try ReplayFixtures.makeVault("vaultA")
        let vaultB = try ReplayFixtures.makeVault("vaultB")
        defer {
            try? FileManager.default.removeItem(at: vaultA)
            try? FileManager.default.removeItem(at: vaultB)
        }
        let itemID = UUID()  // same stable capture identity copied into both vaults
        let providerA = CountingProvider()
        let providerB = CountingProvider()
        let storeA = ScreenshotCaptureStore(vaultRoot: vaultA)
        let storeB = ScreenshotCaptureStore(vaultRoot: vaultB)
        let coordinatorA = ScreenshotCaptureCoordinator(
            store: storeA,
            evidenceExtractor: OkExtractor(),
            understandingProvider: providerA,
            cloudConsent: AllowAllAIConsent()
        )
        let coordinatorB = ScreenshotCaptureCoordinator(
            store: storeB,
            evidenceExtractor: OkExtractor(),
            understandingProvider: providerB,
            cloudConsent: AllowAllAIConsent()
        )

        _ = try await coordinatorA.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: true,
            stableID: itemID
        )
        _ = try await coordinatorB.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .shareExtension,
            cloudAnalysisAllowed: true,
            stableID: itemID
        )
        await coordinatorA.retry(captureID: itemID, cloudAnalysisAllowed: true)
        await coordinatorB.retry(captureID: itemID, cloudAnalysisAllowed: true)

        let countA = providerA.calls
        let countB = providerB.calls
        XCTAssertEqual(countA, 1, "vault A must not be suppressed by vault B's copy")
        XCTAssertEqual(countB, 1, "vault B must not be suppressed by vault A's copy")
    }
}

/// Independent-review P1 (undo finalization): a cancelled finalization (Undo
/// accepted while finalization runs) must not delete the original/manifest,
/// and a closed deletion never resurrects deleted files.
final class ScreenshotDeletionFinalizationTests: XCTestCase {

    func testCancellationBeforeDeletionPreservesOriginalAndManifest() async throws {
        let vault = try ReplayFixtures.makeVault("finalize")
        defer { try? FileManager.default.removeItem(at: vault) }
        let gate = PreflightGate()
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: OkExtractor(),
            understandingProvider: nil,
            cloudConsent: AllowAllAIConsent(),
            finalizeGate: { await gate.hold() }
        )
        _ = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        // The memo is deleted (deleteUndoTask path), then finalization starts
        // and parks at the gate. The user accepts Undo during that window —
        // the task is cancelled, and the finalizer must honor cancellation
        // BEFORE the irreversible deletion.
        let manifests = try await ScreenshotCaptureStore(vaultRoot: vault).allManifests()
        let manifest = try XCTUnwrap(manifests.first)
        try RawStorage.mutate(
            dayString: manifest.memoDayString,
            vaultRoot: vault,
            transform: { memos in memos.filter { $0.id != manifest.memoID } }
        )

        let finalization = Task {
            try await coordinator.finalizeDeletionIfMemoMissing(
                captureID: manifest.id,
                vaultRoot: vault
            )
        }
        // Wait for the finalizer to reach the gate, then cancel (Undo).
        try await Task.sleep(nanoseconds: 100_000_000)
        finalization.cancel()
        gate.releaseAll()
        _ = try? await finalization.value

        // Undo restored the raw memo in the meantime; the cancelled finalizer
        // must not have removed the original or the manifest.
        let reader = ScreenshotCaptureStore(vaultRoot: vault)
        let surviving = try await reader.manifest(for: manifest.id)
        XCTAssertEqual(surviving.id, manifest.id)
        let original = try await reader.originalData(for: manifest.id)
        XCTAssertEqual(original, ReplayFixtures.onePixelPNG)
    }

    func testFinalizationAfterOwnershipClosedDeletesFiles() async throws {
        // Positive control: without an accepted Undo (no cancellation) the
        // finalizer removes the original and manifest after the memo is gone.
        let vault = try ReplayFixtures.makeVault("finalize2")
        defer { try? FileManager.default.removeItem(at: vault) }
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: OkExtractor(),
            understandingProvider: nil,
            cloudConsent: AllowAllAIConsent()
        )
        _ = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        let manifests = try await ScreenshotCaptureStore(vaultRoot: vault).allManifests()
        let manifest = try XCTUnwrap(manifests.first)
        try RawStorage.mutate(
            dayString: manifest.memoDayString,
            vaultRoot: vault,
            transform: { memos in memos.filter { $0.id != manifest.memoID } }
        )

        try await coordinator.finalizeDeletionIfMemoMissing(
            captureID: manifest.id,
            vaultRoot: vault
        )

        let reader = ScreenshotCaptureStore(vaultRoot: vault)
        do {
            _ = try await reader.manifest(for: manifest.id)
            XCTFail("finalization with the memo gone must remove the manifest")
        } catch {
            XCTAssertEqual(error as? ScreenshotCaptureError, .manifestMissing)
        }
    }
}

// MARK: - Local evidence prerequisite (root review finding 7)

/// Local evidence extraction is a REQUIRED step before any cloud request.
/// A capture whose extraction failed (evidence still nil) must never reach the
/// provider on process/retry, while the original and the retryable local
/// failure state stay durable.
@MainActor
final class ScreenshotEvidencePrerequisiteTests: XCTestCase {
    private var vault: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        vault = try ReplayFixtures.makeVault("evidence")
        previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousOverride
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testFailedLocalEvidenceNeverReachesTheProvider() async throws {
        struct ThrowingExtractor: ScreenshotEvidenceExtracting {
            func extract(from imageData: Data) async throws -> ScreenshotEvidence {
                throw URLError(.cannotDecodeContentData)
            }
        }
        let provider = CountingProvider()
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: ThrowingExtractor(),
            understandingProvider: provider,
            cloudConsent: AllowAllAIConsent()
        )
        let outcome = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: true
        )
        XCTAssertEqual(outcome.manifest.phase, .failed)
        XCTAssertEqual(outcome.manifest.failureReason, "local-evidence-failed")
        XCTAssertNil(outcome.manifest.evidence)

        // Repeated retries keep failing locally and never upload.
        _ = await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        _ = await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        XCTAssertEqual(provider.calls, 0, "no send without successful local evidence")

        // The failure stays retryable and the original stays durable.
        let reader = ScreenshotCaptureStore(vaultRoot: vault)
        let manifest = try await reader.manifest(for: outcome.manifest.id)
        XCTAssertEqual(manifest.phase, .failed, "local failure remains retryable")
        XCTAssertNil(manifest.evidence)
        let original = try await reader.originalData(for: outcome.manifest.id)
        XCTAssertEqual(original, ReplayFixtures.onePixelPNG)
    }

    func testInterruptedLegacyStateIsNotMarkedIngestedWithoutMemo() async throws {
        // A legacy sidecar in `stored` phase with NO raw memo anywhere must
        // stay put on recovery — never marked ingested/queued without the memo
        // append actually landing.
        let store = ScreenshotCaptureStore(vaultRoot: vault)
        let coordinator = ScreenshotCaptureCoordinator(
            store: store,
            evidenceExtractor: OkExtractor(),
            understandingProvider: nil,
            cloudConsent: AllowAllAIConsent()
        )
        let outcome = try await coordinator.ingest(
            data: ReplayFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        // Simulate the interrupted legacy state: raw memo removed and the
        // sidecar downgraded to `stored` without the day key.
        try RawStorage.mutate(
            dayString: outcome.manifest.memoDayString,
            vaultRoot: vault,
            transform: { memos in memos.filter { $0.id != outcome.manifest.memoID } }
        )
        try rewriteLegacySidecar(in: vault, manifest: outcome.manifest, phase: .stored)

        await coordinator.processPending(cloudAnalysisAllowed: false)

        let reader = ScreenshotCaptureStore(vaultRoot: vault)
        let manifest = try await reader.manifest(for: outcome.manifest.id)
        XCTAssertEqual(manifest.phase, .stored, "no memo appended ⇒ never marked ingested")
    }

    private func rewriteLegacySidecar(
        in vault: URL,
        manifest: ScreenshotCaptureManifest,
        phase: ScreenshotCapturePhase
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var value = manifest
        value.phase = phase
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(value)
        ) as? [String: Any] ?? [:]
        object.removeValue(forKey: "memoDayString")
        let url = vault.appendingPathComponent(
            "raw/assets/.screenshot-captures/\(manifest.id.uuidString.lowercased()).json"
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
