import XCTest
import Foundation
import DayPageModels
import DayPageStorage
@testable import DayPageServices

// Regression suite for the recovered screenshot pipeline hardening:
// single-Vault binding, stale consent invalidation, crash-phase recovery,
// manifest path containment, strict provider schema closure, QA inbox
// namespace isolation, preferred-time-zone grouping, and canonical photo
// attachment kind. Synthetic 1x1 PNG fixtures only; no vault, provider,
// network, or credential dependencies.

// MARK: - Shared fixtures

private enum RecoveryFixtures {
    static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    static func makeVault(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-screenshot-recovery-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Walks every regular file below `root` (relative paths). The temporary
    /// directory is a symlink on macOS, so both sides are canonicalized.
    static func allFiles(under root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: base, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                let path = item.resolvingSymlinksInPath().standardizedFileURL.path
                if path.hasPrefix(base + "/") {
                    found.append(String(path.dropFirst(base.count + 1)))
                }
            }
        }
        return found.sorted()
    }

    static func manifestJSONURL(in vault: URL, captureID: UUID) -> URL {
        vault.appendingPathComponent("raw/assets/.screenshot-captures/\(captureID.uuidString.lowercased()).json")
    }
}

private actor RecoveryExtractorGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        entered = true
        for waiter in waiters { waiter.resume() }
        waiters = []
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        // Bounded wait: a preflight failure before the gated seam must fail the
        // test promptly instead of parking xctest forever.
        let deadline = Date().addingTimeInterval(10)
        while !entered && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !entered {
            XCTFail("Extractor gate never entered — an earlier preflight step failed")
            release()
        }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private struct GatedExtractor: ScreenshotEvidenceExtracting {
    let gate: RecoveryExtractorGate
    let evidence: ScreenshotEvidence
    func extract(from imageData: Data) async throws -> ScreenshotEvidence {
        await gate.run()
        return evidence
    }
}

private actor RecoveryProviderGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        entered = true
        for waiter in waiters { waiter.resume() }
        waiters = []
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        // Bounded wait: a preflight failure before the provider seam must fail
        // the test promptly instead of parking xctest forever.
        let deadline = Date().addingTimeInterval(10)
        while !entered && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !entered {
            XCTFail("Provider gate never entered — an earlier preflight step failed")
            release()
        }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private struct GatedProvider: ScreenshotUnderstandingProvider {
    let gate: RecoveryProviderGate
    var providerInfo: ScreenshotProviderInfo {
        .init(kind: "test", model: "gated", promptVersion: "test")
    }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        await gate.run()
        return ScreenshotUnderstandingResult(
            suggestedTitle: "标题",
            kind: .other,
            summary: "摘要",
            visualDescription: "描述",
            provider: providerInfo
        )
    }
}

private struct NeverCalledProvider: ScreenshotUnderstandingProvider {
    var providerInfo: ScreenshotProviderInfo {
        .init(kind: "test", model: "never", promptVersion: "test")
    }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        XCTFail("Provider must not be requested after consent revocation")
        throw ScreenshotUnderstandingProviderError.invalidResponse
    }
}

private struct EmptyEvidenceExtractor: ScreenshotEvidenceExtracting {
    func extract(from imageData: Data) async throws -> ScreenshotEvidence { ScreenshotEvidence() }
}

// MARK: - Vault binding (review finding 1)

final class ScreenshotVaultBindingTests: XCTestCase {
    private var vaultA: URL!
    private var vaultB: URL!

    override func setUpWithError() throws {
        vaultA = try RecoveryFixtures.makeVault("vault-a")
        vaultB = try RecoveryFixtures.makeVault("vault-b")
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vaultA { try? FileManager.default.removeItem(at: vaultA) }
        if let vaultB { try? FileManager.default.removeItem(at: vaultB) }
    }

    /// A vault-root switch while local extraction is suspended must not split
    /// the operation across vaults: original, manifest and memo all stay in
    /// the vault captured when the ingest began.
    func testIngestStaysInOneCapturedVaultAcrossMidWorkRootSwitch() async throws {
        VaultInitializer.testOverrideURL = vaultA
        let gate = RecoveryExtractorGate()
        let store = ScreenshotCaptureStore()
        let coordinator = ScreenshotCaptureCoordinator(
            store: store,
            evidenceExtractor: GatedExtractor(gate: gate, evidence: ScreenshotEvidence()),
            understandingProvider: NeverCalledProvider()
        )

        let task = Task {
            try await coordinator.ingest(
                data: RecoveryFixtures.onePixelPNG,
                declaredContentType: "image/png",
                source: .appImport,
                cloudAnalysisAllowed: true
            )
        }
        await gate.waitUntilEntered()
        VaultInitializer.testOverrideURL = vaultB
        await gate.release()
        let outcome = try await task.value

        XCTAssertEqual(
            RecoveryFixtures.allFiles(under: vaultB), [],
            "Vault switch mid-work must not write into the new vault"
        )
        let files = RecoveryFixtures.allFiles(under: vaultA)
        XCTAssertTrue(files.contains { $0.hasPrefix("raw/assets/screenshots/") && $0.hasSuffix(".png") }, "files: \(files)")
        XCTAssertTrue(files.contains { $0.hasPrefix("raw/assets/.screenshot-captures/") && $0.hasSuffix(".json") }, "files: \(files)")
        XCTAssertTrue(files.contains { $0.hasPrefix("raw/") && $0.hasSuffix(".md") }, "files: \(files)")
        // Cloud analysis allowed and no local risk flags: work is queued for
        // the optional understanding pass, never sent from ingest itself.
        XCTAssertEqual(outcome.manifest.phase, .queued)
        XCTAssertNotNil(outcome.manifest.evidence)
    }

    /// Delete finalization must evaluate "is the memo still missing?" in the
    /// same vault it would delete files from. A root switch after the delete
    /// began must never destroy a capture whose memo still exists.
    func testFinalizeDeletionNeverDeletesAcrossVaultBoundary() async throws {
        VaultInitializer.testOverrideURL = vaultA
        let store = ScreenshotCaptureStore(vaultRoot: vaultA)
        let coordinator = ScreenshotCaptureCoordinator(
            store: store,
            evidenceExtractor: EmptyEvidenceExtractor(),
            understandingProvider: NeverCalledProvider()
        )
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        let captureID = outcome.manifest.id
        let originalRelative = outcome.manifest.originalPath
        let originalURL = vaultA.appendingPathComponent(originalRelative)

        // The vault root changes (migration / locator swap) while the undo
        // window is open. The memo still exists in the capture's own vault.
        VaultInitializer.testOverrideURL = vaultB
        try? await coordinator.finalizeDeletionIfMemoMissing(captureID: captureID)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: originalURL.path),
            "Memo present in the capture's vault: files must survive a root switch"
        )

        // With the memo genuinely gone from the capture's vault, the same
        // call removes exactly this capture's files.
        try RawStorage.mutate(
            for: outcome.manifest.createdAt,
            vaultRoot: vaultA,
            transform: { memos in
                let updated = memos.filter { $0.id != outcome.manifest.memoID }
                return updated.count == memos.count ? nil : updated
            }
        )
        try? await coordinator.finalizeDeletionIfMemoMissing(captureID: captureID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalURL.path),
            "Files are removed only when the owning vault really lost the memo"
        )
    }
}

// MARK: - Stale consent / provider completion (review finding 2)

final class ScreenshotConsentRevocationTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = try RecoveryFixtures.makeVault("consent")
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    private func makeCoordinator(provider: any ScreenshotUnderstandingProvider) -> ScreenshotCaptureCoordinator {
        ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: EmptyEvidenceExtractor(),
            understandingProvider: provider,
            // Explicit policy: this suite's subject is epoch/durable-consent
            // behavior. Live-toggle gating is covered by
            // ScreenshotConsentBoundaryTests with isolated policies.
            cloudConsent: AllowAllAIConsent()
        )
    }

    func testKeepLocalDuringProviderFlightDiscardsStaleCompletion() async throws {
        let gate = RecoveryProviderGate()
        let coordinator = makeCoordinator(provider: GatedProvider(gate: gate))
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: true
        )
        let captureID = outcome.manifest.id
        XCTAssertEqual(outcome.manifest.phase, .queued)

        let task = Task { await coordinator.processPending(cloudAnalysisAllowed: true) }
        await gate.waitUntilEntered()
        try await coordinator.keepLocal(captureID: captureID)
        await gate.release()
        await task.value

        let manifest = try await coordinator.manifest(forMemoID: outcome.manifest.memoID)
        XCTAssertEqual(manifest?.phase, .localOnly, "A keep-local during flight must stay local-only")
        XCTAssertNil(manifest?.understanding, "A stale provider completion must be discarded")
    }

    func testGlobalCloudDisableDuringProviderFlightDiscardsStaleCompletion() async throws {
        let gate = RecoveryProviderGate()
        let coordinator = makeCoordinator(provider: GatedProvider(gate: gate))
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: true
        )
        XCTAssertEqual(outcome.manifest.phase, .queued)

        let task = Task { await coordinator.processPending(cloudAnalysisAllowed: true) }
        await gate.waitUntilEntered()
        // The user turns screenshot cloud analysis off while the request is in
        // flight. No new request may start and the late response is discarded.
        await coordinator.processPending(cloudAnalysisAllowed: false)
        await gate.release()
        await task.value

        let manifest = try await coordinator.manifest(forMemoID: outcome.manifest.memoID)
        XCTAssertEqual(manifest?.phase, .localOnly)
        XCTAssertNil(manifest?.understanding)
    }

    func testDurableConsentClearedMeansNoFurtherProviderRequest() async throws {
        let coordinator = makeCoordinator(provider: NeverCalledProvider())
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: true
        )
        try await coordinator.keepLocal(captureID: outcome.manifest.id)
        // A later foreground pass with the global switch on must not re-request
        // a capture whose durable consent snapshot was cleared.
        let result = await coordinator.retry(captureID: outcome.manifest.id, cloudAnalysisAllowed: true)
        XCTAssertEqual(result?.phase, .localOnly)
    }
}

// MARK: - Crash phase recovery and exactly-one memo (review finding 3)

final class ScreenshotCrashRecoveryTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = try RecoveryFixtures.makeVault("crash")
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    private func makeCoordinator(provider: (any ScreenshotUnderstandingProvider)? = nil) -> ScreenshotCaptureCoordinator {
        ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: EmptyEvidenceExtractor(),
            understandingProvider: provider,
            // Explicit policy: this suite's subject is crash-phase recovery,
            // not the live toggle (covered by ScreenshotConsentBoundaryTests).
            cloudConsent: AllowAllAIConsent()
        )
    }

    private func memos(for manifest: ScreenshotCaptureManifest, in vault: URL) throws -> [Memo] {
        try RawStorage.read(dayString: manifest.memoDayString, vaultRoot: vault)
    }

    func testStoredPhaseAfterCrashBeforeMemoAppendRecoversExactlyOneMemo() async throws {
        let coordinator = makeCoordinator(provider: NeverCalledProvider())
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: false
        )
        let captureID = outcome.manifest.id

        // Simulate the crash window between manifest durability and memo
        // append: manifest back to `stored`, memo absent.
        try RawStorage.mutate(
            dayString: outcome.manifest.memoDayString,
            vaultRoot: vault,
            transform: { memos in
                memos.filter { $0.id != outcome.manifest.memoID }
            }
        )
        _ = try await storeUpdate(captureID) { $0.phase = .stored; $0.evidence = nil }

        await coordinator.processPending(cloudAnalysisAllowed: false)
        let afterFirst = try memos(for: outcome.manifest, in: vault)
        XCTAssertEqual(afterFirst.filter { $0.id == outcome.manifest.memoID }.count, 1)

        // Re-running recovery (second foreground pass) stays exactly-once.
        await coordinator.processPending(cloudAnalysisAllowed: false)
        let afterSecond = try memos(for: outcome.manifest, in: vault)
        XCTAssertEqual(afterSecond.filter { $0.id == outcome.manifest.memoID }.count, 1)

        let manifest = try await coordinator.manifest(forMemoID: outcome.manifest.memoID)
        XCTAssertEqual(manifest?.phase, .localOnly)
    }

    func testStoredPhaseAfterCrashBeforePhaseUpdateNeverDuplicatesMemo() async throws {
        let coordinator = makeCoordinator(provider: NeverCalledProvider())
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: false
        )
        // Simulate a crash right after the memo append but before the phase
        // update: manifest `stored`, memo already durable.
        _ = try await storeUpdate(outcome.manifest.id) { $0.phase = .stored }

        await coordinator.processPending(cloudAnalysisAllowed: false)
        let memos = try self.memos(for: outcome.manifest, in: vault)
        XCTAssertEqual(memos.filter { $0.id == outcome.manifest.memoID }.count, 1)
    }

    func testExtractingCrashStateRecoversEvidence() async throws {
        let coordinator = makeCoordinator(provider: NeverCalledProvider())
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        // Crash mid local-extraction: phase stuck at `extracting`, evidence lost.
        _ = try await storeUpdate(outcome.manifest.id) { $0.phase = .extracting; $0.evidence = nil }

        await coordinator.processPending(cloudAnalysisAllowed: false)
        let manifest = try await coordinator.manifest(forMemoID: outcome.manifest.memoID)
        XCTAssertNotNil(manifest?.evidence, "Stuck extracting state must re-run local extraction")
        XCTAssertEqual(manifest?.phase, .localOnly)
    }

    func testUnderstandingCrashStateRecoversWithoutNewRequestWhenConsentOff() async throws {
        let coordinator = makeCoordinator(provider: NeverCalledProvider())
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        // Crash left the phase at `understanding` with no in-flight work.
        _ = try await storeUpdate(outcome.manifest.id) { $0.phase = .understanding }

        await coordinator.processPending(cloudAnalysisAllowed: false)
        let manifest = try await coordinator.manifest(forMemoID: outcome.manifest.memoID)
        XCTAssertEqual(manifest?.phase, .localOnly, "Stuck understanding state must not stay stuck")
        XCTAssertNil(manifest?.understanding)
    }

    func testConcurrentIngestsDeliverExactlyOneMemo() async throws {
        let coordinator = makeCoordinator(provider: NeverCalledProvider())
        let data = RecoveryFixtures.onePixelPNG
        async let first = coordinator.ingest(
            data: data, declaredContentType: "image/png", source: .appImport, cloudAnalysisAllowed: false
        )
        async let second = coordinator.ingest(
            data: data, declaredContentType: "image/png", source: .appImport, cloudAnalysisAllowed: false
        )
        let outcomes = try await [first, second]
        let duplicateCount = outcomes.filter(\.isDuplicate).count
        XCTAssertEqual(duplicateCount, 1, "Concurrent identical captures must collapse to one capture")

        let manifest = outcomes[0].isDuplicate ? outcomes[1].manifest : outcomes[0].manifest
        let memos = try self.memos(for: manifest, in: vault)
        XCTAssertEqual(memos.filter { $0.id == manifest.memoID }.count, 1)
    }

    private func storeUpdate(
        _ captureID: UUID,
        _ mutate: @escaping (inout ScreenshotCaptureManifest) -> Void
    ) async throws -> ScreenshotCaptureManifest {
        let store = ScreenshotCaptureStore(vaultRoot: vault)
        return try await store.update(captureID, mutate: mutate)
    }
}

// MARK: - Manifest path containment (review finding 4)

final class ScreenshotManifestPathSafetyTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = try RecoveryFixtures.makeVault("paths")
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    private func ingest(store: ScreenshotCaptureStore) async throws -> ScreenshotCaptureManifest {
        let outcome = try await store.receive(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudConsentAtCapture: false
        )
        return outcome.manifest
    }

    private func tamper(originalPath: String, for captureID: UUID) throws {
        let url = RecoveryFixtures.manifestJSONURL(in: vault, captureID: captureID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(
            ScreenshotCaptureManifest.self,
            from: try Data(contentsOf: url)
        )
        manifest.originalPath = originalPath
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url)
    }

    func testTamperedManifestPathsCannotReadOrDeleteVaultFiles() async throws {
        let store = ScreenshotCaptureStore(vaultRoot: vault)
        let manifest = try await ingest(store: store)

        let outside = vault.appendingPathComponent("raw/outside.md")
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("outside-content".utf8).write(to: outside)

        for path in ["raw/outside.md", "raw/assets/screenshots/../../outside.md", "/raw/outside.md"] {
            try tamper(originalPath: path, for: manifest.id)
            do {
                _ = try await store.originalData(for: manifest.id)
                XCTFail("Tampered path \(path) must not read outside the screenshots boundary")
            } catch {
                XCTAssertEqual(error as? ScreenshotCaptureError, .invalidPath)
            }
            do {
                try await store.deleteFiles(for: manifest.id)
                XCTFail("Tampered path \(path) must not delete outside the screenshots boundary")
            } catch {
                XCTAssertEqual(error as? ScreenshotCaptureError, .invalidPath)
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: outside.path),
                "Unrelated vault file must survive tampered manifests"
            )
        }
    }

    func testSymlinkedOriginalCannotReadOrDeleteOutsideTarget() async throws {
        let store = ScreenshotCaptureStore(vaultRoot: vault)
        let manifest = try await ingest(store: store)

        let outside = vault.appendingPathComponent("raw/outside.png")
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("outside-bytes".utf8).write(to: outside)

        let link = vault.appendingPathComponent(manifest.originalPath)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            _ = try await store.originalData(for: manifest.id)
            XCTFail("Symlinked original must not read an outside target")
        } catch {
            XCTAssertEqual(error as? ScreenshotCaptureError, .invalidPath)
        }
        try? await store.deleteFiles(for: manifest.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path),
            "Deleting a capture must never delete a symlink target outside the boundary"
        )
    }
}

// MARK: - Strict provider schema (review finding 5)

final class ScreenshotProviderSchemaTests: XCTestCase {
    private func assertClosed(_ node: [String: Any], path: String) throws {
        if let type = node["type"] as? String, type == "object" {
            XCTAssertEqual(
                node["additionalProperties"] as? Bool, false,
                "Object at \(path) must set additionalProperties=false"
            )
            let properties = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            XCTAssertEqual(
                required, Set(properties.keys),
                "Object at \(path) must require every property"
            )
            for (key, value) in properties {
                if let child = value as? [String: Any] {
                    try assertClosed(child, path: "\(path).\(key)")
                }
            }
        }
        if let type = node["type"] as? String, type == "array" {
            if let items = node["items"] as? [String: Any] {
                try assertClosed(items, path: "\(path)[]")
            }
        }
    }

    func testProviderOutputSchemaIsStrictlyClosedAtEveryLevel() throws {
        try assertClosed(OpenAIScreenshotUnderstandingProvider.outputSchema, path: "root")
    }

    private func object(_ value: Any?, _ label: String) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any], label)
    }

    func testDraftFieldsUseClosedEntryArrayOnTheWire() throws {
        let root = try object(OpenAIScreenshotUnderstandingProvider.outputSchema["properties"], "root properties")
        let suggestedActions = try object(root["suggestedActions"], "suggestedActions")
        let items = try object(suggestedActions["items"], "suggestedActions.items")
        let properties = try object(items["properties"], "items.properties")
        let draftFields = try object(properties["draftFields"], "draftFields")
        XCTAssertEqual(draftFields["type"] as? String, "array", "draftFields must be a closed entry array")
        let entry = try object(draftFields["items"], "draftFields.items")
        XCTAssertEqual(entry["additionalProperties"] as? Bool, false)
    }
}

// MARK: - QA inbox namespace isolation (review finding 8)

private final class RecordingInboxFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var lookups = 0
    var lookupCount: Int { lock.lock(); defer { lock.unlock() }; return lookups }
    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        lock.lock(); lookups += 1; lock.unlock()
        return FileManager.default.temporaryDirectory.appendingPathComponent("unused-inbox-\(UUID().uuidString)")
    }
}

final class ScreenshotShareInboxNamespaceTests: XCTestCase {
    func testQAIdentitiesNeverResolveProductionGroup() {
        XCTAssertEqual(
            ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-unit"),
            "group.com.daypage.qa-unit"
        )
        XCTAssertEqual(
            ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-ui"),
            "group.com.daypage.qa-ui"
        )
        XCTAssertEqual(
            ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-unit.share"),
            "group.com.daypage.qa-unit"
        )
        XCTAssertEqual(
            ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-ui.share"),
            "group.com.daypage.qa-ui"
        )
        XCTAssertEqual(
            ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-unit.DayPageWidget"),
            "group.com.daypage.qa-unit"
        )
        XCTAssertEqual(
            ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-ui.DayPageWidget"),
            "group.com.daypage.qa-ui"
        )
    }

    func testOnlyProductionIdentitiesResolveProductionGroup() {
        for identity in [
            "com.daypage.app", "com.daypage.app.share", "com.daypage.app.DayPageWidget",
        ] as [String?] {
            XCTAssertEqual(
                ScreenshotShareInbox.appGroupIdentifier(for: identity), "group.com.daypage",
                "Identity \(identity ?? "nil") must keep the production namespace"
            )
        }
    }

    func testUnknownAndNearMissIdentitiesFailClosed() {
        for identity in [nil, "", "com.daypage.app.qa-ui-other", "com.daypage.app.qa-units",
                         "com.daypage.app.qa-ui-928.fake", "com.daypage.app.qa-ui-928.DayPageWidgetx",
                         "com.daypage.app.qa-ui-1234567890123", "com.daypage.app.qa-ui-",
                         "com.daypage.app.qa-ui-١٢٣", "com.daypage.app.qa-ui-928.share.share"] as [String?] {
            XCTAssertEqual(ScreenshotShareInbox.appGroupIdentifier(for: identity), "")
        }
    }

    func testNumberedQASessionNeverResolvesProductionOrExistingQAGroup() {
        for suffix in ["", ".share", ".DayPageWidget"] {
            XCTAssertEqual(ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-ui-928" + suffix),
                           "group.com.daypage.qa-ui-928")
            XCTAssertEqual(ScreenshotShareInbox.appGroupIdentifier(for: "com.daypage.app.qa-ui-929" + suffix),
                           "group.com.daypage.qa-ui-929")
        }
    }

    func testEmptyNamespaceRefusesContainerLookup() async throws {
        let manager = RecordingInboxFileManager()
        do {
            _ = try await ScreenshotShareInbox(appGroupIdentifier: "", fileManager: manager).pending()
            XCTFail("Empty namespace must refuse before resolving a container")
        } catch {
            XCTAssertEqual(error as? ScreenshotShareInboxError, .appGroupUnavailable)
        }
        XCTAssertEqual(manager.lookupCount, 0)
    }

    func testStagedItemFilenamesCannotEscapeInboxDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-share-inbox-safety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)

        let inbox = ScreenshotShareInbox(rootURL: root)
        let item = ScreenshotShareInboxItem(
            id: UUID(), createdAt: Date(), filename: "../outside.png", contentType: "public.png"
        )
        do {
            _ = try await inbox.data(for: item)
            XCTFail("Tampered inbox item must not read outside the inbox directory")
        } catch {
            XCTAssertEqual(error as? ScreenshotShareInboxError, .unsafePath)
        }
        do {
            try await inbox.remove(item)
            XCTFail("Tampered inbox item must not delete outside the inbox directory")
        } catch {
            XCTAssertEqual(error as? ScreenshotShareInboxError, .unsafePath)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

// MARK: - Preferred-time-zone grouping (review finding 7)

final class ScreenshotDayGroupingTests: XCTestCase {
    private var vault: URL!
    private var previousTimeZone: String?

    override func setUpWithError() throws {
        vault = try RecoveryFixtures.makeVault("tz")
        VaultInitializer.testOverrideURL = vault
        previousTimeZone = UserDefaults.standard.string(forKey: AppSettings.Keys.preferredTimeZone)
    }

    override func tearDownWithError() throws {
        if let previousTimeZone {
            UserDefaults.standard.set(previousTimeZone, forKey: AppSettings.Keys.preferredTimeZone)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSettings.Keys.preferredTimeZone)
        }
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testManifestGroupingFollowsPreferredTimeZone() async throws {
        UserDefaults.standard.set("Etc/GMT+12", forKey: AppSettings.Keys.preferredTimeZone)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Find two nearby instants where the preferred-time-zone day contract
        // and the device-local calendar disagree, so the assertion
        // discriminates the two grouping rules.
        var createdAt = base
        var query = base.addingTimeInterval(1_800)
        var preferredSameDay = true
        var foundDiscriminatingPair = false
        for halfHour in 0..<96 {
            let candidate = base.addingTimeInterval(TimeInterval(halfHour) * 1_800)
            let probe = candidate.addingTimeInterval(1_800)
            let preferred = RawStorage.dayString(for: candidate) == RawStorage.dayString(for: probe)
            let device = Calendar.current.isDate(candidate, inSameDayAs: probe)
            if preferred != device {
                createdAt = candidate
                query = probe
                preferredSameDay = preferred
                foundDiscriminatingPair = true
                break
            }
        }
        guard foundDiscriminatingPair else {
            throw XCTSkip("Preferred and device zones agree on every probed boundary")
        }
        let fixedCreatedAt = createdAt
        let store = ScreenshotCaptureStore(vaultRoot: vault, now: { fixedCreatedAt })
        let outcome = try await store.receive(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudConsentAtCapture: false
        )
        let coordinator = ScreenshotCaptureCoordinator(
            store: store,
            evidenceExtractor: EmptyEvidenceExtractor(),
            understandingProvider: NeverCalledProvider()
        )
        let manifests = await coordinator.manifests(for: query)

        XCTAssertEqual(
            manifests.map(\.id),
            preferredSameDay ? [outcome.manifest.id] : [],
            "Day grouping must follow RawStorage's preferred-time-zone contract"
        )
    }
}

// MARK: - Canonical attachment kind (review finding 9)

final class ScreenshotAttachmentKindTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = try RecoveryFixtures.makeVault("kind")
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testIngestWritesCanonicalPhotoAttachmentAcceptedBySyncWire() async throws {
        let coordinator = ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: vault),
            evidenceExtractor: EmptyEvidenceExtractor(),
            understandingProvider: NeverCalledProvider()
        )
        let outcome = try await coordinator.ingest(
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .actionButtonShortcut,
            cloudAnalysisAllowed: false
        )
        let memos = try RawStorage.read(dayString: outcome.manifest.memoDayString, vaultRoot: vault)
        let memo = try XCTUnwrap(memos.first { $0.id == outcome.manifest.memoID })
        let attachment = try XCTUnwrap(memo.attachments.first)
        XCTAssertEqual(attachment.kind, "photo", "New captures must use the canonical photo kind")
        XCTAssertEqual(attachment.file, outcome.manifest.originalPath)

        // The sync wire builder must accept the ingested attachment unchanged.
        let inspected = try AttachmentFileInspector.inspect(
            relativePath: attachment.file,
            kind: attachment.kind
        )
        XCTAssertEqual(inspected.mimeType, "image/png")
        XCTAssertEqual(inspected.sizeBytes, Int64(RecoveryFixtures.onePixelPNG.count))

        // Raw bytes stay byte-identical to the received screenshot.
        let original = try await ScreenshotCaptureStore(vaultRoot: vault)
            .originalData(for: outcome.manifest.id)
        XCTAssertEqual(original, RecoveryFixtures.onePixelPNG)
    }
}

// MARK: - Share staging cancellation gate (review finding 6)

final class ScreenshotShareStagingGateTests: XCTestCase {
    func testCancelDuringStagingCannotLeaveStagedItem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-share-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenshotShareInbox(rootURL: root)
        let gate = ScreenshotShareStagingGate()

        // Cancellation lands while the provider callback is still staging.
        gate.cancel()
        let staged = try await gate.stageIfActive(
            in: inbox,
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png"
        )
        XCTAssertNil(staged, "A cancelled share request must never stage")
        let pending = try await inbox.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testStagingBeforeCancelRemainsDurableForNextPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-share-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ScreenshotShareInbox(rootURL: root)
        let gate = ScreenshotShareStagingGate()

        let staged = try await gate.stageIfActive(
            in: inbox,
            data: RecoveryFixtures.onePixelPNG,
            declaredContentType: "image/png"
        )
        let item = try XCTUnwrap(staged)
        gate.cancel()
        // Cancellation after staging reports cancel to the host; the durable
        // staged copy stays for the next app pass (it was already committed).
        let pending = try await inbox.pending()
        XCTAssertEqual(pending.map(\.id), [item.id])
        let data = try await inbox.data(for: item)
        XCTAssertEqual(data, RecoveryFixtures.onePixelPNG)
    }
}
