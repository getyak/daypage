import Foundation
import Combine
import DayPageStorage

// MARK: - TimelinePinService
//
// Persists the set of date strings (`yyyy-MM-dd`) that the user has pinned
// from the Today timeline. Pinned days bubble up into a dedicated "📌 PINNED"
// section at the top of the timeline (see TimelineService.sections).
//
// Storage: a single JSON file at `vault/.timeline-pins.json`. JSON instead of
// UserDefaults because the vault is the source of truth for everything else
// the user produces — keeping pin state alongside the markdown files means a
// cloud sync (or a manual `vault/` move) carries the pin set with it.
//
// Concurrency: `@MainActor` final class, single shared instance. Reads are
// O(1) against an in-memory set; writes are atomic-replace via FileManager.
// Writes also broadcast `.timelinePinsDidChange` so the timeline view can
// re-render its sections.

@MainActor
public final class TimelinePinService: ObservableObject {

    public static let shared = TimelinePinService()

    /// The set of pinned date strings (`yyyy-MM-dd`). `@Published` so SwiftUI
    /// views observing the service get a fresh render whenever it mutates.
    @Published public private(set) var pinned: Set<String> = []

    /// Lazy storage URL — computed at first access so we don't touch the
    /// vault before `VaultInitializer.initializeIfNeeded()` runs.
    private var storageURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent(".timeline-pins.json")
    }

    private init() {
        load()
    }

    // MARK: - Public API

    public func isPinned(_ dateString: String) -> Bool {
        pinned.contains(dateString)
    }

    /// Toggles pinned state for one date. Returns the new state for callers
    /// that want to surface a confirmation ("Pinned" / "Unpinned").
    @discardableResult
    public func togglePin(_ dateString: String) -> Bool {
        if pinned.contains(dateString) {
            pinned.remove(dateString)
        } else {
            pinned.insert(dateString)
        }
        persist()
        NotificationCenter.default.post(name: .timelinePinsDidChange, object: nil)
        return pinned.contains(dateString)
    }

    /// Drops a pin without toggling (used when a pinned day is deleted, so we
    /// don't leave a dangling entry in the pin set).
    public func unpin(_ dateString: String) {
        guard pinned.contains(dateString) else { return }
        pinned.remove(dateString)
        persist()
        NotificationCenter.default.post(name: .timelinePinsDidChange, object: nil)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        pinned = Set(decoded)
    }

    private func persist() {
        let sorted = pinned.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        let url = storageURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Notification

public extension Notification.Name {
    /// Posted by: TimelinePinService.togglePin / clear — whenever the pin set
    /// changes (always on the main queue).
    /// Observed by: TimelineService listeners (unverified — no active .addObserver
    /// found in grep; channel kept for future timeline rebuild on pin change).
    public static let timelinePinsDidChange = Notification.Name("timelinePinsDidChange")
}
