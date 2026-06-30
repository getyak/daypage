// NetworkMonitorTests.swift — Round 8 (R8-FEATURE: Simulate Offline)
//
// Validates the "simulate offline" override path:
//   * realIsOnline=true + simulate=true  → isOnline=false
//   * realIsOnline=true + simulate=false → isOnline=true
//   * realIsOnline=false + simulate=false → isOnline=false (override
//     never makes us *more* online than the real network)
//   * Toggling the UserDefaults key + posting
//     .simulateOfflineChanged recomputes the published value.
//
// Why we hit the shared singleton: NetworkMonitor's NWPathMonitor lives
// on a private dispatch queue and can't be swapped out from a test. The
// `_testOnly_*` seams let us drive the override path without touching
// the real network stack. We snapshot+restore the UserDefaults value so
// the test can't poison subsequent runs of the host app. The brief
// suggested UserDefaults(suiteName:) isolation, but NetworkMonitor
// reads `.standard` and would need a bigger refactor to inject a
// different store — for an override-only test the snapshot pattern is
// equivalent.

import Testing
import Foundation
import DayPageStorage
import DayPageServices
@testable import DayPage

@MainActor
@Suite(.serialized)
struct NetworkMonitorTests {

    /// Snapshot + restore so test order can't leak state into the host
    /// app or sibling tests.
    private func withCleanSimulateKey<T>(_ body: () async throws -> T) async rethrows -> T {
        let key = AppSettings.Keys.debugSimulateOffline
        let prior = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        return try await body()
    }

    /// Force NetworkMonitor.shared back to a known-good baseline before
    /// each test so they can be run in any order.
    private func resetMonitor() {
        UserDefaults.standard.set(false, forKey: AppSettings.Keys.debugSimulateOffline)
        NetworkMonitor.shared._testOnly_setRealIsOnline(true)
    }

    @Test
    func simulateOfflineForcesIsOnlineFalse() async {
        await withCleanSimulateKey {
            resetMonitor()
            #expect(NetworkMonitor.shared.isOnline == true)

            // Flip the override → expect isOnline to flip to false on
            // the next recompute.
            UserDefaults.standard.set(true, forKey: AppSettings.Keys.debugSimulateOffline)
            NetworkMonitor.shared._testOnly_recomputeIsOnline()
            #expect(NetworkMonitor.shared.isOnline == false)
        }
    }

    @Test
    func simulateOfflineClearedReturnsToReal() async {
        await withCleanSimulateKey {
            resetMonitor()
            UserDefaults.standard.set(true, forKey: AppSettings.Keys.debugSimulateOffline)
            NetworkMonitor.shared._testOnly_recomputeIsOnline()
            #expect(NetworkMonitor.shared.isOnline == false)

            // Clear the override → the real verdict (true) wins again.
            UserDefaults.standard.set(false, forKey: AppSettings.Keys.debugSimulateOffline)
            NetworkMonitor.shared._testOnly_recomputeIsOnline()
            #expect(NetworkMonitor.shared.isOnline == true)
        }
    }

    @Test
    func overrideCannotForceOnlineWhenRealIsOffline() async {
        await withCleanSimulateKey {
            resetMonitor()
            // Real network reports offline. The override can never make
            // us *more* online than reality — only less. The verdict
            // must remain false regardless of the simulate key.
            NetworkMonitor.shared._testOnly_setRealIsOnline(false)
            #expect(NetworkMonitor.shared.isOnline == false)

            UserDefaults.standard.set(true, forKey: AppSettings.Keys.debugSimulateOffline)
            NetworkMonitor.shared._testOnly_recomputeIsOnline()
            #expect(NetworkMonitor.shared.isOnline == false)

            // Restore real online for sibling tests.
            NetworkMonitor.shared._testOnly_setRealIsOnline(true)
        }
    }

    @Test
    func notificationTriggersRecompute() async {
        await withCleanSimulateKey {
            resetMonitor()
            #expect(NetworkMonitor.shared.isOnline == true)

            // Simulate the production flow: SettingsView toggles the
            // UserDefaults key and posts the notification. Because the
            // observer hop is async, give it a short window to land.
            UserDefaults.standard.set(true, forKey: AppSettings.Keys.debugSimulateOffline)
            NotificationCenter.default.post(name: .simulateOfflineChanged, object: nil)
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(NetworkMonitor.shared.isOnline == false)
        }
    }
}
