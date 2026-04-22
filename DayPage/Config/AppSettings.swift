import Foundation

// MARK: - VaultLocation

enum VaultLocation: String {
    case local = "local"
    case iCloud = "iCloud"
}

// MARK: - AttachmentPolicy

enum AttachmentPolicy: String {
    case onDemand = "onDemand"
    case alwaysLocal = "alwaysLocal"
}

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

    // MARK: - Vault Location

    private let vaultLocationKey = "vaultLocation"

    /// Where the vault is stored. Defaults to .local.
    var vaultLocation: VaultLocation {
        get {
            guard let raw = UserDefaults.standard.string(forKey: vaultLocationKey),
                  let loc = VaultLocation(rawValue: raw) else {
                return .local
            }
            return loc
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: vaultLocationKey)
        }
    }

    // MARK: - Attachment Policy

    private let attachmentPolicyKey = "attachmentPolicy"

    /// How iCloud attachments are downloaded. Defaults to .onDemand.
    var attachmentPolicy: AttachmentPolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: attachmentPolicyKey),
                  let policy = AttachmentPolicy(rawValue: raw) else {
                return .onDemand
            }
            return policy
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: attachmentPolicyKey)
        }
    }

    // MARK: - Migration Completed At

    private let migrationCompletedAtKey = "migrationCompletedAt"

    /// The date when migration to iCloud completed. Nil if not migrated.
    var migrationCompletedAt: Date? {
        get {
            UserDefaults.standard.object(forKey: migrationCompletedAtKey) as? Date
        }
        set {
            objectWillChange.send()
            if let date = newValue {
                UserDefaults.standard.set(date, forKey: migrationCompletedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: migrationCompletedAtKey)
            }
        }
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

    /// Reads the attachment policy directly from UserDefaults without requiring
    /// a @MainActor context. Use from VaultInitializer or other non-isolated code.
    nonisolated static func currentAttachmentPolicy() -> AttachmentPolicy {
        guard let raw = UserDefaults.standard.string(forKey: "attachmentPolicy"),
              let policy = AttachmentPolicy(rawValue: raw) else {
            return .onDemand
        }
        return policy
    }

    /// Reads the vault location directly from UserDefaults without requiring
    /// a @MainActor context. Use from VaultInitializer or other non-isolated code.
    nonisolated static func currentVaultLocation() -> VaultLocation {
        guard let raw = UserDefaults.standard.string(forKey: "vaultLocation"),
              let loc = VaultLocation(rawValue: raw) else {
            return .local
        }
        return loc
    }
}
