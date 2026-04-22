import Foundation
import Combine

// MARK: - SyncStatus

enum SyncStatus {
    case notConfigured
    case connected(lastSync: Date?)
    case syncing(pendingFiles: Int)
    case error(message: String)
}

// MARK: - iCloudSyncMonitor

@MainActor
final class iCloudSyncMonitor: ObservableObject {

    static let shared = iCloudSyncMonitor()
    private init() {}

    @Published var status: SyncStatus = .notConfigured
    @Published var pendingUploadCount: Int = 0
    @Published var pendingDownloadCount: Int = 0

    private var query: NSMetadataQuery?
    private var vaultPathPrefix: String?
    private var lastSyncDate: Date?

    // MARK: - Monitoring

    func startMonitoring(vaultURL: URL) {
        guard VaultInitializer.shared.isUsingiCloud else {
            status = .notConfigured
            return
        }

        vaultPathPrefix = vaultURL.path

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Predicate filters to files whose path starts with the vault directory
        q.predicate = NSPredicate(format: "%K BEGINSWITH %@",
                                  NSMetadataItemPathKey,
                                  vaultURL.path)
        q.notificationBatchingInterval = 1.0

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
        query = nil
    }

    // MARK: - Query Handlers

    @objc private nonisolated func queryDidUpdate(_ notification: Notification) {
        Task { @MainActor in self.processQueryResults() }
    }

    @objc private nonisolated func queryDidFinishGathering(_ notification: Notification) {
        Task { @MainActor in self.processQueryResults() }
    }

    private func processQueryResults() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        var uploadCount = 0
        var downloadCount = 0

        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem else { continue }

            let isUploading = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool ?? false
            let isDownloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false

            if isUploading { uploadCount += 1 }
            if isDownloading { downloadCount += 1 }
        }

        pendingUploadCount = uploadCount
        pendingDownloadCount = downloadCount

        let total = uploadCount + downloadCount
        if total > 0 {
            status = .syncing(pendingFiles: total)
        } else {
            lastSyncDate = Date()
            status = .connected(lastSync: lastSyncDate)
        }
    }
}
