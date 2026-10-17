// AccountTagProjectionStore.swift — #884 derived account tag projection cache.
//
// The account tag projection is a REBUILDABLE, realm-bound, versioned derived
// cache under `vault/_agent/sync/account-tags-v1.json`. It mirrors the current
// `user_tags` / `memo_tag_links` tables (plus opaque `memo_tag_imports`
// source/hash discovery markers) so native reading can show exact labels.
//
// Hard boundaries (see ADR-0025):
//   - This file NEVER touches `vault/raw/`, YAML front matter, the durable
//     outbox, account state or pull cursors. A tag refresh writes exactly one
//     derived file (and only after full consistency validation).
//   - A wrong-realm, corrupt, stale or interrupted cache is a typed
//     "unavailable" — never an empty-success that would hide real labels.
//   - Receipt payload bodies are NEVER read: `memo_tag_imports` rows are
//     discovery markers only (source_sha256/payload_hash/version).
//   - The install commits inside the CURRENT session generation lease and
//     posts its notification only after BOTH the lease gate and the store
//     lock are released (the earlier RawStorage notification deadlock).
//
// Consistency boundary: under the CURRENT canonical append-only import writer
// (0036: authenticated SELECT-only grants, import RPC inserts one immutable
// receipt per source), an exact receipt count that is unchanged across a full
// markers/catalogue/links download proves no new successful source import in
// that interval. Admin/hard-delete/future writers can still change tags
// without a receipt, so this is bounded EVENTUAL refresh — not a linearizable
// raw+tags snapshot (see ADR-0025).

import Foundation
import DayPageModels

// MARK: - Row value types

/// One current `user_tags` row (exact label + import-catalogue flag).
public struct AccountTagCatalogueRow: Codable, Equatable, Sendable {
    public let label: ExactTagLabel
    public let inImportCatalog: Bool

    public init(label: ExactTagLabel, inImportCatalog: Bool) {
        self.label = label
        self.inImportCatalog = inImportCatalog
    }

    enum CodingKeys: String, CodingKey {
        case label
        case inImportCatalog = "in_import_catalog"
    }
}

/// One current `memo_tag_links` row (exact label membership of one memo).
public struct AccountTagLinkRow: Codable, Equatable, Sendable {
    public let memoID: UUID
    public let label: ExactTagLabel

    public init(memoID: UUID, label: ExactTagLabel) {
        self.memoID = memoID
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case memoID = "memo_id"
        case label
    }
}

/// Opaque discovery marker from `memo_tag_imports`. The receipt payload body
/// is deliberately NOT part of this type — it is never fetched and never used
/// as current truth.
public struct AccountTagImportMarker: Codable, Equatable, Sendable {
    public let sourceSHA256: String
    public let payloadHash: String
    public let version: Int

    public init(sourceSHA256: String, payloadHash: String, version: Int) {
        self.sourceSHA256 = sourceSHA256
        self.payloadHash = payloadHash
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case sourceSHA256 = "source_sha256"
        case payloadHash = "payload_hash"
        case version
    }

    /// 64 lowercase hex characters (matches 0036's CHECK constraints).
    public static func isLowerHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    public var isStructurallyValid: Bool {
        Self.isLowerHex64(sourceSHA256)
            && Self.isLowerHex64(payloadHash)
            && version == 1
    }
}

// MARK: - Errors

/// Typed cache-read/install failures. A cache miss or damage is
/// "unavailable" — callers keep showing last-known state and rebuild; they
/// must NEVER interpret these as a complete empty catalogue.
public enum AccountTagCacheError: LocalizedError, Equatable, Sendable {
    /// No cache file at the expected path (first run / after rebuild).
    case missing
    /// Cache belongs to a different origin/owner, or its path escapes the
    /// Vault through a symlink.
    case foreign
    /// Unparseable or structurally inconsistent cache bytes.
    case corrupt
    /// Cache schema version is not the supported one.
    case staleVersion
    /// The session generation changed before the install could commit.
    case leaseInvalidated
    /// The snapshot is internally inconsistent and must not be installed.
    case inconsistentSnapshot

    public var errorDescription: String? {
        switch self {
        case .missing: return "标签投影缓存不存在"
        case .foreign: return "标签投影缓存不属于当前同步账户"
        case .corrupt: return "标签投影缓存已损坏"
        case .staleVersion: return "标签投影缓存版本不受支持"
        case .leaseInvalidated: return "同步会话已被替换，未安装标签投影"
        case .inconsistentSnapshot: return "标签投影数据未通过一致性校验"
        }
    }
}

/// Typed fetch/consistency failures. All of them preserve the previous cache
/// bytes; none of them may be reported as "no tags".
public enum AccountTagFetchError: LocalizedError, Equatable, Sendable {
    /// The response carried no provable exact receipt count.
    case countUnavailable
    /// The exact receipt count changed across the full read (new import
    /// committed mid-fetch) and bounded retries were exhausted.
    case countChanged
    /// Marker row cardinality does not equal the proven receipt count.
    case markerCountMismatch
    /// A row failed owner/label/ordering/dedup validation.
    case invalidRows
    /// A link references a label absent from the catalogue.
    case inconsistentLinks
    /// Local paging/time budget exhausted — typed incomplete, never a
    /// silent truncation at per-import RPC limits.
    case budgetExceeded

    public var errorDescription: String? {
        switch self {
        case .countUnavailable: return "无法获得精确的标签导入计数"
        case .countChanged: return "标签数据在下载期间发生变化"
        case .markerCountMismatch: return "标签导入标记数量与精确计数不一致"
        case .invalidRows: return "标签数据行未通过校验"
        case .inconsistentLinks: return "标签关联引用了不存在的标签"
        case .budgetExceeded: return "标签数据超出本地读取预算"
        }
    }
}

// MARK: - Snapshot

/// Complete, validated projection of one account's current tag tables.
/// Stored as array rows in JSON — labels are NEVER dictionary/set keys over
/// their raw `String` form (canonical equivalents must stay distinct).
public struct AccountTagProjectionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var normalizedOrigin: String
    public var ownerUUID: UUID
    /// Proven exact `memo_tag_imports` receipt count (C0 == C1).
    public var receiptCount: Int
    public var catalogue: [AccountTagCatalogueRow]
    public var links: [AccountTagLinkRow]
    public var sourceMarkers: [AccountTagImportMarker]
    public var fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case normalizedOrigin = "normalized_origin"
        case ownerUUID = "owner_uuid"
        case receiptCount = "receipt_count"
        case catalogue
        case links
        case sourceMarkers = "source_markers"
        case fetchedAt = "fetched_at"
    }

    public init(
        schemaVersion: Int = AccountTagProjectionSnapshot.currentSchemaVersion,
        normalizedOrigin: String,
        ownerUUID: UUID,
        receiptCount: Int,
        catalogue: [AccountTagCatalogueRow],
        links: [AccountTagLinkRow],
        sourceMarkers: [AccountTagImportMarker],
        fetchedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.normalizedOrigin = normalizedOrigin
        self.ownerUUID = ownerUUID
        self.receiptCount = receiptCount
        self.catalogue = catalogue
        self.links = links
        self.sourceMarkers = sourceMarkers
        self.fetchedAt = fetchedAt
    }

    // MARK: Consistency validation

    /// Full structural validation. Mirrors the reader's row checks so a fake
    /// reader, a damaged cache file and a real response are all held to the
    /// same contract.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AccountTagCacheError.staleVersion
        }
        guard receiptCount >= 0, sourceMarkers.count == receiptCount else {
            throw AccountTagFetchError.markerCountMismatch
        }
        var previousMarker: AccountTagImportMarker?
        for marker in sourceMarkers {
            guard marker.isStructurallyValid else {
                throw AccountTagFetchError.invalidRows
            }
            if let previous = previousMarker {
                guard byteLessThan(
                    Data(previous.sourceSHA256.utf8),
                    Data(marker.sourceSHA256.utf8)
                ) else {
                    throw AccountTagFetchError.invalidRows
                }
            }
            previousMarker = marker
        }

        var previousLabel: ExactTagLabel?
        var catalogueIdentities = Set<String>()
        for row in catalogue {
            if let previous = previousLabel, !(previous < row.label) {
                throw AccountTagFetchError.invalidRows
            }
            guard catalogueIdentities.insert(row.label.identity).inserted else {
                throw AccountTagFetchError.invalidRows
            }
            previousLabel = row.label
        }

        var previousLink: AccountTagLinkRow?
        var seenLinks = Set<String>()
        for row in links {
            if let previous = previousLink {
                guard linkPrecedes(previous, row) else {
                    throw AccountTagFetchError.invalidRows
                }
            }
            guard seenLinks.insert("\(row.memoID.uuidString.lowercased()):\(row.label.identity)").inserted else {
                throw AccountTagFetchError.invalidRows
            }
            previousLink = row
        }

        // Foreign-key consistency: every linked label exists in the catalogue
        // with EXACT bytes (canonical equivalents do not match).
        guard catalogueIdentities.isSuperset(of: links.map { $0.label.identity }) else {
            throw AccountTagFetchError.inconsistentLinks
        }
    }

    private func linkPrecedes(_ lhs: AccountTagLinkRow, _ rhs: AccountTagLinkRow) -> Bool {
        let left = Data(lhs.memoID.uuidString.lowercased().utf8)
        let right = Data(rhs.memoID.uuidString.lowercased().utf8)
        if left != right { return byteLessThan(left, right) }
        return lhs.label < rhs.label
    }

    // MARK: View intersection (production reading helpers)

    /// Exact labels of `memoID` — ONLY while that exact raw UUID currently
    /// exists locally. Deleted memos never resurrect from the cache and a
    /// conflict-copy UUID never inherits the original's memberships.
    public func labels(
        forMemoID memoID: UUID,
        liveMemoIDs: Set<UUID>
    ) -> [ExactTagLabel] {
        guard liveMemoIDs.contains(memoID) else { return [] }
        return links.filter { $0.memoID == memoID }.map(\.label)
    }

    /// Current-raw memo UUIDs carrying `label`.
    public func memoIDs(
        containing label: ExactTagLabel,
        liveMemoIDs: Set<UUID>
    ) -> [UUID] {
        links
            .filter { $0.label == label && liveMemoIDs.contains($0.memoID) }
            .map(\.memoID)
    }

    /// Active membership counts per label, intersected with current raw UUIDs.
    /// The full catalogue (including unused labels) stays available separately.
    public func activeMembershipCounts(liveMemoIDs: Set<UUID>) -> [ExactTagLabel: Int] {
        var counts: [ExactTagLabel: Int] = [:]
        for row in links where liveMemoIDs.contains(row.memoID) {
            counts[row.label, default: 0] += 1
        }
        return counts
    }

    /// Every catalogue label in exact ascending order (includes unused ones).
    public var allLabels: [ExactTagLabel] {
        catalogue.map(\.label)
    }

    /// True when every marker set + count matches the given probe result.
    public func matches(receiptCount: Int, markers: [AccountTagImportMarker]) -> Bool {
        self.receiptCount == receiptCount && self.sourceMarkers == markers
    }
}

// MARK: - Derived cache store

/// Atomic, realm-bound persistence for the derived projection cache.
public enum AccountTagProjectionStore {
    public static let cacheDirectoryComponents = ["_agent", "sync"]
    public static let cacheFileName = "account-tags-v1.json"

    private static let storeLock = NSLock()

    public static func cacheFileURL(vaultRoot: URL) -> URL {
        cacheDirectoryComponents.reduce(vaultRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.appendingPathComponent(cacheFileName)
    }

    // MARK: Read

    /// Reads the complete cache for `realm`, or throws a typed unavailable /
    /// stale error. Never returns an empty-success snapshot.
    public static func read(
        realm: SyncRealmIdentity,
        vaultRoot: URL
    ) throws -> AccountTagProjectionSnapshot {
        let fileURL = try verifiedCacheFileURL(vaultRoot: vaultRoot, create: false)
        storeLock.lock()
        defer { storeLock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AccountTagCacheError.missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AccountTagCacheError.corrupt
        }
        let snapshot: AccountTagProjectionSnapshot
        do {
            snapshot = try decodeSnapshot(data)
        } catch let error as AccountTagCacheError {
            throw error
        } catch {
            throw AccountTagCacheError.corrupt
        }
        guard snapshot.schemaVersion == AccountTagProjectionSnapshot.currentSchemaVersion else {
            throw AccountTagCacheError.staleVersion
        }
        guard snapshot.normalizedOrigin == realm.normalizedOrigin,
              snapshot.ownerUUID == realm.userID else {
            throw AccountTagCacheError.foreign
        }
        do {
            try snapshot.validate()
        } catch {
            throw AccountTagCacheError.corrupt
        }
        return snapshot
    }

    // MARK: Install

    /// Atomically replaces the derived cache for `realm`.
    ///
    /// Ordering contract:
    ///   1. snapshot validation (no writes at all on failure),
    ///   2. store lock + CURRENT generation lease gate around the atomic
    ///      file replace (a replaced/invalidated lease refuses the write —
    ///      the lease is a REQUIRED capability, never manufactured),
    ///   3. notification ONLY after both the lease gate and the store lock
    ///      have been released.
    ///
    /// Existing bytes are preserved on every failure path.
    public static func install(
        _ snapshot: AccountTagProjectionSnapshot,
        realm: SyncRealmIdentity,
        lease: SyncSessionLease,
        vaultRoot: URL
    ) throws {
        guard snapshot.normalizedOrigin == realm.normalizedOrigin,
              snapshot.ownerUUID == realm.userID else {
            throw AccountTagCacheError.foreign
        }
        do {
            try snapshot.validate()
        } catch {
            throw AccountTagCacheError.inconsistentSnapshot
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload: Data
        do {
            payload = try encoder.encode(snapshot)
        } catch {
            throw AccountTagCacheError.corrupt
        }

        storeLock.lock()
        do {
            try lease.withValidity {
                let fileURL = try verifiedCacheFileURL(vaultRoot: vaultRoot, create: true)
                try payload.write(to: fileURL, options: [.atomic])
            }
        } catch let error as AccountTagCacheError {
            storeLock.unlock()
            throw error
        } catch let error as SyncRealmError {
            storeLock.unlock()
            throw error == .sessionInvalidated
                ? AccountTagCacheError.leaseInvalidated
                : error
        } catch {
            storeLock.unlock()
            throw AccountTagCacheError.corrupt
        }
        storeLock.unlock()
        // Both guards are released BEFORE any notification callback can run.
        NotificationCenter.default.post(
            name: .accountTagProjectionDidUpdate,
            object: nil,
            userInfo: [
                "ownerUUID": snapshot.ownerUUID.uuidString.lowercased(),
                "normalizedOrigin": snapshot.normalizedOrigin
            ]
        )
    }

    // MARK: Cache-decoding seam (tests reuse it for crash-window fixtures)

    public static func decodeSnapshot(_ data: Data) throws -> AccountTagProjectionSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(AccountTagProjectionSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    // MARK: Path safety

    /// Resolves the cache file URL while REJECTING every metadata-path
    /// symlink, fail-closed.
    ///
    /// `_agent`, `_agent/sync` and the cache file itself must be real
    /// entries: any symlink at any of those positions is refused outright,
    /// including chained aliases (`_agent` → in-Vault alias → outside),
    /// dangling targets and loops — one-hop resolution cannot prove those
    /// safe. Foundation's `resolvingSymlinksInPath` is deliberately unused:
    /// it leaves missing leaves unresolved and rewrites `/private` prefixes.
    /// The trust boundary is the Vault root path the caller supplied.
    private static func verifiedCacheFileURL(
        vaultRoot: URL,
        create: Bool
    ) throws -> URL {
        let rootPath = URL(fileURLWithPath: vaultRoot.path).standardizedFileURL.path
        var currentPath = rootPath
        for component in cacheDirectoryComponents {
            currentPath = currentPath + "/" + component
            try rejectMetadataSymlink(atPath: currentPath)
            if create, !FileManager.default.fileExists(atPath: currentPath) {
                try? FileManager.default.createDirectory(
                    atPath: currentPath,
                    withIntermediateDirectories: true
                )
            }
        }
        let filePath = currentPath + "/" + cacheFileName
        try rejectMetadataSymlink(atPath: filePath)
        return URL(fileURLWithPath: filePath)
    }

    /// `destinationOfSymbolicLink` inspects exactly the final path component
    /// (intermediate components resolve transparently, but each component is
    /// checked at its own turn above). Any symlink — valid, dangling or
    /// looping — fails closed as foreign metadata.
    private static func rejectMetadataSymlink(atPath path: String) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            throw AccountTagCacheError.foreign
        }
    }
}

// MARK: - Consistency-wrapped refresh

/// Full/cheap account-tag reads with the settled consistency boundary.
public enum AccountTagProjectionRefresh {
    /// Bounded attempts for observed-change races (count moved mid-read).
    public static let defaultMaxAttempts = 3

    /// One full consistency-wrapped attempt:
    /// C0 exact count → complete markers + current catalogue + current links
    /// → C1 exact count. Installs nothing; only returns a validated snapshot
    /// when C0 == C1 == marker cardinality and every row check passed.
    public static func fetchOnce(
        reader: RemoteAccountTagsReader,
        realm: SyncRealmIdentity
    ) async throws -> AccountTagProjectionSnapshot {
        let countBefore = try await reader.exactReceiptCount()
        let markers = try await reader.importMarkers()
        let catalogue = try await reader.catalogueRows()
        let links = try await reader.linkRows()
        let countAfter = try await reader.exactReceiptCount()
        guard countBefore == countAfter else {
            throw AccountTagFetchError.countChanged
        }
        let snapshot = AccountTagProjectionSnapshot(
            normalizedOrigin: realm.normalizedOrigin,
            ownerUUID: realm.userID,
            receiptCount: countAfter,
            catalogue: catalogue,
            links: links,
            sourceMarkers: markers
        )
        try snapshot.validate()
        return snapshot
    }

    /// Bounded retry: a changing count/marker set retries the whole wrapped
    /// read; every other failure is authoritative for this pass. Exhausted
    /// retries leave the caller's previous cache untouched.
    public static func fetch(
        reader: RemoteAccountTagsReader,
        realm: SyncRealmIdentity,
        maxAttempts: Int = defaultMaxAttempts
    ) async throws -> AccountTagProjectionSnapshot {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await fetchOnce(reader: reader, realm: realm)
            } catch let error as AccountTagFetchError {
                switch error {
                case .countChanged, .markerCountMismatch:
                    // Observed-change race: bounded retry of the WHOLE wrapped
                    // read. Exhausted retries rethrow the observed error and
                    // never install a partial snapshot.
                    guard attempt < max(1, maxAttempts) else { throw error }
                default:
                    throw error
                }
            }
        }
    }

    /// Cheap periodic/online probe: exact count + marker set only. Returns
    /// true when the cached snapshot is still the current complete truth for
    /// the canonical append-only import writer (no full re-download needed).
    /// Throws when the count cannot be proven or the probe fails — a failed
    /// probe is NEVER "fresh".
    public static func isCacheFresh(
        reader: RemoteAccountTagsReader,
        cached: AccountTagProjectionSnapshot
    ) async throws -> Bool {
        let count = try await reader.exactReceiptCount()
        guard count == cached.receiptCount else { return false }
        let markers = try await reader.importMarkers()
        guard markers.count == count else {
            throw AccountTagFetchError.markerCountMismatch
        }
        return cached.matches(receiptCount: count, markers: markers)
    }
}

// MARK: - Tag filter resolution (search-side contract)

/// Typed outcome of applying an exact-tag selection to the projection and the
/// CURRENT raw memo UUIDs (#884). The three states are deliberately distinct:
/// "no tag filter", "filtered to these memos (possibly zero)" and "filter is
/// active but metadata is unreadable" can never collapse into each other.
public enum AccountTagFilterResolution: Equatable, Sendable {
    /// No tag filter selected — the query has no tag dimension at all.
    case noTagDimension
    /// Selected labels map to these CURRENT raw memo UUIDs. May be EMPTY:
    /// a selected label with no live member matches nothing (never everything).
    case eligible(Set<UUID>)
    /// A tag filter IS selected but account-tag metadata is not readable.
    /// Callers must fail CLOSED — never silently drop the filter and show
    /// unrelated text hits — and keep an unavailable warning visible.
    case unavailable
}

public enum AccountTagProjectionFilter {
    /// Resolves a label-identity selection (OR across labels) against a
    /// snapshot and the live raw UUID set. `snapshot == nil` means metadata
    /// unavailable — with an active selection that is `.unavailable`, never a
    /// silently unfiltered query.
    public static func resolve(
        selection: Set<String>,
        liveMemoIDs: Set<UUID>,
        snapshot: AccountTagProjectionSnapshot?
    ) -> AccountTagFilterResolution {
        guard !selection.isEmpty else { return .noTagDimension }
        guard let snapshot else { return .unavailable }
        var eligible = Set<UUID>()
        for row in snapshot.links
        where selection.contains(row.label.identity) && liveMemoIDs.contains(row.memoID) {
            eligible.insert(row.memoID)
        }
        return .eligible(eligible)
    }
}

// MARK: - Notification name

public extension Notification.Name {
    /// Posted by `AccountTagProjectionStore.install` AFTER the lease gate and
    /// the store lock are both released. Observers (SearchIndex refresh
    /// triggers, Today/detail views) recompute read-only views.
    static let accountTagProjectionDidUpdate =
        Notification.Name("DayPage.accountTagProjection.didUpdate")
}
