import Foundation
import Combine

// MARK: - iCloudConflictMonitor

/// Monitors iCloud for files with unresolved conflicts and resolves them
/// automatically using ConflictMerger.
///
/// Listens to NSMetadataQuery updates for the `.ubiquitousItemHasUnresolvedConflictsKey`
/// attribute, then delegates to `ConflictMerger.resolveConflictsIfNeeded(in:)`.
/// Posts `.vaultConflictResolved` notifications so the UI layer can show a banner.
@MainActor
final class iCloudConflictMonitor: ObservableObject {

    static let shared = iCloudConflictMonitor()
    private init() {}

    // MARK: - Published State

    /// Number of currently unresolved conflicts observed.
    @Published var unresolvedConflictCount: Int = 0

    /// Whether a conflict resolution pass is in progress.
    @Published var isResolving: Bool = false

    /// The most recent conflict resolution info (for UI banners).
    @Published var lastResolution: ConflictResolutionInfo?

    // MARK: - Private

    private var query: NSMetadataQuery?
    private var vaultURL: URL?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Monitoring

    /// Start monitoring conflict status for the given vault URL.
    /// Call this once after VaultInitializer is configured and iCloud is available.
    /// When iCloud is not in use, this is a no-op.
    func startMonitoring(vaultURL: URL) {
        let locator = iCloudVaultLocator()
        guard locator.isUsingiCloud else { return }

        self.vaultURL = vaultURL

        // Listen for the resolution notification to publish lastResolution.
        NotificationCenter.default.publisher(for: .vaultConflictResolved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let info = notification.object as? ConflictResolutionInfo else { return }
                self.lastResolution = info
            }
            .store(in: &cancellables)

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K BEGINSWITH %@",
                                  NSMetadataItemPathKey,
                                  vaultURL.path)
        // Batch updates for performance.
        q.notificationBatchingInterval = 2.0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: q
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: q
        )

        self.query = q
        q.start()
    }

    func stopMonitoring() {
        query?.stop()
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
        query = nil
        vaultURL = nil
    }

    // MARK: - Query Handlers

    @objc private nonisolated func queryDidUpdate(_ notification: Notification) {
        Task { @MainActor in self.processConflicts() }
    }

    @objc private nonisolated func queryDidFinishGathering(_ notification: Notification) {
        Task { @MainActor in self.processConflicts() }
    }

    // MARK: - Conflict Processing

    /// Scans query results for files with unresolved conflicts and triggers resolution.
    private func processConflicts() {
        guard !isResolving, let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        var count = 0
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem else { continue }
            let hasConflicts = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool ?? false
            if hasConflicts { count += 1 }
        }

        unresolvedConflictCount = count

        guard count > 0, let vaultURL = vaultURL else { return }

        isResolving = true
        defer { isResolving = false }

        ConflictMerger.resolveConflictsIfNeeded(in: vaultURL)
    }
}
