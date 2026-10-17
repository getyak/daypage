// SupabaseAccountTagsReader.swift — #884 complete account-tag table reader.
//
// Pure Sendable reader for the three 0036 account tag tables. It reuses the
// SAME verified session (`session.tokens.verifiedToken` + `SyncSessionNetwork`)
// as push/pull/media: only GET/HEAD style reads, no RPC writes, no Storage
// access, no second auth or configuration installer. Every request start
// linearizes with the session generation lease (T09: zero sends after
// invalidation) and every consumed response re-checks the lease before it can
// influence derived state.
//
// `memo_tag_imports` payload bodies are NEVER requested — the reader selects
// only `user_id,source_sha256,payload_hash,version` as opaque discovery
// markers. `user_tags`/`memo_tag_links` are read COMPLETELY (including
// catalogue labels with no live membership) with strict composite keyset
// paging at 500 rows/page. Local page budgets produce typed
// `budgetExceeded` (incomplete) — never silent truncation at the per-import
// RPC limits (20k/10k/50k), because cumulative sources can exceed them.
//
// Query encoding contract (single encode, unreserved-only UTF-8 percent
// encoding of every query VALUE): literal '+' is %2B, '%' %25, '#' %23,
// '&' %26, space %20. Nested filter literals inside `or=(...)` first escape
// backslash + double quote and are quoted; the top-level `gt` cursor value is
// raw (never gratuitously quoted) so exact label bytes round-trip.

import Foundation
import DayPageModels

// MARK: - Reader protocol

/// Complete account-tag metadata source. Implemented by
/// `SupabaseAccountTagsReader` in production and by explicit fakes in tests.
///
/// A `nil` capability (`RemotePuller.accountTagsReader`) means "metadata
/// unavailable" — it must NEVER be treated as a complete empty catalogue.
public protocol RemoteAccountTagsReader: Sendable {
    /// One independent owner-scoped exact receipt-count probe
    /// (`Prefer: count=exact`). Throws `AccountTagFetchError.countUnavailable`
    /// when the server does not return a provable exact total.
    func exactReceiptCount() async throws -> Int

    /// Complete `memo_tag_imports` marker rows (metadata only, no payloads).
    func importMarkers() async throws -> [AccountTagImportMarker]

    /// Complete current `user_tags` rows.
    func catalogueRows() async throws -> [AccountTagCatalogueRow]

    /// Complete current `memo_tag_links` rows.
    func linkRows() async throws -> [AccountTagLinkRow]
}

// MARK: - Query encoding

public enum SupabaseAccountTagQuery {
    /// Unreserved-only UTF-8 percent encoding for one query VALUE. Unreserved
    /// = ALPHA / DIGIT / '-' / '_' / '.' / '~'. Everything else (including
    /// '+', '%', '#', '&', space, quotes, parentheses, commas) is %XX-encoded
    /// per UTF-8 byte. Applied EXACTLY once — no second decode/encode and no
    /// form-decoding ambiguity where '+' would become a space.
    public static func encodeValue(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            let isAlphaNumeric = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
            if isAlphaNumeric
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "~") {
                out.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Quotes a literal for nested `or=(...)` grammar: escape backslash and
    /// double quote first, then wrap in double quotes. Operates on UNICODE
    /// SCALARS (not `Character` grapheme clusters) so an ASCII quote or
    /// backslash followed by a combining mark can never fuse into one
    /// cluster and slip through unescaped. The RESULT is still raw
    /// pre-encoding text — the whole query value gets `encodeValue` once.
    public static func quoteFilterLiteral(_ literal: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(literal.utf8.count + 2)
        for scalar in literal.unicodeScalars {
            switch scalar {
            case "\\": escaped.unicodeScalars.append("\\")
                escaped.unicodeScalars.append("\\")
            case "\"": escaped.unicodeScalars.append("\\")
                escaped.unicodeScalars.append("\"")
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// Builds `key=encodedValue` pairs joined by '&' with EXACT bytes.
    public static func queryString(_ pairs: [(String, String)]) -> String {
        pairs
            .map { "\($0.0)=\(encodeValue($0.1))" }
            .joined(separator: "&")
    }
}

// MARK: - Reader file transport

/// The account-tag reader performs data reads only; file transfer is
/// structurally unavailable instead of silently sharing another channel.
private struct AccountTagsFileTransportUnavailable: AttachmentFileTransport {
    func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        throw MemoSyncError.invalidResponse
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        throw MemoSyncError.invalidResponse
    }
}

// MARK: - Supabase reader

/// Session-bound reader for the account tag tables. All requests use the
/// exact-token-proven bearer and the redirect-refusing session network.
public struct SupabaseAccountTagsReader: RemoteAccountTagsReader {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    /// Rows per keyset page (settled page size).
    public static let defaultPageSize = 500

    /// Local page budget PER TABLE. Reaching it is typed incomplete
    /// (`budgetExceeded`), never a truncated "complete" result. It is far
    /// above the per-import RPC limits and only guards local resources.
    public static let defaultMaxPagesPerTable = 200

    public let session: SyncSession
    public let restBase: URL
    public let anonKey: String
    public let transport: HTTPTransport
    /// Session-scoped executor: every request START linearizes with the lease.
    public let network: SyncSessionNetwork
    public let accessTokenProvider: AccessTokenProvider
    public let pageSize: Int
    public let maxPagesPerTable: Int

    private var lease: SyncSessionLease { session.lease }
    private var owner: UUID { session.identity.userID }

    public init(
        session: SyncSession,
        transport: HTTPTransport? = nil,
        accessTokenProvider: @escaping AccessTokenProvider,
        pageSize: Int = SupabaseAccountTagsReader.defaultPageSize,
        maxPagesPerTable: Int = SupabaseAccountTagsReader.defaultMaxPagesPerTable
    ) {
        self.session = session
        let configuration = session.context.configuration
        self.restBase = configuration.url
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        self.anonKey = configuration.publishableKey
        let realmTransport = SupabaseSyncTransport.shared(for: session.identity.origin)
        self.transport = transport ?? realmTransport
        self.network = SyncSessionNetwork(
            lease: session.lease,
            dataTransport: self.transport,
            fileTransport: self.transport as? AttachmentFileTransport
                ?? AccountTagsFileTransportUnavailable()
        )
        self.accessTokenProvider = accessTokenProvider
        self.pageSize = min(max(pageSize, 1), 1_000)
        self.maxPagesPerTable = max(1, maxPagesPerTable)
    }

    // MARK: RemoteAccountTagsReader

    /// Independent owner-scoped exact-count probe over `memo_tag_imports`
    /// (GET Range 0-0 + `Prefer: count=exact`). The exact header total is
    /// REQUIRED: missing or estimated counts throw `countUnavailable` and can
    /// never prove stability. The request carries the SAME verified bearer as
    /// every table read — the receipt table is authenticated-only.
    public func exactReceiptCount() async throws -> Int {
        let query = SupabaseAccountTagQuery.queryString([
            ("select", "source_sha256"),
            ("user_id", "eq.\(owner.uuidString.lowercased())")
        ])
        var request = try await authorizedRequest(table: "memo_tag_imports", query: query)
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        request.setValue("0-0", forHTTPHeaderField: "Range")
        let (data, response) = try await network.data(for: request)
        try lease.assertValid()
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.statusError(http)
        }
        _ = data
        return try Self.exactTotal(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
    }

    public func importMarkers() async throws -> [AccountTagImportMarker] {
        var rows: [AccountTagImportMarker] = []
        var cursor: String?
        for _ in 0..<maxPagesPerTable {
            var pairs: [(String, String)] = [
                ("select", "user_id,source_sha256,payload_hash,version"),
                ("user_id", "eq.\(owner.uuidString.lowercased())"),
                ("order", "source_sha256.asc"),
                ("limit", "\(pageSize)")
            ]
            if let cursor {
                // Top-level keyset cursor: RAW value, never quoted.
                pairs.append(("source_sha256", "gt.\(cursor)"))
            }
            let page = try await fetchRows(MarkerRowDTO.self, table: "memo_tag_imports", pairs: pairs)
            guard page.count <= pageSize else { throw AccountTagFetchError.invalidRows }
            for object in page {
                let marker = try Self.parseMarker(object, owner: owner)
                if let previous = rows.last {
                    guard byteLessThan(
                        Data(previous.sourceSHA256.utf8),
                        Data(marker.sourceSHA256.utf8)
                    ) else {
                        throw AccountTagFetchError.invalidRows
                    }
                }
                rows.append(marker)
            }
            guard page.count == pageSize else { return rows }
            guard let last = rows.last else { throw AccountTagFetchError.invalidRows }
            cursor = last.sourceSHA256
        }
        throw AccountTagFetchError.budgetExceeded
    }

    public func catalogueRows() async throws -> [AccountTagCatalogueRow] {
        var rows: [AccountTagCatalogueRow] = []
        var cursor: ExactTagLabel?
        for _ in 0..<maxPagesPerTable {
            var pairs: [(String, String)] = [
                ("select", "user_id,label,in_import_catalog"),
                ("user_id", "eq.\(owner.uuidString.lowercased())"),
                ("order", "label.asc"),
                ("limit", "\(pageSize)")
            ]
            if let cursor {
                // Top-level `gt` carries the RAW label value (unquoted).
                pairs.append(("label", "gt.\(cursor.text)"))
            }
            let page = try await fetchRows(CatalogueRowDTO.self, table: "user_tags", pairs: pairs)
            guard page.count <= pageSize else { throw AccountTagFetchError.invalidRows }
            for object in page {
                let row = try Self.parseCatalogueRow(object, owner: owner)
                if let previous = rows.last {
                    guard previous.label < row.label else {
                        throw AccountTagFetchError.invalidRows
                    }
                }
                rows.append(row)
            }
            guard page.count == pageSize else { return rows }
            guard let last = rows.last else { throw AccountTagFetchError.invalidRows }
            cursor = last.label
        }
        throw AccountTagFetchError.budgetExceeded
    }

    public func linkRows() async throws -> [AccountTagLinkRow] {
        var rows: [AccountTagLinkRow] = []
        var cursor: AccountTagLinkRow?
        for _ in 0..<maxPagesPerTable {
            var pairs: [(String, String)] = [
                ("select", "user_id,memo_id,label"),
                ("user_id", "eq.\(owner.uuidString.lowercased())"),
                ("order", "memo_id.asc,label.asc"),
                ("limit", "\(pageSize)")
            ]
            if let cursor {
                // Composite keyset: nested label literal is quoted + escaped,
                // then the WHOLE `or` value is percent-encoded exactly once.
                let memo = cursor.memoID.uuidString.lowercased()
                let literal = SupabaseAccountTagQuery.quoteFilterLiteral(cursor.label.text)
                pairs.append((
                    "or",
                    "(memo_id.gt.\(memo),and(memo_id.eq.\(memo),label.gt.\(literal)))"
                ))
            }
            let page = try await fetchRows(LinkRowDTO.self, table: "memo_tag_links", pairs: pairs)
            guard page.count <= pageSize else { throw AccountTagFetchError.invalidRows }
            for object in page {
                let row = try Self.parseLinkRow(object, owner: owner)
                if let previous = rows.last {
                    guard Self.linkPrecedes(previous, row) else {
                        throw AccountTagFetchError.invalidRows
                    }
                }
                rows.append(row)
            }
            guard page.count == pageSize else { return rows }
            guard let last = rows.last else { throw AccountTagFetchError.invalidRows }
            cursor = last
        }
        throw AccountTagFetchError.budgetExceeded
    }

    // MARK: Row parsing + validation

    // STRICT wire types: `JSONSerialization`'s NSNumber bridging would accept
    // `version: true` as 1 and `in_import_catalog: 1` as true. `Decodable`
    // rejects both (verified typeMismatch), so wrong wire types fail the
    // whole round instead of silently coercing.
    private struct MarkerRowDTO: Decodable {
        let userID: String
        let sourceSHA256: String
        let payloadHash: String
        let version: Int

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case sourceSHA256 = "source_sha256"
            case payloadHash = "payload_hash"
            case version
        }
    }

    private struct CatalogueRowDTO: Decodable {
        let userID: String
        let label: String
        let inImportCatalog: Bool

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case label
            case inImportCatalog = "in_import_catalog"
        }
    }

    private struct LinkRowDTO: Decodable {
        let userID: String
        let memoID: String
        let label: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case memoID = "memo_id"
            case label
        }
    }

    private static func parseMarker(
        _ row: MarkerRowDTO,
        owner: UUID
    ) throws -> AccountTagImportMarker {
        guard UUID(uuidString: row.userID) == owner else {
            throw AccountTagFetchError.invalidRows
        }
        let marker = AccountTagImportMarker(
            sourceSHA256: row.sourceSHA256,
            payloadHash: row.payloadHash,
            version: row.version
        )
        guard marker.isStructurallyValid else {
            throw AccountTagFetchError.invalidRows
        }
        return marker
    }

    private static func parseCatalogueRow(
        _ row: CatalogueRowDTO,
        owner: UUID
    ) throws -> AccountTagCatalogueRow {
        guard UUID(uuidString: row.userID) == owner,
              let label = ExactTagLabel(row.label) else {
            throw AccountTagFetchError.invalidRows
        }
        return AccountTagCatalogueRow(label: label, inImportCatalog: row.inImportCatalog)
    }

    private static func parseLinkRow(
        _ row: LinkRowDTO,
        owner: UUID
    ) throws -> AccountTagLinkRow {
        guard UUID(uuidString: row.userID) == owner,
              let memoID = UUID(uuidString: row.memoID),
              row.memoID == memoID.uuidString.lowercased(),
              let label = ExactTagLabel(row.label) else {
            throw AccountTagFetchError.invalidRows
        }
        return AccountTagLinkRow(memoID: memoID, label: label)
    }

    /// Composite (memo UUID canonical-lowercase bytes, label UTF-8 bytes)
    /// strict order — matches `order=memo_id.asc,label.asc` binary ordering.
    private static func linkPrecedes(_ lhs: AccountTagLinkRow, _ rhs: AccountTagLinkRow) -> Bool {
        let left = Data(lhs.memoID.uuidString.lowercased().utf8)
        let right = Data(rhs.memoID.uuidString.lowercased().utf8)
        if left != right { return byteLessThan(left, right) }
        return lhs.label < rhs.label
    }

    // MARK: HTTP plumbing

    private func makeRequest(table: String, query: String) throws -> URLRequest {
        #if !DEBUG
        guard session.identity.origin.normalized.hasPrefix("https://") else {
            throw MemoSyncError.insecureScheme
        }
        #endif
        guard !anonKey.isEmpty else { throw MemoSyncError.notConfigured }
        guard var components = URLComponents(
            url: restBase.appendingPathComponent(table),
            resolvingAgainstBaseURL: false
        ) else {
            throw MemoSyncError.invalidResponse
        }
        // EXACT query bytes: values already percent-encoded once above.
        components.percentEncodedQuery = query
        guard let url = components.url else { throw MemoSyncError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        return request
    }

    /// Session-scoped exact-token proof preparation shared by EVERY request
    /// (count probes included): local claim pre-check + same-origin
    /// `/auth/v1/user` proof, then the exact proven bearer on the request and
    /// a lease recheck before the send.
    private func authorizedRequest(table: String, query: String) async throws -> URLRequest {
        let rawToken = try await accessTokenProvider()
        guard !rawToken.isEmpty else { throw MemoSyncError.unauthorized }
        let token = try await session.tokens.verifiedToken(rawToken)
        try lease.assertValid()
        var request = try makeRequest(table: table, query: query)
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func fetchRows<Row: Decodable>(
        _ type: Row.Type,
        table: String,
        pairs: [(String, String)]
    ) async throws -> [Row] {
        let request = try await authorizedRequest(
            table: table,
            query: SupabaseAccountTagQuery.queryString(pairs)
        )
        let (data, response) = try await network.data(for: request)
        try lease.assertValid()
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode([Row].self, from: data)
            } catch {
                // Wrong wire types (e.g. `version: true`,
                // `in_import_catalog: 1`) and malformed rows fail the round.
                throw AccountTagFetchError.invalidRows
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

    /// Parses the exact total from `Content-Range` (`0-0/123` or `*/123`).
    /// A missing header or a `*` total is NOT proof and throws.
    static func exactTotal(fromContentRange header: String?) throws -> Int {
        guard let header,
              let slash = header.lastIndex(of: "/") else {
            throw AccountTagFetchError.countUnavailable
        }
        let total = String(header[header.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard total != "*", let value = Int(total), value >= 0 else {
            throw AccountTagFetchError.countUnavailable
        }
        return value
    }

    private static func statusError(_ http: HTTPURLResponse) -> Error {
        switch http.statusCode {
        case 401: return MemoSyncError.unauthorized
        case 403: return MemoSyncError.forbidden
        case 429:
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            return MemoSyncError.rateLimited(retryAfter: retry)
        default: return MemoSyncError.serverError(status: http.statusCode)
        }
    }
}
