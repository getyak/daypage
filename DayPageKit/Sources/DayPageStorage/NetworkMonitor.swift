// NetworkMonitor.swift
//
// Lightweight wrapper around NWPathMonitor that publishes a single
// `isOnline` boolean to SwiftUI views and services.
//
// R8 addition — "Simulate Offline" debug toggle:
//   The Settings → Experiments section now exposes a toggle that flips
//   `AppSettings.Keys.debugSimulateOffline` in UserDefaults. When that
//   key is true, `isOnline` is forced to `false` regardless of the real
//   NWPath state, so testers can dogfood the SyncQueue banner and
//   offline-capture flows without putting the device into airplane mode.
//   The override never makes us *more* online — if the real network is
//   down, we still report offline.

import Foundation
import Network

@MainActor
public final class NetworkMonitor: ObservableObject {

    public static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.daypage.network", qos: .utility)

    /// What the SwiftUI layer observes. Equals `realIsOnline && !simulateOffline`.
    @Published public private(set) var isOnline: Bool = true

    /// The raw NWPath verdict, before the debug override is applied.
    /// The NWPath callback writes here; `recomputeIsOnline()` then folds
    /// in the simulate-offline override and publishes the result.
    private var realIsOnline: Bool = true

    private var notificationObserver: NSObjectProtocol?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.realIsOnline = path.status == .satisfied
                self?.recomputeIsOnline()
            }
        }
        monitor.start(queue: queue)

        // SettingsView posts this when the user flips the "Simulate
        // Offline" toggle. We can't rely on UserDefaults KVO because
        // @AppStorage-backed mutations don't always cross actor
        // boundaries cleanly; an explicit notification is cheaper and
        // more predictable.
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .simulateOfflineChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeIsOnline()
            }
        }

        // Apply any pre-existing UserDefaults value at launch so the
        // toggle survives across cold starts.
        recomputeIsOnline()
    }

    deinit {
        if let obs = notificationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Recomputes `isOnline` from the raw NWPath verdict + the debug
    /// override. Idempotent — assigning the same value to a @Published
    /// property is a no-op for observers thanks to `removeDuplicates()`
    /// downstream.
    private func recomputeIsOnline() {
        let simulate = UserDefaults.standard.bool(forKey: StorageSettings.debugSimulateOfflineKey)
        let next = realIsOnline && !simulate
        if isOnline != next {
            isOnline = next
        }
    }

    /// Test seam — lets `NetworkMonitorTests` drive the override path
    /// without spinning up a real NWPathMonitor. Production code never
    /// calls this; the real NWPath callback owns `realIsOnline`.
    public func _testOnly_setRealIsOnline(_ value: Bool) {
        realIsOnline = value
        recomputeIsOnline()
    }

    /// Test seam — lets `NetworkMonitorTests` trigger a recompute after
    /// it has mutated the simulate-offline key in a private UserDefaults
    /// suite. The production path goes through
    /// `.simulateOfflineChanged` notifications.
    public func _testOnly_recomputeIsOnline() {
        recomputeIsOnline()
    }
}

// MARK: - Notification name

public extension Notification.Name {
    /// Posted by: SettingsView.debugSimulateOffline toggle (R8) — when the user flips
    /// the "Simulate Offline" debug switch.
    /// Observed by: NetworkMonitor.init (.addObserver — recomputes `isOnline` regardless
    /// of real NWPathMonitor state). Kept in this file because the coupling is tight
    /// between the toggle UI and the monitor; no other component should need to post it.
    public static let simulateOfflineChanged = Notification.Name("com.daypage.simulateOfflineChanged")
}
