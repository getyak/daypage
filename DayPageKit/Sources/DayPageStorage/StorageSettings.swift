import Foundation

// MARK: - Vault Location

/// Where the user's vault lives. Stored as the raw string under
/// `AppSettings.Keys.vaultLocation`. Defined in Storage (not Services/Config)
/// because `VaultInitializer` needs to read it during launch before any
/// Services target code is reachable.
public enum VaultLocation: String, Sendable {
    case local = "local"
    case iCloud = "iCloud"
}

// MARK: - Attachment Policy

/// How aggressively attachments are kept on-device when the vault is
/// iCloud-backed. Stored as the raw string under
/// `AppSettings.Keys.attachmentPolicy`.
public enum AttachmentPolicy: String, Sendable {
    case onDemand = "onDemand"
    case alwaysLocal = "alwaysLocal"
}

// MARK: - StorageSettings

/// Storage-layer subset of `AppSettings`: read-only accessors for user
/// preferences that the Storage code path needs but cannot reach (AppSettings
/// lives in DayPageServices/Config which depends on DayPageStorage, so a
/// reverse import would cycle).
///
/// Behavior contract: every accessor reads the SAME `UserDefaults.standard`
/// key that `AppSettings` writes from the Settings UI, so swapping out the
/// read site does not change observable behavior.
public enum StorageSettings {

    // MARK: Keys (mirror AppSettings.Keys — must stay in sync)

    public static let preferredTimeZoneKey = "preferredTimeZone"
    public static let vaultLocationKey = "vaultLocation"
    public static let attachmentPolicyKey = "attachmentPolicy"
    public static let debugSimulateOfflineKey = "debug.simulateOffline"

    // MARK: Accessors

    /// Returns the user's preferred TimeZone, falling back to `TimeZone.current`
    /// when the preference is unset or invalid. Used by `RawStorage` to derive
    /// the YYYY-MM-DD day filename — must match `AppSettings.currentTimeZone()`
    /// exactly so iOS and Storage agree on day boundaries.
    public static func currentTimeZone() -> TimeZone {
        guard let id = UserDefaults.standard.string(forKey: preferredTimeZoneKey),
              let tz = TimeZone(identifier: id) else {
            return TimeZone.current
        }
        return tz
    }

    /// Returns the user's chosen vault location, defaulting to `.local`.
    public static func currentVaultLocation() -> VaultLocation {
        guard let raw = UserDefaults.standard.string(forKey: vaultLocationKey),
              let loc = VaultLocation(rawValue: raw) else {
            return .local
        }
        return loc
    }

    /// Returns the user's attachment download policy, defaulting to `.onDemand`.
    public static func currentAttachmentPolicy() -> AttachmentPolicy {
        guard let raw = UserDefaults.standard.string(forKey: attachmentPolicyKey),
              let policy = AttachmentPolicy(rawValue: raw) else {
            return .onDemand
        }
        return policy
    }
}

// MARK: - InflightDraftRefsHook

/// Injection point for the iOS Today feature's `InflightDraftStore.pending()`.
/// The orphaned-attachment scanners in DayPageServices need to honor inflight
/// draft references (so the GC does not delete an attachment while the user
/// is mid-submit), but `InflightDraftStore` lives in the app target's
/// Features/Today layer which Kit cannot reach.
///
/// iOS registers a closure during app launch that returns the set of attachment
/// path strings currently referenced by inflight drafts. Scanners call
/// `InflightDraftRefsHook.referencedPaths()` and union the result into their
/// reference set. Returns empty when no provider is registered (test contexts,
/// pre-launch, etc.) — safe degradation, just means a stale draft attachment
/// could be GC'd; the user retry path already handles that case.
public enum InflightDraftRefsHook {
    public typealias Provider = @Sendable () -> Set<String>

    private static let lock = NSLock()
    private static var _provider: Provider?

    public static func register(_ provider: @escaping Provider) {
        lock.lock(); defer { lock.unlock() }
        _provider = provider
    }

    public static func referencedPaths() -> Set<String> {
        lock.lock()
        let p = _provider
        lock.unlock()
        return p?() ?? []
    }
}

// MARK: - VaultMigrationHook

/// Injection point for the iOS-only `VaultMigrationService`. The Storage layer
/// cannot reach `VaultMigrationService.shared.migrateIfNeeded()` directly
/// (Services → Storage is the only valid dep direction), so iOS registers a
/// closure at launch and Storage invokes it when the migration trigger fires.
///
/// Threading: the closure is invoked from `VaultInitializer` on an arbitrary
/// background queue; iOS callers should hop to `@MainActor` themselves.
public enum VaultMigrationHook {
    public typealias Handler = @Sendable () -> Void

    private static let lock = NSLock()
    private static var _handler: Handler?

    public static func register(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    /// Invoked by `VaultInitializer.triggerMigrationIfNeeded`. No-op when iOS
    /// has not registered yet (e.g. tests, headless contexts).
    public static func fire() {
        lock.lock()
        let h = _handler
        lock.unlock()
        h?()
    }
}
