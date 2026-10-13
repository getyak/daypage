import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

// Issue #928 / #876 — native screenshot capture regressions: exact photo/memo
// integration and Undo-vs-finalization ownership. Temporary vaults, fake
// extractors/providers, disabled cloud policy only — no real keys, defaults,
// vault content, or provider traffic. Parent-run native suite.

private enum UIFixtures {
    static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}

private struct FakeExtractor: ScreenshotEvidenceExtracting {
    func extract(from imageData: Data) async throws -> ScreenshotEvidence { ScreenshotEvidence() }
}

private struct NeverCalledProvider: ScreenshotUnderstandingProvider {
    var providerInfo: ScreenshotProviderInfo {
        .init(kind: "test", model: "never", promptVersion: "test")
    }
    func understand(_ request: ScreenshotUnderstandingRequest) async throws -> ScreenshotUnderstandingResult {
        Issue.record("disabled policy must never reach the provider")
        throw ScreenshotUnderstandingProviderError.invalidResponse
    }
}

extension DayPageSerialSwiftTests {
@MainActor
@Suite("ScreenshotCaptureUITests", .serialized)
struct ScreenshotCaptureUITests {

    private let tempDir: URL
    private let previousOverride: URL?

    init() throws {
        previousOverride = VaultInitializer.testOverrideURL
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotCaptureUI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = previousOverride
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator() -> ScreenshotCaptureCoordinator {
        ScreenshotCaptureCoordinator(
            store: ScreenshotCaptureStore(vaultRoot: tempDir),
            evidenceExtractor: FakeExtractor(),
            understandingProvider: NeverCalledProvider(),
            cloudConsent: AllowAllAIConsent()
        )
    }

    /// Ingests one capture and waits (bounded) for Today to observe it.
    private func makeTodayWithCapture() async throws -> (TodayViewModel, ScreenshotCaptureManifest) {
        let coordinator = makeCoordinator()
        let outcome = try await coordinator.ingest(
            data: UIFixtures.onePixelPNG,
            declaredContentType: "image/png",
            source: .appImport,
            cloudAnalysisAllowed: false
        )
        let vm = TodayViewModel(date: outcome.manifest.createdAt, observeChanges: false)
        vm.load()
        let deadline = Date().addingTimeInterval(5)
        while (vm.memos.isEmpty || vm.screenshotManifestsByMemoID[outcome.manifest.memoID] == nil) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return (vm, outcome.manifest)
    }

    @Test("Exact photo/memo integration: one photo memo bound to the capture")
    func exactPhotoMemoIntegration() async throws {
        defer { cleanup() }
        let (vm, manifest) = try await makeTodayWithCapture()

        let memo = try #require(vm.memos.first { $0.id == manifest.memoID })
        #expect(memo.attachments.count == 1)
        #expect(memo.attachments.first?.kind == "photo")
        #expect(memo.attachments.first?.file == manifest.originalPath)

        // The original file exists at the exact generated path; nothing else.
        let reader = ScreenshotCaptureStore(vaultRoot: tempDir)
        let original = try await reader.originalData(for: manifest.id)
        #expect(original == UIFixtures.onePixelPNG)
    }

    @Test("Undo accepted before expiration preserves raw memo, original and manifest")
    func undoBeforeExpirationPreservesEverything() async throws {
        defer { cleanup() }
        let (vm, manifest) = try await makeTodayWithCapture()
        let memo = try #require(vm.memos.first { $0.id == manifest.memoID })
        let coordinator = makeCoordinator()
        vm.finalizeScreenshotDeletionOverride = { id, root in
            try await coordinator.finalizeDeletionIfMemoMissing(captureID: id, vaultRoot: root)
        }

        vm.deleteMemo(memo)
        vm.undoDelete()  // accepted: the window is still open

        // Wait for durable persistence to settle (bounded).
        await vm.waitForMemoPersistence()
        let reader = ScreenshotCaptureStore(vaultRoot: tempDir)
        let surviving = try await reader.manifest(for: manifest.id)
        #expect(surviving.id == manifest.id)
        let original = try await reader.originalData(for: manifest.id)
        #expect(original == UIFixtures.onePixelPNG)
        let memos = try RawStorage.read(dayString: manifest.memoDayString, vaultRoot: tempDir)
        #expect(memos.contains { $0.id == manifest.memoID }, "undo restores the raw memo")
    }

    @Test("Undo after ownership closes cannot restore an assetless memo")
    func undoAfterOwnershipClosedIsRejected() async throws {
        defer { cleanup() }
        let (vm, manifest) = try await makeTodayWithCapture()
        let memo = try #require(vm.memos.first { $0.id == manifest.memoID })
        let coordinator = makeCoordinator()
        let finalized = FinalizeRecorder()
        defer { Task { await finalized.release() } }
        vm.finalizeScreenshotDeletionOverride = { id, root in
            await finalized.hold()
            try await coordinator.finalizeDeletionIfMemoMissing(captureID: id, vaultRoot: root)
            await finalized.mark()
        }

        vm.deleteMemo(memo)
        // Try Undo while the real expired finalizer is suspended.
        let deadline = Date().addingTimeInterval(8)
        while await !finalized.entered && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let entered = await finalized.entered
        try #require(entered, "finalization runs at expiration")

        // The window is closed: undo must be rejected, not restore a memo
        // whose screenshot originals are already gone.
        vm.undoDelete()
        #expect(vm.lastDeletedMemo == nil)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(dayString: manifest.memoDayString, vaultRoot: tempDir).allSatisfy { $0.id != manifest.memoID })
        await finalized.release()
        let finishDeadline = Date().addingTimeInterval(3)
        while await !finalized.done && Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let done = await finalized.done
        try #require(done)

        let reader = ScreenshotCaptureStore(vaultRoot: tempDir)
        await #expect(throws: (any Error).self) {
            _ = try await reader.manifest(for: manifest.id)
        }
    }

    @Test("A rapid second deletion keeps its Undo state while the first finalizes")
    func rapidSecondDeletionKeepsUndoState() async throws {
        defer { cleanup() }
        let (vm, manifestA) = try await makeTodayWithCapture()
        let memoA = try #require(vm.memos.first { $0.id == manifestA.memoID })
        let coordinator = makeCoordinator()
        let finalized = FinalizeRecorder()
        defer { Task { await finalized.release() } }
        vm.finalizeScreenshotDeletionOverride = { id, root in
            await finalized.hold()
            try await coordinator.finalizeDeletionIfMemoMissing(captureID: id, vaultRoot: root)
            await finalized.mark()
        }
        // A plain second memo (no screenshot) deleted shortly after A.
        let memoB = Memo(
            id: UUID(),
            type: .text,
            created: manifestA.createdAt,
            attachments: [],
            body: "second"
        )
        try RawStorage.mutate(dayString: manifestA.memoDayString, vaultRoot: tempDir) { $0 + [memoB] }
        vm.memos = vm.memos + [memoB]

        vm.deleteMemo(memoA)
        let deadline = Date().addingTimeInterval(8)
        while await !finalized.entered && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entered = await finalized.entered
        try #require(entered)
        vm.deleteMemo(memoB)
        await finalized.release()
        let finishDeadline = Date().addingTimeInterval(3)
        while await !finalized.done && Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let done = await finalized.done
        try #require(done)
        #expect(vm.lastDeletedMemo?.id == memoB.id, "older deletion never clears newer Undo state")

        // B is still undoable.
        vm.undoDelete()
        await vm.waitForMemoPersistence()
        #expect(vm.lastDeletedMemo == nil)
        let memos = try RawStorage.read(dayString: manifestA.memoDayString, vaultRoot: tempDir)
        #expect(memos.contains { $0.id == memoB.id })
        #expect(memos.allSatisfy { $0.id != memoA.id })
        await #expect(throws: (any Error).self) {
            _ = try await ScreenshotCaptureStore(vaultRoot: tempDir).manifest(for: manifestA.id)
        }
    }

    @Test("Rapid deletion waits for the previous raw delete before removing screenshot files")
    func rapidDeletionWaitsForDurablePredecessor() async throws {
        defer { cleanup() }
        let (vm, manifestA) = try await makeTodayWithCapture()
        let memoA = try #require(vm.memos.first { $0.id == manifestA.memoID })
        let memoB = Memo(id: UUID(), type: .text, created: manifestA.createdAt, attachments: [], body: "second")
        try RawStorage.mutate(dayString: manifestA.memoDayString, vaultRoot: tempDir) { $0 + [memoB] }
        vm.memos.append(memoB)
        let coordinator = makeCoordinator()
        vm.finalizeScreenshotDeletionOverride = { id, root in
            try await coordinator.finalizeDeletionIfMemoMissing(captureID: id, vaultRoot: root)
        }

        // Pause the existing persistence queue, without replacing the real
        // deletion implementation. A and B must wait behind this predecessor.
        let predecessor = FinalizeRecorder()
        defer { Task { await predecessor.release() } }
        _ = vm.enqueueMemoPersistence { await predecessor.hold() }
        let admissionDeadline = Date().addingTimeInterval(3)
        while await !predecessor.entered && Date() < admissionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entered = await predecessor.entered
        try #require(entered)
        vm.deleteMemo(memoA)
        vm.deleteMemo(memoB)
        vm.undoDelete()
        // Let the earlier finalizer attempt run while A still exists on disk.
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(try RawStorage.read(dayString: manifestA.memoDayString, vaultRoot: tempDir).contains { $0.id == memoA.id })
        await predecessor.release()
        await vm.waitForMemoPersistence()

        let reader = ScreenshotCaptureStore(vaultRoot: tempDir)
        let completionDeadline = Date().addingTimeInterval(3)
        while (try? await reader.manifest(for: manifestA.id)) != nil && Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await #expect(throws: (any Error).self) { _ = try await reader.manifest(for: manifestA.id) }
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(manifestA.originalPath).path))
        let memos = try RawStorage.read(dayString: manifestA.memoDayString, vaultRoot: tempDir)
        #expect(memos.allSatisfy { $0.id != memoA.id })
        #expect(memos.contains { $0.id == memoB.id }, "the newer deletion remains undoable")
    }
}

}

typealias ScreenshotCaptureUITests = DayPageSerialSwiftTests.ScreenshotCaptureUITests

/// Records whether the deletion finalizer completed.
private actor FinalizeRecorder {
    private(set) var done = false
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
    func mark() { done = true }
}
