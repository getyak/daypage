import Foundation
import Testing
@testable import DayPageServices
@testable import DayPageStorage

@Suite("Compilation transition request currency", .serialized)
struct CompilationTransitionCurrencyTests {
    @Test @MainActor
    func revokeRejectsNewOutboundAuthorizationBeforeActiveWriteDrains() async throws {
        let suiteName = "CompilationImmediateRevoke.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        store.set(true, forKey: AppSettings.Keys.aiFeaturesEnabled)
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-currency-vault"))
        let commit = try scope.beginCommit(token)
        defer { commit.finish() }
        let revoke = AppSettings.setAIFeaturesEnabled(false, in: store, scope: scope)
        #expect(scope.hasActiveCommits)
        #expect(throws: AIAuthorizationError.self) {
            try AIRequestConsent.authorize(in: store)
        }
        commit.finish()
        await revoke.value
        #expect(!AppSettings.aiFeaturesEnabled(in: store))
    }

    @Test @MainActor
    func enablingWaitsUntilActiveWriteDrains() async throws {
        let suiteName = "CompilationDelayedEnable.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        store.set(false, forKey: AppSettings.Keys.aiFeaturesEnabled)
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-currency-vault"))
        let commit = try scope.beginCommit(token)
        defer { commit.finish() }
        let enable = AppSettings.setAIFeaturesEnabled(true, in: store, scope: scope)
        #expect(throws: AIAuthorizationError.self) { try AIRequestConsent.authorize(in: store) }
        commit.finish()
        await enable.value
        try AIRequestConsent.authorize(in: store)
    }

    @Test @MainActor
    func unrelatedCloseCannotDiscardAnAIRevokeRequest() async throws {
        let suiteName = "CompilationRevokeCurrency.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-currency-vault"))
        let commit = try scope.beginCommit(token)
        defer { commit.finish() }
        let revoke = AppSettings.setAIFeaturesEnabled(false, in: store, scope: scope)
        let queue = SyncQueueService.makeForTesting(defaults: store)
        let observer = SyncQueueObserver(observeNotifications: false, syncQueue: queue, compilationScope: scope, legacyIsConfigured: { false })
        let unrelated = observer.clearSession()
        commit.finish()
        await revoke.value
        await unrelated.value
        #expect(!AppSettings.aiFeaturesEnabled(in: store), "A different closing operation must not swallow the user's revoke")
    }

    @Test(arguments: [false, true]) @MainActor
    func rapidPreferenceRequestsStillApplyTheLatestValue(initial: Bool) async throws {
        let suiteName = "CompilationToggleCurrency.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        store.set(initial, forKey: AppSettings.Keys.aiFeaturesEnabled)
        let scope = LocalCompilationCommitScope()
        let token = try scope.capture(vaultRoot: URL(fileURLWithPath: "/synthetic-currency-vault"))
        let commit = try scope.beginCommit(token)
        defer { commit.finish() }
        let first = AppSettings.setAIFeaturesEnabled(!initial, in: store, scope: scope)
        let second = AppSettings.setAIFeaturesEnabled(initial, in: store, scope: scope)
        let latest = AppSettings.setAIFeaturesEnabled(!initial, in: store, scope: scope)
        await Task.yield()
        commit.finish()
        await latest.value
        await second.value
        await first.value
        #expect(AppSettings.aiFeaturesEnabled(in: store) == !initial)
    }
}
