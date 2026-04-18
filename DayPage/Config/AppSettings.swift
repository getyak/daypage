import Foundation

// MARK: - AppSettings

/// Persistent user preferences backed by UserDefaults.
/// Use AppSettings.shared as the single source of truth for all
/// user-configurable options that affect date/time calculations.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    private init() {}

    // MARK: - Preferred Time Zone

    private let timeZoneKey = "preferredTimeZone"

    /// The time zone used for all date calculations: file naming, compilation
    /// scheduling, and Daily Page attribution. Defaults to the device time zone.
    var preferredTimeZone: TimeZone {
        get {
            guard let id = UserDefaults.standard.string(forKey: timeZoneKey),
                  let tz = TimeZone(identifier: id) else {
                return TimeZone.current
            }
            return tz
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.identifier, forKey: timeZoneKey)
        }
    }

    /// Resets the preferred time zone to the current device time zone.
    func resetToDeviceTimeZone() {
        UserDefaults.standard.removeObject(forKey: timeZoneKey)
        objectWillChange.send()
    }

    // MARK: - Synchronous accessor (safe from any context)

    /// Reads the preferred time zone directly from UserDefaults without
    /// requiring a @MainActor context. Use this from synchronous, non-isolated
    /// code paths (e.g. RawStorage, static formatters).
    nonisolated static func currentTimeZone() -> TimeZone {
        guard let id = UserDefaults.standard.string(forKey: "preferredTimeZone"),
              let tz = TimeZone(identifier: id) else {
            return TimeZone.current
        }
        return tz
    }
}
