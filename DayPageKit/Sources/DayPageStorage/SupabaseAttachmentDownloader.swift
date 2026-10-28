import Foundation

/// Persists every remote media obligation before attempting network transfer.
/// A failed or cellular-deferred download therefore cannot be forgotten when
/// the memo cursor advances.
public struct SupabaseAttachmentDownloader: Sendable {
    public let session: SyncSession
    public let supabaseURL: URL
    public let anonKey: String
    public let fileTransport: AttachmentFileTransport
    /// Session-scoped executor: every request START linearizes with the lease.
    public let network: SyncSessionNetwork

    private var lease: SyncSessionLease { session.lease }
    private var realm: SyncRealmIdentity { session.identity }

    /// Downloads share the uploader/puller session: same verified origin,
    /// key and user, same generation lease. Transport defaults to the
    /// redirect-refusing sync transport.
    public init(
        session: SyncSession,
        fileTransport: AttachmentFileTransport? = nil
    ) {
        self.session = session
        let configuration = session.context.configuration
        self.supabaseURL = configuration.url
        self.anonKey = configuration.publishableKey
        let resolvedFileTransport = fileTransport
            ?? SupabaseSyncTransport.shared(for: session.identity.origin)
        self.fileTransport = resolvedFileTransport
        self.network = SyncSessionNetwork(
            lease: session.lease,
            fileTransport: resolvedFileTransport
        )
    }

    /// Commit gate: check + effect linearize together against invalidation.
    private func commit<T>(_ body: () throws -> T) throws -> T {
        try lease.withValidity(body)
    }

    public func persistAndAttempt(
        changes: [SyncRemoteChange],
        token: SyncVerifiedAccessToken
    ) async throws {
        let deletedMemoIDs = Set(changes.filter(\.isDeleted).map(\.id))
        try commit {
            try AttachmentTransferStore.discardTransfers(
                memoIDs: deletedMemoIDs,
                realm: realm
            )
        }
        var pending: [AttachmentDownloadItem] = []
        for change in changes where !change.isDeleted {
            let descriptors = change.attachments ?? []
            let recorded = try commit {
                try AttachmentTransferStore.recordPendingDownloads(
                    memoID: change.id,
                    descriptors: descriptors,
                    realm: realm
                )
            }
            pending.append(contentsOf: recorded)
        }
        pending.append(contentsOf: try AttachmentTransferStore.pendingDownloads(realm: realm))
        var seenRecordIDs = Set<String>()
        pending = pending.filter { seenRecordIDs.insert($0.recordID).inserted }

        // A transfer failure is durable state, not a reason to discard the
        // already-persisted memo page. Continue independent attachments.
        for item in pending {
            do {
                try await install(item, token: token)
            } catch {
                // Old catch blocks never overwrite a replaced session's
                // transfer state: the commit gate refuses once invalidated.
                try? commit {
                    try AttachmentTransferStore.update(
                        recordID: item.recordID,
                        status: .failed,
                        realm: realm,
                        error: downloadErrorCode(error)
                    )
                }
            }
        }
    }

    private func downloadErrorCode(_ error: Error) -> String {
        switch error {
        case AttachmentSyncError.integrityMismatch,
             AttachmentSyncError.localFileChanged:
            return "integrity_mismatch"
        case AttachmentSyncError.transferFailed:
            return "http_transfer"
        default:
            return "download_failed"
        }
    }

    private func install(
        _ item: AttachmentDownloadItem,
        token: SyncVerifiedAccessToken
    ) async throws {
        let vaultCandidate = VaultInitializer.vaultURL
            .appendingPathComponent(item.relativePath).standardizedFileURL
        if FileManager.default.fileExists(atPath: vaultCandidate.path) {
            do {
                let existing = try AttachmentFileInspector.safeLocalURL(
                    relativePath: item.relativePath
                )
                try AttachmentFileInspector.verify(
                    url: existing,
                    descriptor: item.descriptor
                )
            } catch {
                // Never overwrite a different local file, even at the
                // deterministic SHA-prefixed target.
                throw AttachmentSyncError.integrityMismatch(vaultCandidate.lastPathComponent)
            }
            try commit {
                try AttachmentTransferStore.markDownloadInstalled(
                    recordID: item.recordID,
                    realm: realm
                )
            }
            return
        }
        let destination = try destinationURL(relativePath: item.relativePath)
        let stagingURL = try validatedWriteURL(Self.stagingURL(recordID: item.recordID))
        // Every persistent staging mutation (directory create, partial
        // cleanup, copy) commits inside the generation gate. On a stale lease
        // existing partials are preserved, never deleted.
        try commit {
            _ = try validatedWriteURL(stagingURL)
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            let stagingVerified = (try? AttachmentFileInspector.verify(
                url: stagingURL,
                descriptor: item.descriptor
            )) != nil
            if stagingVerified {
                // Media install is a durable effect: moving into the Vault and
                // closing the obligation commit inside the generation gate.
                try commit {
                    _ = try validatedWriteURL(stagingURL)
                    _ = try validatedWriteURL(destination)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: stagingURL, to: destination)
                    try AttachmentTransferStore.markDownloadInstalled(
                        recordID: item.recordID,
                        realm: realm
                    )
                }
                return
            }
            // Cleanup of an invalid partial is itself a durable mutation; a
            // refused (stale) cleanup preserves the bytes untouched.
            try? commit {
                _ = try validatedWriteURL(stagingURL)
                try FileManager.default.removeItem(at: stagingURL)
            }
        }

        try commit {
            try AttachmentTransferStore.update(
                recordID: item.recordID,
                status: .transferring,
                realm: realm
            )
        }
        let url = supabaseURL
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("object", isDirectory: true)
            .appendingPathComponent("authenticated", isDirectory: true)
            .appendingPathComponent("memo-attachments", isDirectory: true)
            .appendingPathComponent(item.descriptor.objectKey)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 180
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = AttachmentNetworkPolicy.allowsCellularTransfers
        try lease.assertValid()
        let (temporaryURL, response) = try await network.downloadFile(for: request)
        // The transport hands over an OWNED transient copy; it is transient
        // transport data and must be cleaned on every exit path (success,
        // failure or stale lease) — never left as a Vault obligation.
        defer { SyncNetworkTempFile.discard(temporaryURL) }
        // Re-check before consuming the downloaded bytes.
        try lease.assertValid()
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AttachmentSyncError.transferFailed(status: http.statusCode)
        }

        try commit {
            _ = try validatedWriteURL(stagingURL)
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: temporaryURL, to: stagingURL)
        }
        do {
            try AttachmentFileInspector.verify(url: stagingURL, descriptor: item.descriptor)
        } catch {
            // Cleanup is gated too: a stale lease preserves the partial.
            try? commit {
                _ = try validatedWriteURL(stagingURL)
                try FileManager.default.removeItem(at: stagingURL)
            }
            throw error
        }
        // Verified staging survives a refused commit as resumable progress;
        // nothing unverified or foreign is ever moved into the Vault.
        try commit {
            _ = try validatedWriteURL(stagingURL)
            _ = try validatedWriteURL(destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            try AttachmentTransferStore.markDownloadInstalled(
                recordID: item.recordID,
                realm: realm
            )
        }
    }

    private func destinationURL(relativePath: String) throws -> URL {
        guard relativePath.hasPrefix("raw/assets/sync/"),
              !relativePath.contains(".."),
              !relativePath.contains("//") else {
            throw AttachmentSyncError.invalidPath(relativePath)
        }
        let vault = VaultInitializer.vaultURL.standardizedFileURL
        let assets = vault.appendingPathComponent("raw/assets", isDirectory: true)
            .standardizedFileURL
        let destination = vault.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = assets.path.hasSuffix("/") ? assets.path : assets.path + "/"
        guard destination.path.hasPrefix(prefix) else {
            throw AttachmentSyncError.invalidPath(relativePath)
        }
        return try validatedWriteURL(destination)
    }

    /// Write paths may have missing leaves, but every existing entry below
    /// the selected Vault must be real. Reading verified bytes through a
    /// symlink does not authorize moving that link or writing through its
    /// ancestors. Recheck inside each durable commit after network waits.
    private func validatedWriteURL(_ url: URL) throws -> URL {
        try AttachmentFileInspector.safeWriteURL(url)
    }

    static func stagingURL(recordID: String) -> URL {
        let safeID = recordID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return VaultInitializer.vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("\(String(safeID)).partial")
    }
}
