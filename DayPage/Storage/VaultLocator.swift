import Foundation

// MARK: - VaultLocator

/// Abstracts the storage backend so the vault path can be swapped at runtime
/// without touching individual call sites.
protocol VaultLocator {
    var vaultURL: URL { get }
    var isUsingiCloud: Bool { get }
}

// MARK: - LocalVaultLocator

/// Default implementation: stores vault under the app's local Documents directory.
/// Behavior is identical to the previous hard-coded VaultInitializer.vaultURL.
struct LocalVaultLocator: VaultLocator {
    // FileManager.urls(for:) is safe to call repeatedly but allocates on every
    // call. Cache the result once at the static level — the Documents path never
    // changes within a process lifetime.
    private static let _localDocuments: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vault", isDirectory: true)

    var vaultURL: URL { Self._localDocuments }

    var isUsingiCloud: Bool { false }
}

// MARK: - iCloudVaultLocator

/// iCloud Drive implementation: stores vault under the app's ubiquity container.
/// Falls back gracefully when iCloud is unavailable (e.g., Simulator without account).
struct iCloudVaultLocator: VaultLocator {
    let containerID = "iCloud.com.daypage.app"

    private static let _ubiquityContainer: URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.daypage.app")
    }()

    var vaultURL: URL {
        Self._ubiquityContainer?
            .appendingPathComponent("Documents/vault", isDirectory: true)
            ?? LocalVaultLocator().vaultURL
    }

    var isUsingiCloud: Bool {
        Self._ubiquityContainer != nil
    }
}
