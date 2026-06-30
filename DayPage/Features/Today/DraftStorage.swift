import Foundation
import DayPageServices

// MARK: - DraftStorage

/// Manages the persisted draft text lifecycle for TodayView.
/// Keys mirror the @SceneStorage / @AppStorage keys used in TodayView.
enum DraftStorage {

    static let textKey = "today.draftText"
    static let dateKey = "today.draftDate"

    private static let maxAgeSeconds: TimeInterval = 30 * 24 * 3600

    /// Call on launch. Deletes the draft keys from UserDefaults if the draft is
    /// older than 30 days so stale text never surfaces after a long app pause.
    static func clearIfExpired() {
        let defaults = UserDefaults.standard
        let draftDate = defaults.double(forKey: dateKey)
        guard draftDate > 0 else { return }
        let age = Date().timeIntervalSince1970 - draftDate
        if age > maxAgeSeconds {
            defaults.removeObject(forKey: textKey)
            defaults.removeObject(forKey: dateKey)
        }
    }
}
