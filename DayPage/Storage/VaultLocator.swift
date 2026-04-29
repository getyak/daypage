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

// MARK: - SyncBackend

/// Extension point for future remote sync backends (Supabase, Google Drive, etc.).
/// The iCloud path uses VaultLocator directly (filesystem-level sync handled by the OS);
/// this protocol covers backends that require explicit upload/download operations.
///
/// Upgrade path: local → iCloud → remote backend (one-way, no data loss on upgrade).
/// v4 target: SupabaseSyncBackend (requires AuthService.session).
protocol SyncBackend {
    /// Human-readable identifier shown in Settings (e.g. "iCloud", "Supabase").
    var displayName: String { get }

    /// Whether this backend is currently available (signed in, reachable, etc.).
    var isAvailable: Bool { get }

    /// Upload a single file from the local vault to the remote backend.
    /// Called after a successful local write when the backend requires explicit push.
    func upload(fileAt localURL: URL, relativePath: String) async throws

    /// Download a single file from the remote backend to the local vault.
    /// `relativePath` is relative to the vault root (e.g. "raw/2026-04-29.md").
    func download(relativePath: String, to localURL: URL) async throws

    /// List all files known to the backend, returning their relative paths and
    /// last-modified dates. Used for incremental sync diff.
    func listRemoteFiles() async throws -> [(relativePath: String, modifiedAt: Date)]
}
