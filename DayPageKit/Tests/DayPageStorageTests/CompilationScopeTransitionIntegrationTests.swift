import Foundation
import XCTest
@testable import DayPageStorage

final class CompilationScopeTransitionIntegrationTests: XCTestCase {
    private struct FixedLocator: VaultLocator {
        let vaultURL: URL
        var isUsingiCloud: Bool { false }
    }

    @MainActor
    func testLocatorReplacementWaitsForAdmittedCommitBeforePublishingRoot() async throws {
        let previous = VaultInitializer.shared
        defer { VaultInitializer.shared = previous }
        let root = SyncRealmTestSupport.fixtureRoot.appendingPathComponent("synthetic-scope-root")
        let token = try LocalCompilationCommitScope.shared.capture(vaultRoot: root)
        let commit = try LocalCompilationCommitScope.shared.beginCommit(token)
        defer { commit.finish() }
        let replacement = VaultInitializer.replaceShared(with: FixedLocator(vaultURL: root))
        await Task.yield()
        XCTAssertFalse(VaultInitializer.shared is FixedLocator)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertFalse(token.isCurrent)
        commit.finish()
        let applied = await replacement.value
        XCTAssertTrue(applied)
        XCTAssertEqual(VaultInitializer.shared.vaultURL, root)
    }

    @MainActor
    func testSessionClearReturnsADrainWithoutWaitingOnMainThread() async throws {
        let suiteName = "CompilationScopeSession.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = SyncQueueService.makeForTesting(defaults: defaults)
        let observer = SyncQueueObserver(observeNotifications: false, syncQueue: queue, legacyIsConfigured: { false })
        let root = SyncRealmTestSupport.fixtureRoot.appendingPathComponent("synthetic-session-root")
        let token = try LocalCompilationCommitScope.shared.capture(vaultRoot: root)
        let commit = try LocalCompilationCommitScope.shared.beginCommit(token)
        defer { commit.finish() }
        let drain = observer.clearSession()
        XCTAssertFalse(token.isCurrent)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(LocalCompilationCommitScope.shared.hasActiveCommits)
        commit.finish()
        await drain.value
        XCTAssertFalse(LocalCompilationCommitScope.shared.hasActiveCommits)
        XCTAssertTrue(try LocalCompilationCommitScope.shared.capture(vaultRoot: root).isCurrent)
    }
}
