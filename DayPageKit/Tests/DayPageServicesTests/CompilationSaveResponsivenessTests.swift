import Foundation
import Testing
import DayPageModels
@testable import DayPageServices
@testable import DayPageStorage

/// Delays an actual coordinated daily-page replacement until the main actor
/// responds, or until the bounded timeout allows a failing test to finish.
private final class CompilationWritePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var observed = false
    private var responsive = false
    private let manual: Bool
    private var pendingWriter: (@Sendable ((@Sendable () -> Void)?) -> Void)?

    init(url: URL, manual: Bool = false) {
        presentedItemURL = url
        self.manual = manual
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        if manual {
            lock.lock()
            observed = true
            pendingWriter = writer
            lock.unlock()
            return
        }
        let response = DispatchSemaphore(value: 0)
        Task { @MainActor in response.signal() }
        let didRespond = response.wait(timeout: .now() + 1) == .success
        lock.lock()
        observed = true
        responsive = didRespond
        lock.unlock()
        writer({})
    }

    func release() {
        lock.lock()
        let writer = pendingWriter
        pendingWriter = nil
        lock.unlock()
        writer?({})
    }

    func waitUntilWriting() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !result.observed, ContinuousClock.now < deadline { await Task.yield() }
        try #require(result.observed, "Real save must reach the controlled coordinator")
    }

    var result: (observed: Bool, responsive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (observed, responsive)
    }
}

@Suite("Compilation save responsiveness", .serialized)
struct CompilationSaveResponsivenessTests {
    private func fixture() throws -> (URL, String) {
        let fixtureRoot = ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = fixtureRoot.appendingPathComponent("compilation-responsive-\(UUID().uuidString)", isDirectory: true)
        let memo = Memo(created: Date(timeIntervalSince1970: 1_798_502_400), body: "Synthetic source")
        try RawStorage.atomicWrite(string: memo.toMarkdown(), to: root.appendingPathComponent("raw/2026-10-28.md"))
        try RawStorage.atomicWrite(string: "---\ntype: daily\n---\n\n# Previous\n", to: root.appendingPathComponent("wiki/daily/2026-10-28.md"))
        return (root, CompilationService.sourceHash(of: [memo]))
    }

    private var parsed: CompilationService.ParsedCompilationOutput {
        .init(dailyPageText: "---\ntype: daily\n---\n\n# Synthetic saved page\n", entityInstructions: [], memoUpdates: [], hotCacheText: "")
    }

    @Test @MainActor
    func savingDailyPageKeepsMainActorResponsiveDuringCoordinatedWrite() async throws {
        let (root, sourceHash) = try fixture()
        let dailyURL = root.appendingPathComponent("wiki/daily/2026-10-28.md")
        let presenter = CompilationWritePresenter(url: dailyURL)
        NSFileCoordinator.addFilePresenter(presenter)
        defer {
            NSFileCoordinator.removeFilePresenter(presenter)
            try? FileManager.default.removeItem(at: root)
        }
        let service = CompilationService(vaultRootProvider: { root }, scope: LocalCompilationCommitScope(), consent: AllowAllAIConsent())
        #expect(Thread.isMainThread)
        let startedAt = ContinuousClock.now
        try await service.saveResults(
            parsed,
            dateString: "2026-10-28",
            trigger: "test",
            startTime: Date(),
            memoCount: 1,
            sourceHash: sourceHash,
            entityOperationID: "synthetic-operation"
        )
        let indexURL = root.appendingPathComponent("wiki/index.md")
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        let persisted = try String(contentsOf: dailyURL, encoding: .utf8)
        #expect(persisted.contains("source_hash: \(sourceHash)"))
        #expect(persisted.contains("# Synthetic saved page"))
        print("Synthetic coordinated save: caller_main_thread=true, elapsed=\(startedAt.duration(to: .now)), daily_bytes=\(persisted.utf8.count), coordination_observed=\(presenter.result.observed), main_actor_responded=\(presenter.result.responsive)")
        #expect(presenter.result.observed, "The real atomic write must reach file coordination")
        #expect(presenter.result.responsive, "Saving a daily page must not block the main actor")
    }

    @Test @MainActor
    func queuedResultRevokedBeforeAdmissionWritesNothing() async throws {
        let (root, hash) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: root)
        let service = CompilationService(vaultRootProvider: { root }, scope: scope, consent: AllowAllAIConsent())
        let previous = try Data(contentsOf: root.appendingPathComponent("wiki/daily/2026-10-28.md"))
        let transition = scope.close()
        transition.finish()
        await #expect(throws: CancellationError.self) {
            try await service.saveResults(parsed, dateString: "2026-10-28", trigger: "test", startTime: Date(), memoCount: 1, sourceHash: hash, entityOperationID: hash, token: token)
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("wiki/daily/2026-10-28.md")) == previous)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki/log.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki/index.md").path))
    }

    @Test @MainActor
    func sourceChangeAndConsentRevocationRejectBeforeFirstWrite() async throws {
        let (root, hash) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CompilationService(vaultRootProvider: { root }, scope: LocalCompilationCommitScope(), consent: AllowAllAIConsent())
        try RawStorage.atomicWrite(string: "changed synthetic input", to: root.appendingPathComponent("raw/2026-10-28.md"))
        await #expect(throws: CancellationError.self) {
            try await service.saveResults(parsed, dateString: "2026-10-28", trigger: "test", startTime: Date(), memoCount: 1, sourceHash: hash, entityOperationID: hash)
        }
        let denied = CompilationService(vaultRootProvider: { root }, scope: LocalCompilationCommitScope(), consent: DeniedCompilationConsent())
        await #expect(throws: AIAuthorizationError.self) {
            try await denied.saveResults(parsed, dateString: "2026-10-28", trigger: "test", startTime: Date(), memoCount: 1, sourceHash: hash, entityOperationID: hash)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wiki/log.md").path))
    }

    @Test @MainActor
    func overlappingSavesPreserveBothLogRowsAndEntityIdempotency() async throws {
        let (root, hash) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CompilationService(vaultRootProvider: { root }, scope: LocalCompilationCommitScope(), consent: AllowAllAIConsent())
        let output = CompilationService.ParsedCompilationOutput(
            dailyPageText: parsed.dailyPageText,
            entityInstructions: [.init(entityType: "themes", entitySlug: "synthetic-theme", section: "## Notes", content: "- One synthetic observation.", displayName: "Synthetic Theme")],
            memoUpdates: [], hotCacheText: ""
        )
        async let first: Void = service.saveResults(output, dateString: "2026-10-28", trigger: "first", startTime: Date(), memoCount: 1, sourceHash: hash, entityOperationID: hash)
        async let second: Void = service.saveResults(output, dateString: "2026-10-28", trigger: "second", startTime: Date(), memoCount: 1, sourceHash: hash, entityOperationID: hash)
        _ = try await (first, second)
        let log = try String(contentsOf: root.appendingPathComponent("wiki/log.md"), encoding: .utf8)
        let entity = try String(contentsOf: root.appendingPathComponent("wiki/themes/synthetic-theme.md"), encoding: .utf8)
        #expect(log.components(separatedBy: "| first |").count - 1 == 1)
        #expect(log.components(separatedBy: "| second |").count - 1 == 1)
        #expect(entity.components(separatedBy: "- One synthetic observation.").count - 1 == 1)
        #expect(entity.contains("occurrence_count: 1"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("wiki/daily/.trash").path).count == 2)
    }

    @Test(arguments: ["reset", "switch", "revoke"])
    @MainActor
    func transitionsDrainRealSaveWithoutBlockingOrLateWrites(action: String) async throws {
        let (root, hash) = try fixture()
        let (nextRoot, _) = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: nextRoot)
        }
        let scope = LocalCompilationCommitScope()
        let selected = CompilationTestRoot(root)
        let service = CompilationService(vaultRootProvider: { selected.value }, scope: scope, consent: AllowAllAIConsent())
        let memo = try #require(RawStorage.read(dayString: "2026-10-28", vaultRoot: root).first)
        let output = CompilationService.ParsedCompilationOutput(dailyPageText: parsed.dailyPageText,
            entityInstructions: [], memoUpdates: [.init(memoID: memo.id, mood: "focused", entityMentions: [], dateReferences: [], marginNote: nil)], hotCacheText: "")
        let notifications = CompilationSaveCounter()
        let observer = NotificationCenter.default.addObserver(forName: .rawStorageDidWrite, object: nil, queue: nil) { note in
            if note.userInfo?[RawStorage.writtenVaultRootKey] as? URL == root { notifications.increment() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let presenter = CompilationWritePresenter(url: root.appendingPathComponent("wiki/daily/2026-10-28.md"), manual: true)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
        let save = Task { @MainActor in
            try await service.saveResults(output, dateString: "2026-10-28", trigger: "test", startTime: Date(), memoCount: 1, sourceHash: hash, entityOperationID: hash)
        }
        try await presenter.waitUntilWriting()

        var completed = false
        let transition: Task<Void, Never>
        let suiteName = "CompilationTransition.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        if action == "reset" {
            let reset = LocalDataResetPolicy.beginReset(contextProvider: {
                .init(activeVaultURL: root, canonicalLocalVaultURL: root, locatorKind: .local, vaultLocationPreference: .local, hasAuthenticatedCloudAccount: false)
            }, scope: scope, mutation: { target in
                try? FileManager.default.removeItem(at: target)
            })
            transition = Task { @MainActor in
                #expect(await reset.value == .allowed)
                completed = true
            }
        } else if action == "revoke" {
            let revoke = AppSettings.setAIFeaturesEnabled(false, in: store, scope: scope)
            transition = Task { @MainActor in
                await revoke.value
                #expect(!AppSettings.aiFeaturesEnabled(in: store))
                completed = true
            }
        } else {
            let closing = scope.close()
            transition = Task { @MainActor in
                await closing.waitForDrain()
                selected.value = nextRoot
                closing.finish()
                completed = true
            }
        }
        await Task.yield()
        #expect(!completed, "Transition must wait for the admitted disk write")
        #expect(Thread.isMainThread, "Main actor remains usable while draining")
        presenter.release()
        await #expect(throws: CancellationError.self) { try await save.value }
        await transition.value
        #expect(completed)
        #expect(!scope.hasActiveCommits)
        #expect(notifications.value == 0, "Closing must suppress old-root notifications and sync scheduling")
        if action == "reset" {
            #expect(!FileManager.default.fileExists(atPath: root.path))
        } else {
            #expect(try String(contentsOf: root.appendingPathComponent("wiki/index.md"), encoding: .utf8).contains("2026-10-28"))
        }
        #expect(!FileManager.default.fileExists(atPath: nextRoot.appendingPathComponent("wiki/index.md").path))
        #expect(!FileManager.default.fileExists(atPath: nextRoot.appendingPathComponent("wiki/log.md").path))
    }
}

private struct DeniedCompilationConsent: AIConsentChecking {
    func authorize() throws { throw AIAuthorizationError.aiDisabled }
}

private final class CompilationTestRoot: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL
    init(_ root: URL) { self.root = root }
    var value: URL {
        get { lock.lock(); defer { lock.unlock() }; return root }
        set { lock.lock(); root = newValue; lock.unlock() }
    }
}

private final class CompilationSaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
