import Foundation
import DayPageStorage

// MARK: - LocalDataResetBlockReason

/// Why the "Clear local data" danger action is refused. Deliberately narrow:
/// every case is a state in which deleting the active vault (or any directory)
/// could destroy the user's only copy of their notes or wipe data that belongs
/// to a cloud-synced identity.
public enum LocalDataResetBlockReason: String, Sendable, Equatable {
    /// The active or canonical vault URL could not be resolved to a concrete
    /// path. Fail closed: when the target cannot be proven safe, delete nothing.
    case unresolvedVault
    /// The active vault is (or is configured to be) iCloud-backed. The iCloud
    /// copy is shared/replicated state and must never be deleted here.
    case iCloudVault
    /// The active vault is not the canonical local vault. Deleting any other
    /// directory is never substituted for deleting the real vault.
    case nonCanonicalVault
    /// A cloud account session is authenticated. The vault may hold data bound
    /// to that account that is pending upload, so a local wipe is refused.
    case authenticatedCloudAccount
}

// MARK: - LocalDataResetDecision

public enum LocalDataResetDecision: Sendable, Equatable {
    case allowed
    case blocked(LocalDataResetBlockReason)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var blockReason: LocalDataResetBlockReason? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

// MARK: - LocalDataResetPolicy

/// Fail-closed policy for the "Clear local data" danger action (issue #922).
///
/// The action may run ONLY when all of the following hold at the moment of
/// evaluation:
///   1. The active vault URL and the canonical local vault URL both resolve to
///      concrete paths and are equal after standardizing and resolving
///      symlinks (so `/var/...` vs `/private/var/...` cannot fake a mismatch —
///      or a match).
///   2. The active vault is not iCloud-backed and iCloud is not the configured
///      vault location (an iCloud locator can transiently fall back to the
///      local path while the container is unavailable — still refused).
///   3. No cloud account session is authenticated.
///
/// Anything else is blocked, and a blocked decision must mutate NOTHING:
/// not the vault, not keys, not preferences. Callers must re-evaluate via
/// `performIfAllowed(contextProvider:mutation:)` immediately before mutating so
/// a stale enabled-state in the view layer cannot bypass the policy.
public enum LocalDataResetPolicy {

    /// Locator identity is stable even while iCloud availability changes.
    public enum LocatorKind: Sendable, Equatable {
        case local, iCloud, unknown
    }

    /// Live state snapshot evaluated by the policy. The app builds this from
    /// the active `VaultLocator`, `AppSettings`, and the auth session; tests
    /// construct it directly.
    public struct Context: Sendable, Equatable {
        /// The vault the app would actually delete (`VaultInitializer.vaultURL`).
        public var activeVaultURL: URL
        /// The only directory the action is ever allowed to delete
        /// (`LocalVaultLocator().vaultURL`).
        public var canonicalLocalVaultURL: URL
        /// Never infer this from `isUsingiCloud`: iCloud can temporarily
        /// report false and fall back to the local URL during daemon startup.
        public var locatorKind: LocatorKind
        /// The user's configured vault location (`AppSettings.vaultLocation`).
        public var vaultLocationPreference: VaultLocation
        /// True while an authenticated cloud account session exists.
        public var hasAuthenticatedCloudAccount: Bool

        public init(
            activeVaultURL: URL,
            canonicalLocalVaultURL: URL,
            locatorKind: LocatorKind,
            vaultLocationPreference: VaultLocation,
            hasAuthenticatedCloudAccount: Bool
        ) {
            self.activeVaultURL = activeVaultURL
            self.canonicalLocalVaultURL = canonicalLocalVaultURL
            self.locatorKind = locatorKind
            self.vaultLocationPreference = vaultLocationPreference
            self.hasAuthenticatedCloudAccount = hasAuthenticatedCloudAccount
        }
    }

    // MARK: Evaluation

    public static func evaluate(_ context: Context) -> LocalDataResetDecision {
        guard let activePath = normalizedPath(context.activeVaultURL),
              let canonicalPath = normalizedPath(context.canonicalLocalVaultURL) else {
            return .blocked(.unresolvedVault)
        }
        if context.hasAuthenticatedCloudAccount {
            return .blocked(.authenticatedCloudAccount)
        }
        if context.locatorKind == .iCloud || context.vaultLocationPreference == .iCloud {
            return .blocked(.iCloudVault)
        }
        guard context.locatorKind == .local else {
            return .blocked(.nonCanonicalVault)
        }
        guard activePath == canonicalPath else {
            return .blocked(.nonCanonicalVault)
        }
        return .allowed
    }

    /// The only sanctioned mutation entry point. Re-evaluates the policy from a
    /// FRESH context immediately before mutating — the view's enabled-state is
    /// advisory only and can be stale (account signed in, vault migrated, or
    /// locator hot-swapped after the button was drawn).
    ///
    /// On a blocked decision `mutation` is never invoked, so vault, keys and
    /// preferences are preserved by construction. `@MainActor` because the
    /// mutation targets are UI-owned wipes; the decision logic itself is the
    /// nonisolated `evaluate(_:)` above.
    @MainActor
    @discardableResult
    public static func performIfAllowed(
        contextProvider: () -> Context,
        mutation: (URL) -> Void
    ) -> LocalDataResetDecision {
        var context = contextProvider()
        // Freeze the exact resolved deletion target. The caller must not
        // consult the live locator again after authorization.
        context.activeVaultURL = context.activeVaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let decision = evaluate(context)
        guard decision.isAllowed else { return decision }
        mutation(context.activeVaultURL)
        return decision
    }

    // MARK: URL normalization

    /// Standardizes and resolves symlinks, then strips trailing separators.
    /// Returns nil for non-file URLs, empty paths, or a filesystem root — all
    /// of which must fail closed instead of being compared loosely.
    static func normalizedPath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        guard path.count > 1, path.hasPrefix("/") else { return nil }
        return path
    }
}
