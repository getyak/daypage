import Foundation
import DayPageModels

public struct SyncRemoteChange: Decodable, Equatable, Sendable {
    public struct Location: Decodable, Equatable, Sendable {
        public let name: String?
        public let address: String?
        public let lat: Double?
        public let lng: Double?
    }

    public struct Weather: Decodable, Equatable, Sendable {
        public let condition: String?

        private enum CodingKeys: String, CodingKey {
            case condition
            case weather
        }

        public init(from decoder: Decoder) throws {
            if let scalar = try? decoder.singleValueContainer(),
               let value = try? scalar.decode(String.self) {
                condition = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            condition = try container.decodeIfPresent(String.self, forKey: .condition)
                ?? container.decodeIfPresent(String.self, forKey: .weather)
        }
    }

    public let id: UUID
    public let type: String
    public let body: String
    public let createdAt: Date
    public let pinnedAt: Date?
    public let location: Location?
    public let weather: Weather?
    public let device: String?
    public let source: String
    public let vaultPath: String?
    public let sourceModifiedAt: Date?
    public let contentHash: String?
    public let syncRevision: Int64
    public let lastSyncDeviceId: String?
    public let deletedAt: Date?
    public let changeSequence: Int64
    public let attachmentManifestHash: String?
    public let attachments: [SyncAttachmentDescriptor]?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case body
        case createdAt = "created_at"
        case pinnedAt = "pinned_at"
        case location
        case weather
        case device
        case source
        case vaultPath = "vault_path"
        case sourceModifiedAt = "source_modified_at"
        case contentHash = "content_hash"
        case syncRevision = "sync_revision"
        case lastSyncDeviceId = "last_sync_device_id"
        case deletedAt = "deleted_at"
        case changeSequence = "change_sequence"
        case attachmentManifestHash = "attachment_manifest_hash"
        case attachments
    }

    public init(
        id: UUID,
        type: String,
        body: String,
        createdAt: Date,
        pinnedAt: Date?,
        location: Location?,
        weather: Weather?,
        device: String?,
        source: String,
        vaultPath: String?,
        sourceModifiedAt: Date?,
        contentHash: String?,
        syncRevision: Int64,
        lastSyncDeviceId: String?,
        deletedAt: Date?,
        changeSequence: Int64,
        attachmentManifestHash: String? = nil,
        attachments: [SyncAttachmentDescriptor]? = nil
    ) {
        self.id = id
        self.type = type
        self.body = body
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
        self.location = location
        self.weather = weather
        self.device = device
        self.source = source
        self.vaultPath = vaultPath
        self.sourceModifiedAt = sourceModifiedAt
        self.contentHash = contentHash
        self.syncRevision = syncRevision
        self.lastSyncDeviceId = lastSyncDeviceId
        self.deletedAt = deletedAt
        self.changeSequence = changeSequence
        self.attachmentManifestHash = attachmentManifestHash
        self.attachments = attachments
    }

    public var isDeleted: Bool { deletedAt != nil }

    public func makeMemo(preservingLocalMetadata local: Memo? = nil) -> Memo {
        let memoType: Memo.MemoType
        switch type {
        case "voice": memoType = .voice
        case "photo": memoType = .photo
        default: memoType = .text
        }
        let remoteAttachments: [Memo.Attachment]
        if attachmentManifestHash != nil {
            remoteAttachments = (attachments ?? [])
                .sorted { $0.position < $1.position }
                .map { descriptor in
                    Memo.Attachment(
                        file: AttachmentTransferStore.localPath(
                            memoID: id,
                            objectKey: descriptor.objectKey,
                            fallback: descriptor
                        ),
                        kind: descriptor.kind,
                        duration: descriptor.durationMilliseconds.map { Double($0) / 1_000 },
                        transcript: descriptor.transcript,
                        transcriptionStatus: descriptor.transcriptionStatus.flatMap {
                            Memo.TranscriptionStatus(rawValue: $0)
                        }
                    )
                }
        } else {
            // Protocol-v1 rows did not carry an authoritative attachment
            // manifest, so retain the local metadata during mixed-version rollout.
            remoteAttachments = local?.attachments ?? []
        }
        return Memo(
            id: id,
            type: memoType,
            created: createdAt,
            pinnedAt: pinnedAt,
            location: location.map {
                Memo.Location(name: $0.name ?? $0.address, lat: $0.lat, lng: $0.lng)
            },
            weather: weather?.condition,
            device: device,
            attachments: remoteAttachments,
            mood: local?.mood,
            entityMentions: local?.entityMentions ?? [],
            marginNote: local?.marginNote,
            body: body
        )
    }
}

public struct SyncPullPage: Decodable, Equatable, Sendable {
    public let changes: [SyncRemoteChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case changes
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    /// A malformed page must never advance the durable cursor past a change
    /// that was not applied locally. The RPC promises strict sequence order
    /// and sets `next_cursor` to the final returned sequence.
    public func isValid(after cursor: Int64) -> Bool {
        guard changes.allSatisfy({ change in
            if change.isDeleted {
                return change.attachmentManifestHash == nil
                    && (change.attachments ?? []).isEmpty
            }
            guard let expected = change.attachmentManifestHash else {
                return change.attachments == nil || change.attachments?.isEmpty == true
            }
            let descriptors = change.attachments ?? []
            return AttachmentManifest.isStructurallyValid(descriptors)
                && AttachmentManifest.hash(descriptors) == expected
        }) else {
            return false
        }
        let sequences = changes.map(\.changeSequence)
        guard nextCursor >= cursor,
              sequences == sequences.sorted(),
              Set(sequences).count == sequences.count,
              !sequences.contains(where: { $0 <= cursor }) else {
            return false
        }
        guard let last = sequences.last else {
            return nextCursor == cursor && !hasMore
        }
        return nextCursor == last
    }
}

public struct SyncRemoteApplyResult: Equatable, Sendable {
    public let appliedCount: Int
    public let deletedCount: Int
    public let conflictCopies: [UUID]

    public init(appliedCount: Int, deletedCount: Int, conflictCopies: [UUID]) {
        self.appliedCount = appliedCount
        self.deletedCount = deletedCount
        self.conflictCopies = conflictCopies
    }
}

public protocol RemotePuller: Sendable {
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage

    /// Optional account-tag metadata capability (#884). Source-compatible:
    /// conformers that do not implement it keep the default below. A `nil`
    /// reader means METADATA UNAVAILABLE — it is never a complete empty
    /// catalogue and never satisfies full-sync completion.
    var accountTagsReader: RemoteAccountTagsReader? { get }
}

public extension RemotePuller {
    var accountTagsReader: RemoteAccountTagsReader? { nil }
}

/// Incremental, user-session-backed reader for the monotonic Supabase change
/// sequence. The same user access token used for push is passed through RLS.
public struct SupabaseSyncPuller: RemotePuller {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private struct RequestBody: Encodable {
        let afterSequence: Int64
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case afterSequence = "p_after_sequence"
            case limit = "p_limit"
        }
    }

    public let session: SyncSession
    public let endpoint: URL
    public let anonKey: String
    public let transport: HTTPTransport
    public let attachmentDownloader: SupabaseAttachmentDownloader
    /// Session-scoped executor: every request START linearizes with the lease.
    public let network: SyncSessionNetwork
    public let accessTokenProvider: AccessTokenProvider

    private var lease: SyncSessionLease { session.lease }

    /// Pull and media obligations share the SAME verified session as push.
    /// Transport defaults to the redirect-refusing sync transport.
    public init(
        session: SyncSession,
        transport: HTTPTransport? = nil,
        fileTransport: AttachmentFileTransport? = nil,
        accessTokenProvider: @escaping AccessTokenProvider
    ) {
        self.session = session
        let configuration = session.context.configuration
        let realmTransport = SupabaseSyncTransport.shared(for: session.identity.origin)
        self.endpoint = configuration.url
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rpc", isDirectory: true)
            .appendingPathComponent("daypage_pull_sync_changes_v2")
        self.anonKey = configuration.publishableKey
        self.transport = transport ?? realmTransport
        let resolvedFileTransport = fileTransport ?? realmTransport
        self.network = SyncSessionNetwork(
            lease: session.lease,
            dataTransport: self.transport,
            fileTransport: resolvedFileTransport
        )
        self.attachmentDownloader = SupabaseAttachmentDownloader(
            session: session,
            fileTransport: resolvedFileTransport
        )
        self.accessTokenProvider = accessTokenProvider
    }

    /// Same-session account-tag reader capability: the SAME verified session,
    /// exact-token proof and redirect-refusing transport as push/pull. The
    /// Auth/session installers stay untouched (no second configuration).
    public var accountTagsReader: RemoteAccountTagsReader? {
        SupabaseAccountTagsReader(
            session: session,
            transport: transport,
            accessTokenProvider: accessTokenProvider
        )
    }

    public func pull(after cursor: Int64, limit: Int = 200) async throws -> SyncPullPage {
        #if !DEBUG
        guard endpoint.scheme?.lowercased() == "https" else {
            throw MemoSyncError.insecureScheme
        }
        #endif
        guard !anonKey.isEmpty else { throw MemoSyncError.notConfigured }
        // Session-scoped exact-token proof: any new token value needs local
        // claim checks AND same-origin `/auth/v1/user` success before it can
        // drive any durable preparation or mutation.
        let rawToken = try await accessTokenProvider()
        guard !rawToken.isEmpty else { throw MemoSyncError.unauthorized }
        let token = try await session.tokens.verifiedToken(rawToken)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(RequestBody(
            afterSequence: max(0, cursor),
            limit: min(max(limit, 1), 500)
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await network.data(for: request)
        // Re-check before consuming the page.
        try lease.assertValid()
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: value) { return date }
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                if let date = standard.date(from: value) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            do {
                let page = try decoder.decode(SyncPullPage.self, from: data)
                guard page.isValid(after: max(0, cursor)) else {
                    throw MemoSyncError.invalidResponse
                }
                // Persist all media obligations before the caller is allowed
                // to apply the page and advance its durable cursor. Individual
                // media failures remain retryable sidecar state.
                try await attachmentDownloader.persistAndAttempt(
                    changes: page.changes,
                    token: token
                )
                return page
            } catch {
                if let memoError = error as? MemoSyncError {
                    throw memoError
                }
                throw MemoSyncError.invalidResponse
            }
        case 401:
            throw MemoSyncError.unauthorized
        case 403:
            throw MemoSyncError.forbidden
        case 429:
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw MemoSyncError.rateLimited(retryAfter: retry)
        default:
            throw MemoSyncError.serverError(status: http.statusCode)
        }
    }
}
