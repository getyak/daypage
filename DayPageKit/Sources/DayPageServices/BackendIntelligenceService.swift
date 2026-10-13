import Foundation
import DayPageStorage

/// Native projection of the backend-first intelligence plane. Raw capture
/// remains in `vault/raw`; this service only stores a replaceable projection
/// under `vault/_agent/cache` and never mutates legacy `vault/wiki` files.
@MainActor
public final class BackendIntelligenceService: ObservableObject {
    public static let shared = BackendIntelligenceService()

    private struct CacheEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let accountID: UUID
        let refreshedAt: Date
        let artifacts: [RemoteDerivedArtifact]
    }

    @Published public private(set) var artifacts: [RemoteDerivedArtifact] = []
    @Published public private(set) var lastRefreshAt: Date?
    @Published public private(set) var lastError: String?

    private var remote: DerivedArtifactRemote?
    private var accountID: UUID?
    private var refreshTask: Task<Void, Never>?

    /// Live authorization policy for backend authoring requests (issue #928).
    /// Daily/weekly reducer requests are NEW AI work and check it before the
    /// sync flush and again after the awaited flush, before the remote call.
    private let consent: AIConsentChecking
    /// Injectable sync-queue flush seam. Production flushes the durable sync
    /// queue; tests inject a recorder so OFF paths can prove zero flush.
    private let syncFlush: @Sendable () async -> Void

    public init(
        consent: AIConsentChecking = LiveAIConsent(),
        syncFlush: @escaping @Sendable () async -> Void = { await SyncQueueObserver.shared.flush() }
    ) {
        self.consent = consent
        self.syncFlush = syncFlush
    }

    /// True while a derived-refresh schedule is armed. Exposed so consent
    /// tests can prove OFF schedules zero refreshes without waiting on timers.
    public var isRefreshScheduled: Bool { refreshTask != nil }

    public var isConfigured: Bool { remote != nil && accountID != nil }

    public func configure(remote: DerivedArtifactRemote, accountID: UUID) {
        refreshTask?.cancel()
        self.remote = remote
        self.accountID = accountID
        if let cached = Self.readCache(), cached.accountID == accountID {
            artifacts = cached.artifacts
            lastRefreshAt = cached.refreshedAt
        } else {
            artifacts = []
            lastRefreshAt = nil
        }
        lastError = nil
    }

    public func clearSession() {
        refreshTask?.cancel()
        refreshTask = nil
        remote = nil
        accountID = nil
        artifacts = []
        lastRefreshAt = nil
        lastError = nil
    }

    /// Refreshes the local read model after an authenticated sync pass. Cache
    /// replacement is atomic; a partial response can never erase the last
    /// known-good projection.
    public func refresh() async throws {
        guard let remote, let accountID else { throw MemoSyncError.notConfigured }
        let fetched = try await remote.fetchCanonicalArtifacts(limit: 1_000)
        let now = Date()
        try await Task.detached(priority: .utility) {
            try Self.writeCache(
                CacheEnvelope(
                    schemaVersion: 2,
                    accountID: accountID,
                    refreshedAt: now,
                    artifacts: fetched
                )
            )
        }.value
        artifacts = fetched
        lastRefreshAt = now
        lastError = nil
    }

    @discardableResult
    public func requestDaily(
        localDate: String,
        timezone: String,
        force: Bool
    ) async throws -> UUID {
        guard let remote else { throw MemoSyncError.notConfigured }
        // Issue #928: authoring requests are new AI work — checked BEFORE the
        // sync flush so an OFF master switch causes zero flush.
        try consent.authorize()
        // Raw operations must be acknowledged before the reducer request. The
        // memo revision trigger then places understanding jobs ahead of the
        // debounced Daily job in the same durable queue.
        await syncFlush()
        // Checked AGAIN after the awaited flush: a toggle flip during the
        // flush must cause zero remote request.
        try consent.authorize()
        let jobID = try await remote.requestDaily(
            localDate: localDate,
            timezone: timezone,
            finalize: false,
            explicitRetry: force
        )
        scheduleRefresh()
        return jobID
    }

    @discardableResult
    public func requestWeekly(
        weekStart: String,
        timezone: String,
        force: Bool
    ) async throws -> UUID {
        guard let remote else { throw MemoSyncError.notConfigured }
        try consent.authorize()
        await syncFlush()
        try consent.authorize()
        let jobID = try await remote.requestWeekly(
            weekStart: weekStart,
            timezone: timezone,
            explicitRetry: force
        )
        scheduleRefresh()
        return jobID
    }

    /// Markdown projection suitable for the existing Daily parser. This is a
    /// view adapter only; it is generated in memory from the canonical
    /// artifact and is never written into `vault/wiki/daily`.
    public func dailyMarkdown(for localDate: String) -> String? {
        guard let artifact = latest(kind: "daily_page", localDate: localDate),
              let body = artifact.bodyMarkdown else { return nil }
        let headline = artifact.payload["headline"]?.stringValue ?? ""
        let safeHeadline = headline
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        return """
        ---
        type: daily
        source: backend-agent-artifact
        artifact_id: \(artifact.id.uuidString.lowercased())
        artifact_revision: \(artifact.revision)
        summary: "\(safeHeadline)"
        entries_count: 0
        ---

        \(body)
        """
    }

    public func weeklyArtifact(for weekStart: String) -> RemoteDerivedArtifact? {
        latest(kind: "weekly_review", localDate: weekStart)
    }

    public func hasDailyArtifact(for localDate: String) -> Bool {
        latest(kind: "daily_page", localDate: localDate) != nil
    }

    private func latest(kind: String, localDate: String) -> RemoteDerivedArtifact? {
        artifacts
            .filter { $0.kind == kind && $0.localDate == localDate && $0.perspectiveKey == "canonical" }
            .max { lhs, rhs in
                if lhs.revision == rhs.revision { return lhs.updatedAt < rhs.updatedAt }
                return lhs.revision < rhs.revision
            }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // The queue is asynchronous (and Daily is intentionally
            // debounced), so use bounded refreshes while the app stays alive.
            for delaySeconds in [5, 20, 60, 120] {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    try await self?.refresh()
                } catch is CancellationError {
                    return
                } catch {
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static var cacheURL: URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("derived-artifacts-v1.json")
    }

    nonisolated private static func readCache() -> CacheEnvelope? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheEnvelope.self, from: data)
    }

    nonisolated private static func writeCache(_ envelope: CacheEnvelope) throws {
        let url = cacheURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
    }
}
