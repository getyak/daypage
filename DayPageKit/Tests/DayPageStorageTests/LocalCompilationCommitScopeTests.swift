import Foundation
import Testing
import DayPageModels
@testable import DayPageStorage

@Suite("Local compilation commit admission")
struct LocalCompilationCommitScopeTests {
    @Test
    func closingRejectsQueuedTokenWithoutRunningItsEffect() throws {
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-vault"))
        let transition = scope.close()
        defer { transition.finish() }
        var writes = 0
        #expect(throws: CancellationError.self) {
            let commit = try scope.beginCommit(token)
            defer { commit.finish() }
            writes += 1
        }
        #expect(writes == 0)
        #expect(throws: CancellationError.self) {
            try scope.capture(vaultRoot: token.vaultRoot)
        }
    }

    @Test @MainActor
    func drainSuspendsWithoutBlockingMainActorAndReopensAfterFinish() async throws {
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-vault"))
        let commit = try scope.beginCommit(token)
        let transition = scope.close()
        var drained = false
        let waiter = Task { @MainActor in
            await transition.waitForDrain()
            drained = true
        }
        await Task.yield()
        #expect(!drained)
        #expect(!transition.isDrained)
        #expect(Thread.isMainThread)
        commit.finish()
        await waiter.value
        #expect(drained)
        transition.finish()
        let next = try scope.capture(vaultRoot: token.vaultRoot)
        #expect(next.isCurrent)
        #expect(!token.isCurrent)
    }

    @Test
    func overlappingTransitionsCannotReopenOrApplyAnOlderRequest() throws {
        let scope = LocalCompilationCommitScope()
        let first = scope.close()
        let second = scope.close()
        #expect(!first.isCurrent)
        #expect(second.isCurrent)
        first.finish()
        first.finish() // completion is idempotent
        #expect(throws: CancellationError.self) {
            try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-vault"))
        }
        second.finish()
        #expect(try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-vault")).isCurrent)
    }

    @Test @MainActor
    func deferredRawReceiptCannotNotifyAnotherVaultOrAResetGeneration() throws {
        let root = SyncRealmTestSupport.fixtureRoot.appendingPathComponent("compilation-receipts-\(UUID().uuidString)", isDirectory: true)
        let rootA = root.appendingPathComponent("a", isDirectory: true)
        let rootB = root.appendingPathComponent("b", isDirectory: true)
        let previous = VaultInitializer.testOverrideURL
        defer {
            VaultInitializer.testOverrideURL = previous
            try? FileManager.default.removeItem(at: root)
        }
        let memo = Memo(created: Date(), body: "Synthetic receipt fixture")
        try RawStorage.atomicWrite(string: memo.toMarkdown(), to: rootA.appendingPathComponent("raw/2026-10-28.md"))
        let receipt = try #require(RawStorage.mutateDeferringNotifications(dayString: "2026-10-28", vaultRoot: rootA) { memos in
            var changed = memos
            changed[0].mood = "focused"
            return changed
        })
        let notifications = CompilationReceiptCounter()
        let observer = NotificationCenter.default.addObserver(forName: .rawStorageDidWrite, object: nil, queue: nil) { _ in
            notifications.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        VaultInitializer.testOverrideURL = rootB
        receipt.publishIfCurrent()
        #expect(notifications.value == 0)
        VaultInitializer.testOverrideURL = rootA
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: rootA)
        let reset = scope.close()
        reset.finish()
        receipt.publishIfCurrent(isCurrent: { token.isCurrent })
        #expect(notifications.value == 0)
        #expect(!FileManager.default.fileExists(atPath: rootB.path))
        #expect(try RawStorage.read(dayString: "2026-10-28", vaultRoot: rootA).first?.mood == "focused")
    }
}

private final class CompilationReceiptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
