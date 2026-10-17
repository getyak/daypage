// SyncRealm.swift — origin/account/session-generation isolation primitives.
//
// A "realm" is exactly one (normalized HTTPS backend origin, user UUID) pair.
// Every push, pull, download, raw apply, outbox acknowledgement and cursor
// update must be provably scoped to one realm before it can touch durable
// state. The building blocks live here:
//
//   - `SyncRealmOrigin`        normalized HTTPS origin (no userinfo/port
//                              ambiguity/path/query/fragment).
//   - `SyncRealmIdentity`      (origin, user UUID) realm identity.
//   - `SyncBackendConfiguration` URL + publishable key selected as ONE pair
//                              from ONE configuration tier.
//   - `SyncSessionTokenClaims` local JWT claim pre-check. Decoding a JWT is
//                              routing/identity pre-check ONLY — it is never
//                              authentication proof.
//   - `SyncSessionVerifier`    same-origin `/auth/v1/user` server proof that
//                              upgrades claims into a verified context.
//   - `SyncSessionContext`     immutable verified backend/session context.
//   - `SyncSessionLease`       invalidatable generation lease with a
//                              synchronous `withValidity` commit gate. The
//                              check and its effect linearize together inside
//                              the gate; invalidation linearizes against the
//                              gate, never mid-commit.
//   - `SyncTransferSidecarBinding` realm-binding verdict for the attachment
//                              transfer sidecar (shared by the account store
//                              and `AttachmentTransferStore`).
//
// Nothing in this file performs implicit networking: the only network call is
// `SyncSessionVerifier`, which requires an explicitly injected `HTTPTransport`.
// Tests inject fakes; production injects `SupabaseSyncTransport` (which
// refuses redirects before any bearer can be forwarded).

import Foundation

// MARK: - SyncRealmError

/// Bounded, privacy-safe realm errors. Associated values are reason codes or
/// status codes — never raw URLs, tokens, note text, or attachment names.
public enum SyncRealmError: LocalizedError, Equatable, Sendable {
    public enum OriginProblem: String, Sendable {
        case insecureScheme
        case missingHost
        case userinfo
        case ambiguousPort
        case nonRootPath
        case query
        case fragment
    }

    public enum TokenProblem: String, Sendable {
        case format
        case issuer
        case subject
        case role
        case expired
        case unproven
    }

    case invalidOrigin(OriginProblem)
    case incompleteConfigurationPair
    case partialConfigurationOverride
    case realmMismatch
    case legacyRealmUnverified
    case sessionTokenInvalid(TokenProblem)
    case serverUserUnverified(status: Int)
    case serverUserMismatch
    case sessionInvalidated
    case invalidResumableURL
    case redirectRefused

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin(let problem):
            return "同步地址不是合法的 HTTPS 服务地址（\(problem.rawValue)）"
        case .incompleteConfigurationPair:
            return "同步配置缺少完整的服务地址或公开密钥"
        case .partialConfigurationOverride:
            return "同步配置只覆盖了地址或密钥其中一项，拒绝混用不同配置层"
        case .realmMismatch:
            return "本地数据已绑定到另一个同步项目或账户"
        case .legacyRealmUnverified:
            return "本地存在无法证明来源的旧同步状态，已暂停同步以保护数据"
        case .sessionTokenInvalid(let problem):
            return "会话凭证与当前同步项目不匹配（\(problem.rawValue)）"
        case .serverUserUnverified(let status):
            return "服务器未能确认当前会话用户（HTTP \(status)）"
        case .serverUserMismatch:
            return "服务器确认的用户与当前同步账户不一致"
        case .sessionInvalidated:
            return "本次同步会话已被替换或撤销"
        case .invalidResumableURL:
            return "断点续传地址不属于当前同步项目"
        case .redirectRefused:
            return "同步请求被重定向到其他地址，已拒绝转发会话凭证"
        }
    }
}

// MARK: - SyncRealmOrigin

/// Normalized HTTPS backend origin.
///
/// Normalization is deliberately strict (handoff §3): userinfo, ambiguous
/// ports, non-root paths, query and fragment components are rejected instead
/// of being silently dropped, because a dropped component could otherwise
/// route a bearer token to a different authority than the one the realm was
/// verified against.
public struct SyncRealmOrigin: Hashable, Sendable {
    /// Canonical form: `https://host` or `https://host:port` with an explicit
    /// non-default port. Host is lowercased; the default port 443 is omitted.
    public let normalized: String

    public init(validating url: URL) throws {
        try self.init(validatingRaw: url.absoluteString)
    }

    public init(validating string: String) throws {
        try self.init(validatingRaw: string)
    }

    private init(validatingRaw raw: String) throws {
        let authority = try Self.normalizedAuthority(from: raw)
        // Root-path URLs only: a realm origin never carries a resource path,
        // query or fragment that could silently redirect token scope.
        guard let schemeEnd = raw.range(of: "://") else {
            throw SyncRealmError.invalidOrigin(.missingHost)
        }
        let rest = raw[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? rest.endIndex
        let tail = String(rest[authorityEnd...])
        if tail.hasPrefix("?") {
            throw SyncRealmError.invalidOrigin(.query)
        }
        if tail.hasPrefix("#") {
            throw SyncRealmError.invalidOrigin(.fragment)
        }
        if !tail.isEmpty && tail != "/" {
            throw SyncRealmError.invalidOrigin(.nonRootPath)
        }
        self.normalized = authority
    }

    /// The GoTrue issuer for this backend: `origin + /auth/v1`.
    public var authIssuer: String { normalized + "/auth/v1" }

    /// True when `url`'s scheme/host/port are exactly this origin. Path,
    /// query and fragment are ignored here (resource-level path rules such as
    /// the resumable endpoint check them explicitly).
    public func matchesRoot(_ url: URL) -> Bool {
        (try? Self.normalizedAuthority(from: url.absoluteString)) == normalized
    }

    /// Strict `https://host[:port]` authority parse of a raw URL string.
    ///
    /// `URLComponents.port` silently returns nil for a malformed or empty
    /// port (`https://host:`, `https://host:abc`), so the raw authority is
    /// inspected directly: every explicit port marker must resolve to exactly
    /// one 1...65535 decimal value. Userinfo is rejected outright.
    static func normalizedAuthority(from raw: String) throws -> String {
        guard let schemeEnd = raw.range(of: "://") else {
            throw SyncRealmError.invalidOrigin(.missingHost)
        }
        guard raw[raw.startIndex..<schemeEnd.lowerBound].lowercased() == "https" else {
            throw SyncRealmError.invalidOrigin(.insecureScheme)
        }
        let rest = raw[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? rest.endIndex
        let authority = String(rest[rest.startIndex..<authorityEnd])
        guard !authority.isEmpty else {
            throw SyncRealmError.invalidOrigin(.missingHost)
        }
        guard !authority.contains("@") else {
            throw SyncRealmError.invalidOrigin(.userinfo)
        }
        guard !authority.contains("%") else {
            // Percent-encoded authorities would allow two spellings of one
            // origin (e.g. `ho%6Dst` vs `homst`).
            throw SyncRealmError.invalidOrigin(.missingHost)
        }
        if authority.hasPrefix("[") {
            // Bracketed IPv6 literal; the bracket form itself disambiguates
            // any following port.
            guard let close = authority.firstIndex(of: "]") else {
                throw SyncRealmError.invalidOrigin(.ambiguousPort)
            }
            let host = String(authority[authority.startIndex...close]).lowercased()
            let remainder = String(authority[authority.index(after: close)...])
            let port = try parsePortMarker(remainder, allowEmpty: true)
            return composeAuthority(host: host, port: port)
        }
        if let marker = authority.lastIndex(of: ":") {
            let host = String(authority[authority.startIndex..<marker])
            guard !host.isEmpty, !host.contains(":") else {
                throw SyncRealmError.invalidOrigin(.ambiguousPort)
            }
            let port = try parsePortMarker(
                String(authority[marker...]),
                allowEmpty: false
            )
            return composeAuthority(host: host.lowercased(), port: port)
        }
        return composeAuthority(host: authority.lowercased(), port: nil)
    }

    /// Parses a `:digits` (or, for IPv6, empty) port marker.
    private static func parsePortMarker(_ marker: String, allowEmpty: Bool) throws -> Int? {
        guard marker.hasPrefix(":") else {
            if marker.isEmpty, allowEmpty { return nil }
            throw SyncRealmError.invalidOrigin(.ambiguousPort)
        }
        let digits = String(marker.dropFirst())
        guard !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
              let port = Int(digits),
              (1...65535).contains(port) else {
            throw SyncRealmError.invalidOrigin(.ambiguousPort)
        }
        return port
    }

    private static func composeAuthority(host: String, port: Int?) -> String {
        if let port, port != 443 {
            return "https://\(host):\(port)"
        }
        return "https://\(host)"
    }
}

// MARK: - SyncRealmIdentity

/// One local Vault is bound to exactly one (origin, user) realm.
public struct SyncRealmIdentity: Hashable, Sendable {
    public let origin: SyncRealmOrigin
    public let userID: UUID

    public init(origin: SyncRealmOrigin, userID: UUID) {
        self.origin = origin
        self.userID = userID
    }

    public init(originURL: URL, userID: UUID) throws {
        self.init(origin: try SyncRealmOrigin(validating: originURL), userID: userID)
    }

    public var normalizedOrigin: String { origin.normalized }
}

// MARK: - Backend configuration pairing

/// One configuration tier. URL and publishable key are always selected as a
/// complete pair from the same tier; a tier that overrides exactly one of the
/// two is rejected instead of being completed from another tier.
public struct SyncConfigurationTier: Sendable {
    public let url: String?
    public let key: String?

    public init(url: String?, key: String?) {
        self.url = url
        self.key = key
    }
}

/// Immutable backend endpoint + publishable key.
public struct SyncBackendConfiguration: Hashable, Sendable {
    public let origin: SyncRealmOrigin
    public let publishableKey: String

    public init(url: URL, publishableKey: String) throws {
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw SyncRealmError.incompleteConfigurationPair
        }
        self.origin = try SyncRealmOrigin(validating: url)
        self.publishableKey = key
    }

    public var url: URL {
        // Origin normalization guarantees a parseable root URL.
        URL(string: origin.normalized) ?? URL(fileURLWithPath: "/")
    }
}

public enum SyncConfigurationPair {
    /// Walks `tiers` in priority order and returns the first tier that carries
    /// BOTH values. A tier carrying only one of the two fails closed with
    /// `partialConfigurationOverride` — the missing half is never borrowed
    /// from another tier. The final `fallback` tier must also be complete.
    public static func select(
        tiers: [SyncConfigurationTier],
        fallback: SyncConfigurationTier
    ) throws -> SyncBackendConfiguration {
        for tier in tiers + [fallback] {
            let url = tier.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = tier.key?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasURL = !(url ?? "").isEmpty
            let hasKey = !(key ?? "").isEmpty
            if hasURL != hasKey {
                throw SyncRealmError.partialConfigurationOverride
            }
            guard hasURL, hasKey, let url, let key else { continue }
            guard let parsed = URL(string: url) else {
                throw SyncRealmError.invalidOrigin(.missingHost)
            }
            return try SyncBackendConfiguration(url: parsed, publishableKey: key)
        }
        throw SyncRealmError.incompleteConfigurationPair
    }
}

// MARK: - JWT claim pre-check

/// Claims extracted from a session access token for LOCAL routing pre-checks.
///
/// A matching decode is not authentication proof: the token is only accepted
/// for use after `SyncSessionVerifier` confirms the same claims against the
/// backend's own `/auth/v1/user` endpoint on the same origin.
public struct SyncSessionTokenClaims: Equatable, Sendable {
    public let issuer: String
    public let subject: String
    public let role: String
    public let expiresAt: Date

    public init(issuer: String, subject: String, role: String, expiresAt: Date) {
        self.issuer = issuer
        self.subject = subject
        self.role = role
        self.expiresAt = expiresAt
    }

    public var subjectUserID: UUID? { UUID(uuidString: subject) }

    /// Decodes the JWT payload without verifying the signature (the signature
    /// is proven by the server round-trip, not locally).
    public static func decode(_ token: String) throws -> SyncSessionTokenClaims {
        let pieces = token.split(separator: ".")
        guard pieces.count == 3 else {
            throw SyncRealmError.sessionTokenInvalid(.format)
        }
        var base64 = String(pieces[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = object["iss"] as? String,
              let subject = object["sub"] as? String,
              let role = object["role"] as? String else {
            throw SyncRealmError.sessionTokenInvalid(.format)
        }
        let expiresAt: Date
        if let seconds = object["exp"] as? Double {
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else if let seconds = object["exp"] as? Int {
            expiresAt = Date(timeIntervalSince1970: Double(seconds))
        } else {
            throw SyncRealmError.sessionTokenInvalid(.format)
        }
        return SyncSessionTokenClaims(
            issuer: issuer,
            subject: subject,
            role: role,
            expiresAt: expiresAt
        )
    }

    /// Verifies this token may be used against `identity` right now: issuer
    /// must be `origin/auth/v1`, subject must be the expected user UUID, role
    /// must be the authenticated user role, and the token must not be expired.
    public func verify(for identity: SyncRealmIdentity, now: Date = Date()) throws {
        guard issuer == identity.origin.authIssuer else {
            throw SyncRealmError.sessionTokenInvalid(.issuer)
        }
        guard subject.caseInsensitiveCompare(identity.userID.uuidString) == .orderedSame else {
            throw SyncRealmError.sessionTokenInvalid(.subject)
        }
        guard role == "authenticated" else {
            throw SyncRealmError.sessionTokenInvalid(.role)
        }
        guard expiresAt > now else {
            throw SyncRealmError.sessionTokenInvalid(.expired)
        }
    }
}

// MARK: - Verified session context

/// Immutable, shared backend/session context. The uploader, puller and
/// downloader all consume the SAME context value so no call path can assemble
/// an inconsistent URL/key/user triple.
public struct SyncSessionContext: Equatable, Sendable {
    public let identity: SyncRealmIdentity
    public let configuration: SyncBackendConfiguration
    public let serverVerifiedUserID: UUID
    public let serverVerifiedAt: Date

    /// Builds a context only after `SyncSessionVerifier` proved the user on
    /// the same origin. The public initializer still enforces internal
    /// consistency so a hand-built context can never mix realms.
    public init(
        identity: SyncRealmIdentity,
        configuration: SyncBackendConfiguration,
        serverVerifiedUserID: UUID,
        serverVerifiedAt: Date
    ) throws {
        guard configuration.origin == identity.origin else {
            throw SyncRealmError.realmMismatch
        }
        guard serverVerifiedUserID == identity.userID else {
            throw SyncRealmError.serverUserMismatch
        }
        self.identity = identity
        self.configuration = configuration
        self.serverVerifiedUserID = serverVerifiedUserID
        self.serverVerifiedAt = serverVerifiedAt
    }

    /// Local claim pre-check before any network send. Not authentication.
    public func verifyAccessToken(_ token: String, now: Date = Date()) throws {
        try SyncSessionTokenClaims.decode(token).verify(for: identity, now: now)
    }
}

/// One configured session: the verified context, its generation lease, and
/// the ONE session-scoped exact-token proof cache shared by the uploader,
/// puller and downloader. Callers cannot assemble an inconsistent
/// URL/key/user/token set.
public struct SyncSession: Sendable {
    public let context: SyncSessionContext
    public let lease: SyncSessionLease
    public let tokens: SyncSessionTokenProver

    public init(
        context: SyncSessionContext,
        lease: SyncSessionLease = SyncSessionLease(),
        proofTransport: HTTPTransport? = nil,
        seededToken: String? = nil,
        seededClaims: SyncSessionTokenClaims? = nil
    ) {
        self.context = context
        self.lease = lease
        self.tokens = SyncSessionTokenProver(
            context: context,
            lease: lease,
            proofTransport: proofTransport,
            seededToken: seededToken,
            seededClaims: seededClaims
        )
    }

    public var identity: SyncRealmIdentity { context.identity }
    public var configuration: SyncBackendConfiguration { context.configuration }
}

// MARK: - Generation lease

/// Invalidatable session-generation lease.
///
/// ## Linearization contract
///
/// `withValidity` is the synchronous commit gate for every durable side
/// effect (transfer obligations, media install, raw apply commit, outbox ack,
/// cursor update). The gate and `invalidate()` share one lock, so each
/// invalidation linearizes as a whole against each commit:
///
///   - A commit that entered `withValidity` BEFORE `invalidate()` linearizes
///     may run to completion; `invalidate()` returns only after that commit
///     finished. This is the documented "pre-invalidation already-entered
///     commit" ordering — it is safe because the commit was checked against
///     the same lease the invalidation targets, and invalidation of a replaced
///     session only guarantees no NEW effects for the old session.
///   - A commit that enters AFTER `invalidate()` linearized is refused and
///     performs no effect at all.
///
/// The gate body is synchronous on purpose: never `await` inside
/// `withValidity` (that would hold the lock across suspension). Network sends
/// happen OUTSIDE the gate; each send re-checks validity first and each
/// consumed result commits through the gate.
public final class SyncSessionLease: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var valid = true

    public init() {}

    public var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    /// Runs `body` iff the lease is still valid, synchronously linearized
    /// with `invalidate()`.
    public func withValidity<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw SyncRealmError.sessionInvalidated }
        return try body()
    }

    /// Pre-send / pre-await validity re-check.
    public func assertValid() throws {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw SyncRealmError.sessionInvalidated }
    }

    /// Linearizes invalidation. Any commit already inside `withValidity`
    /// finishes first (see the type documentation); every later commit fails.
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }
}

// MARK: - Exact-token proof boundary

/// Narrow typed boundary for an access token that has passed BOTH the local
/// claim pre-check AND the same-origin `/auth/v1/user` server proof for the
/// EXACT token value in this live session. A raw provider `String` cannot
/// reach sync effects without going through `SyncSessionTokenProver`.
public struct SyncVerifiedAccessToken: Sendable, Equatable {
    public let value: String
    public let claims: SyncSessionTokenClaims

    internal init(value: String, claims: SyncSessionTokenClaims) {
        self.value = value
        self.claims = claims
    }
}

/// Session-scoped verifier/proof cache bound to the immutable realm context
/// and generation lease. Every NEW token value needs local claim checks and a
/// same-origin `/auth/v1/user` success with matching UUID before it may drive
/// any durable preparation or mutation. The initial server proof seeds ONLY
/// the exact token it proved; reuse is allowed only for that same unexpired
/// token in this live context. Concurrent candidates singleflight PER EXACT
/// TOKEN VALUE (a flight's result is only ever delivered to waiters that
/// requested that same value). Proof completion — expiry recheck, cache write
/// and capability finalization — linearizes inside the lease gate at the
/// CURRENT clock; cache writes after invalidation are refused. Tokens are
/// never persisted or logged.
public final class SyncSessionTokenProver: @unchecked Sendable {
    private final class Flight {
        var waiters: [CheckedContinuation<SyncVerifiedAccessToken, Error>] = []
        var result: Result<SyncVerifiedAccessToken, Error>?
    }

    private let lock = NSRecursiveLock()
    private let context: SyncSessionContext
    private let lease: SyncSessionLease
    private let proofTransport: HTTPTransport?
    private let clock: @Sendable () -> Date
    private var provenToken: String?
    private var provenClaims: SyncSessionTokenClaims?
    private var flights: [String: Flight] = [:]

    public init(
        context: SyncSessionContext,
        lease: SyncSessionLease,
        proofTransport: HTTPTransport?,
        seededToken: String? = nil,
        seededClaims: SyncSessionTokenClaims? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.lease = lease
        self.proofTransport = proofTransport
        self.clock = clock
        if let seededToken, let seededClaims {
            self.provenToken = seededToken
            self.provenClaims = seededClaims
        }
    }

    /// Verifies `raw` against the realm and, for any token value not already
    /// proven in this live session, against the backend's own `/auth/v1/user`
    /// answer on the same origin.
    public func verifiedToken(_ raw: String) async throws -> SyncVerifiedAccessToken {
        try lease.assertValid()
        guard !raw.isEmpty else { throw SyncRealmError.sessionTokenInvalid(.format) }

        // Cached proof: reused ONLY for the exact token value, and only while
        // it is still unexpired at the current clock.
        lock.lock()
        if provenToken == raw {
            let claims = provenClaims
            lock.unlock()
            guard let claims else { throw SyncRealmError.sessionTokenInvalid(.unproven) }
            guard claims.expiresAt > clock() else {
                throw SyncRealmError.sessionTokenInvalid(.expired)
            }
            try lease.assertValid()
            return SyncVerifiedAccessToken(value: raw, claims: claims)
        }
        // Per-exact-token singleflight: join the flight for THIS value only.
        if let flight = flights[raw] {
            lock.unlock()
            let delivered = try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result = flight.result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    flight.waiters.append(continuation)
                    lock.unlock()
                }
            }
            return try redeliver(delivered, raw: raw)
        }
        let flight = Flight()
        flights[raw] = flight
        lock.unlock()

        let outcome = await proveCandidate(raw, flight: flight)
        return try outcome.get()
    }

    /// Local claims + same-origin server proof for one exact candidate, then
    /// linearized finalization of the cache write and the capability.
    private func proveCandidate(
        _ raw: String,
        flight: Flight
    ) async -> Result<SyncVerifiedAccessToken, Error> {
        let outcome: Result<SyncVerifiedAccessToken, Error>
        do {
            // Local claims are a pre-check only — the server proof below is
            // the authentication evidence for this exact value.
            let claims = try SyncSessionTokenClaims.decode(raw)
            try claims.verify(for: context.identity, now: clock())
            guard let proofTransport else {
                throw SyncRealmError.sessionTokenInvalid(.unproven)
            }
            let serverID = try await SyncSessionVerifier.proofServerUser(
                configuration: context.configuration,
                accessToken: raw,
                transport: proofTransport
            )
            guard serverID == context.identity.userID else {
                throw SyncRealmError.serverUserMismatch
            }
            // Finalize under the lease gate at the CURRENT clock: recheck the
            // candidate's expiry and commit the cache write atomically with
            // the still-live session. No await happens inside the gate.
            let capability = try lease.withValidity {
                guard claims.expiresAt > clock() else {
                    throw SyncRealmError.sessionTokenInvalid(.expired)
                }
                // Cache readers use this same lock. Keep the lock order
                // lease -> cache; cached readers release cache before lease.
                lock.lock()
                defer { lock.unlock() }
                if provenToken != raw {
                    provenToken = raw
                    provenClaims = claims
                }
                return SyncVerifiedAccessToken(value: raw, claims: claims)
            }
            outcome = .success(capability)
        } catch {
            outcome = .failure(error)
        }

        // Deliver only to waiters of THIS exact token; the flight's result is
        // never shared with a different candidate.
        lock.lock()
        flight.result = outcome
        let waiters = flight.waiters
        flight.waiters.removeAll()
        flights[raw] = nil
        lock.unlock()
        for waiter in waiters {
            waiter.resume(with: outcome)
        }
        return outcome
    }

    /// Every joined waiter is rechecked on delivery: active lease, still
    /// unexpired at the current clock, and the capability matches the
    /// requested value exactly.
    private func redeliver(
        _ capability: SyncVerifiedAccessToken,
        raw: String
    ) throws -> SyncVerifiedAccessToken {
        try lease.assertValid()
        guard capability.value == raw else {
            throw SyncRealmError.sessionTokenInvalid(.unproven)
        }
        guard capability.claims.expiresAt > clock() else {
            throw SyncRealmError.sessionTokenInvalid(.expired)
        }
        return capability
    }
}

// MARK: - Server user proof

/// Upgrades locally decoded claims into a verified session context by asking
/// the BACKEND (`{origin}/auth/v1/user`, same URL/key pair) which user the
/// token actually authenticates. The decoded JWT alone is never auth proof.
public enum SyncSessionVerifier {
    /// Same-origin `/auth/v1/user` proof for ONE exact token value. Returns
    /// the server-confirmed user UUID.
    public static func proofServerUser(
        configuration: SyncBackendConfiguration,
        accessToken: String,
        transport: HTTPTransport
    ) async throws -> UUID {
        guard let proofURL = URL(string: configuration.origin.normalized + "/auth/v1/user") else {
            // Bounded guard instead of force-unwrapping; a normalized origin
            // must always compose, so this is unreachable config corruption.
            throw SyncRealmError.serverUserUnverified(status: 0)
        }
        var request = URLRequest(url: proofURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncRealmError.serverUserUnverified(status: 0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SyncRealmError.serverUserUnverified(status: http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverIDString = object["id"] as? String,
              let serverID = UUID(uuidString: serverIDString) else {
            throw SyncRealmError.serverUserMismatch
        }
        return serverID
    }

    public static func verifiedSession(
        configuration: SyncBackendConfiguration,
        accessToken: String,
        transport: HTTPTransport,
        expectedUserID: UUID? = nil,
        now: Date = Date()
    ) async throws -> SyncSession {
        let claims = try SyncSessionTokenClaims.decode(accessToken)
        guard let subjectUserID = claims.subjectUserID else {
            throw SyncRealmError.sessionTokenInvalid(.subject)
        }
        if let expectedUserID, expectedUserID != subjectUserID {
            throw SyncRealmError.serverUserMismatch
        }
        let identity = SyncRealmIdentity(
            origin: configuration.origin,
            userID: subjectUserID
        )
        try claims.verify(for: identity, now: now)

        let serverID = try await proofServerUser(
            configuration: configuration,
            accessToken: accessToken,
            transport: transport
        )
        guard serverID == subjectUserID else {
            throw SyncRealmError.serverUserMismatch
        }
        let context = try SyncSessionContext(
            identity: identity,
            configuration: configuration,
            serverVerifiedUserID: serverID,
            serverVerifiedAt: now
        )
        // The proof seeds ONLY the exact token it just proved.
        return SyncSession(
            context: context,
            proofTransport: transport,
            seededToken: accessToken,
            seededClaims: claims
        )
    }
}

// MARK: - Transfer sidecar realm binding

/// Realm-binding verdict for the attachment transfer sidecar.
///
/// The sidecar may carry a realm header (`realm_origin` + `realm_user_id`).
/// Old state without a header is NEVER guessed into a new project: it is held
/// (`legacyRealmUnverified`) and left byte-for-byte untouched. The same rules
/// back `SyncAccountStateStore`'s first-bind decision (a Vault with unproven
/// cloud obligations is not "first unclaimed") and `AttachmentTransferStore`'s
/// read/reuse decision.
public enum SyncTransferSidecarBinding {
    public enum Verdict: Equatable, Sendable {
        /// No cloud obligations and no foreign header: a genuine first claim
        /// may bind this state to the expected realm.
        case claimable
        /// The sidecar header proves exactly the expected realm.
        case proven
        /// The sidecar header proves a DIFFERENT realm. Hold; never rebind.
        case foreign(SyncRealmIdentity)
        /// Obligations exist without a provable realm header (legacy or
        /// corrupt state). Hold; never guess.
        case unproven
    }

    /// Canonical sidecar filename. The old name is retained on purpose so no
    /// rename can bypass detection of pre-realm state.
    public static let transferStateFilename = "attachment-transfers-v1.json"
    public static let partialDownloadsDirectoryName = "downloads"

    public static func transfersFileURL(vaultRoot: URL) -> URL {
        syncDirectory(vaultRoot: vaultRoot)
            .appendingPathComponent(transferStateFilename)
    }

    public static func partialDownloadsDirectory(vaultRoot: URL) -> URL {
        syncDirectory(vaultRoot: vaultRoot)
            .appendingPathComponent(partialDownloadsDirectoryName, isDirectory: true)
    }

    static func syncDirectory(vaultRoot: URL) -> URL {
        vaultRoot
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
    }

    public static func inspect(
        vaultRoot: URL,
        expecting realm: SyncRealmIdentity
    ) -> Verdict {
        let evaluation = evaluate(vaultRoot: vaultRoot)
        // Corruption and unreadable state are checked FIRST: an unknown or
        // malformed shape can never be downgraded to "empty" (claimable) or
        // accepted through a coexisting header.
        if evaluation.corrupt || evaluation.partialsUnknown {
            return .unproven
        }
        if let header = evaluation.header {
            return header == realm ? .proven : .foreign(header)
        }
        return evaluation.hasObligations ? .unproven : .claimable
    }

    /// True only for a genuinely unclaimed sidecar: no realm header at all,
    /// no records, no blocked records, no partial downloads. Used to decide
    /// whether the legacy uploader fallback is even a candidate.
    public static func isUnclaimed(vaultRoot: URL) -> Bool {
        let evaluation = evaluate(vaultRoot: vaultRoot)
        return evaluation.header == nil
            && !evaluation.corrupt
            && !evaluation.partialsUnknown
            && !evaluation.hasObligations
    }

    private struct Evaluation {
        var header: SyncRealmIdentity?
        var hasObligations: Bool
        var corrupt: Bool
        var partialsUnknown: Bool
    }

    private enum PartialState {
        case none
        case present
        /// The downloads location exists but cannot be proven free of
        /// partials (unreadable directory, non-directory entry, dangling or
        /// malformed entries). Absence is never assumed from unreadability.
        case unknown
    }

    // Strict typed shapes of the schema-v1 transfer sidecar. Decoding with
    // `JSONDecoder` gives real JSON-type validation — a JSON `true` never
    // decodes as `Int`, `null` never fills a non-optional field, fractional
    // numbers never become integers — unlike JSONSerialization/NSNumber
    // bridging where `1 is Bool` also holds on Darwin. Unknown or truncated
    // documents are held instead of silently treated as empty. The shapes
    // mirror the canonical `AttachmentTransferStore` Codable records so every
    // record VALUE is validated, not just key presence.
    private struct SidecarDocument: Codable {
        var schemaVersion: Int
        var realmOrigin: String?
        var realmUserID: String?
        var records: [RecordShape]
        var blockedRecords: [BlockedRecordShape]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case realmOrigin = "realm_origin"
            case realmUserID = "realm_user_id"
            case records
            case blockedRecords = "blocked_records"
        }
    }

    private struct RecordShape: Codable {
        static let directions: Set<String> = ["upload", "download"]
        static let statuses: Set<String> = [
            "pending", "transferring", "transferred", "paused", "failed",
            "unsupported", "quota_failed",
        ]

        var id: String
        var operationID: UUID?
        var memoID: UUID
        var localPath: String
        var descriptor: DescriptorShape
        var direction: String
        var status: String
        var resumableURL: URL?
        var uploadOffset: Int64
        var lastError: String?
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case operationID = "operation_id"
            case memoID = "memo_id"
            case localPath = "local_path"
            case descriptor
            case direction
            case status
            case resumableURL = "resumable_url"
            case uploadOffset = "upload_offset"
            case lastError = "last_error"
            case updatedAt = "updated_at"
        }

        func isWellTyped() -> Bool {
            !id.isEmpty
                && !localPath.isEmpty
                && Self.directions.contains(direction)
                && Self.statuses.contains(status)
                && uploadOffset >= 0
                && descriptor.isWellTyped()
        }
    }

    private struct DescriptorShape: Codable {
        var position: Int
        var kind: String
        var contentSHA256: String
        var sizeBytes: Int64
        var mimeType: String
        var objectKey: String
        var originalFilename: String
        var durationMilliseconds: Int?
        var transcript: String?
        var transcriptionStatus: String?

        enum CodingKeys: String, CodingKey {
            case position
            case kind
            case contentSHA256 = "content_sha256"
            case sizeBytes = "size_bytes"
            case mimeType = "mime_type"
            case objectKey = "object_key"
            case originalFilename = "original_filename"
            case durationMilliseconds = "duration_ms"
            case transcript
            case transcriptionStatus = "transcription_status"
        }

        func isWellTyped() -> Bool {
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            return position >= 0
                && !kind.isEmpty
                && contentSHA256.count == 64
                && contentSHA256.unicodeScalars.allSatisfy { hex.contains($0) }
                && sizeBytes >= 0
                && !mimeType.isEmpty
                && !objectKey.isEmpty
                && !originalFilename.isEmpty
                && (durationMilliseconds ?? 0) >= 0
                && (transcript?.utf8.count ?? 0) <= 200_000
                && [nil, "pending", "done", "failed"].contains(transcriptionStatus)
        }
    }

    private struct BlockedRecordShape: Codable {
        var operationID: UUID
        var memoID: UUID
        var localPath: String
        var status: String
        var errorCode: String
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case memoID = "memo_id"
            case localPath = "local_path"
            case status
            case errorCode = "error_code"
            case updatedAt = "updated_at"
        }

        func isWellTyped() -> Bool {
            RecordShape.statuses.contains(status) && !errorCode.isEmpty
        }
    }

    private static func evaluate(vaultRoot: URL) -> Evaluation {
        let partials = partialState(vaultRoot: vaultRoot)
        let partialsUnknown = partials == .unknown
        let hasPartials = partials == .present

        let fileURL = transfersFileURL(vaultRoot: vaultRoot)
        let fileAttributes: [FileAttributeKey: Any]?
        do {
            fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch let error as NSError {
            if isNoSuchFile(error) {
                // Absent: only partial files can hold obligations.
                return Evaluation(
                    header: nil,
                    hasObligations: hasPartials,
                    corrupt: false,
                    partialsUnknown: partialsUnknown
                )
            }
            // Unreadable state is never assumed absent.
            return Evaluation(
                header: nil,
                hasObligations: true,
                corrupt: true,
                partialsUnknown: partialsUnknown
            )
        }
        guard fileAttributes?[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: fileURL) else {
            // Present but not a readable regular JSON file: hold, preserve.
            return Evaluation(
                header: nil,
                hasObligations: true,
                corrupt: true,
                partialsUnknown: partialsUnknown
            )
        }
        return evaluate(document: data, hasPartials: hasPartials, partialsUnknown: partialsUnknown)
    }

    /// Strict typed evaluation. Corruption is decided BEFORE any header
    /// verdict: a matching header can never outrank corrupt records.
    private static func evaluate(
        document data: Data,
        hasPartials: Bool,
        partialsUnknown: Bool
    ) -> Evaluation {
        func corrupt() -> Evaluation {
            Evaluation(
                header: nil,
                hasObligations: true,
                corrupt: true,
                partialsUnknown: partialsUnknown
            )
        }
        let document: SidecarDocument
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            document = try decoder.decode(SidecarDocument.self, from: data)
        } catch {
            return corrupt()
        }
        // Only the schema version the store actually writes is understood;
        // booleans, fractions, nulls and unknown versions never pass here.
        guard document.schemaVersion == 1 else { return corrupt() }
        guard document.records.allSatisfy({ $0.isWellTyped() }),
              document.blockedRecords?.allSatisfy({ $0.isWellTyped() }) ?? true else {
            return corrupt()
        }
        let header: SyncRealmIdentity?
        do {
            header = try parseHeaderStrict(
                origin: document.realmOrigin,
                userID: document.realmUserID
            )
        } catch {
            // Partial or malformed realm headers are corruption, not absence.
            return corrupt()
        }
        return Evaluation(
            header: header,
            hasObligations: !document.records.isEmpty
                || !(document.blockedRecords ?? []).isEmpty
                || hasPartials,
            corrupt: false,
            partialsUnknown: partialsUnknown
        )
    }

    private static func isNoSuchFile(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    /// Strict header parse. Both fields must be present and well-typed, or
    /// both absent; anything in between is malformed state.
    private static func parseHeaderStrict(
        origin originString: String?,
        userID userString: String?
    ) throws -> SyncRealmIdentity? {
        let hasOrigin = originString != nil
        let hasUser = userString != nil
        guard hasOrigin || hasUser else { return nil }
        guard hasOrigin, hasUser,
              let originString, let userString,
              let userID = UUID(uuidString: userString) else {
            throw SyncRealmError.legacyRealmUnverified
        }
        let origin = try SyncRealmOrigin(validating: originString)
        guard origin.normalized == originString else {
            throw SyncRealmError.legacyRealmUnverified
        }
        return SyncRealmIdentity(origin: origin, userID: userID)
    }

    private static func partialState(vaultRoot: URL) -> PartialState {
        let directory = partialDownloadsDirectory(vaultRoot: vaultRoot)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        } catch let error as NSError {
            if isNoSuchFile(error) { return .none }
            // Unreadable is never assumed absent.
            return .unknown
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            // A regular file or symlink where the partial directory belongs
            // cannot be enumerated: partial state is unknown.
            return .unknown
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .unknown
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".DS_Store" { continue }
            if name.hasSuffix(".partial") {
                // Any partial obligation (including dangling symlinks).
                return .present
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
            if attributes?[.type] as? FileAttributeType != .typeRegular {
                // Dangling symlinks and other non-regular entries count as
                // held state.
                return .present
            }
        }
        return .none
    }
}
