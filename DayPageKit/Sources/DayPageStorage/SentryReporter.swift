import Foundation

// MARK: - SentryLevel (Kit-side mirror)

/// Mirror of Sentry's `SentryLevel` enum so Kit callers (RawStorage,
/// ConflictMerger, LLMClient, …) can specify a level without `import Sentry`.
/// The app target's `SentryAdapter` impl bridges these to the real
/// `Sentry.SentryLevel` values at the SDK boundary.
public enum SentryLevel: Sendable, Equatable {
    case debug
    case info
    case warning
    case error
    case fatal
}

// MARK: - Privacy-safe operational event

/// A deliberately narrow event shape for diagnosable auth/sync failures.
///
/// Callers cannot attach arbitrary context, response bodies, memo text, email
/// addresses, or tokens. Every textual field is matched against a small
/// allow-list before it reaches an adapter, so the Sentry boundary remains
/// allow-list based instead of relying on best-effort redaction after collection.
public struct OperationalEvent: Sendable, Equatable {
    public enum NetworkState: String, Sendable {
        case online
        case offline
        case unknown
    }

    public let area: String
    public let stage: String
    public let code: String
    public let correlationID: String
    public let level: SentryLevel
    public let provider: String?
    public let httpStatus: Int?
    public let networkState: NetworkState
    public let pendingCount: Int?
    public let consecutiveFailureCount: Int?

    public init(
        area: String,
        stage: String,
        code: String,
        correlationID: UUID,
        level: SentryLevel = .warning,
        provider: String? = nil,
        httpStatus: Int? = nil,
        networkState: NetworkState = .unknown,
        pendingCount: Int? = nil,
        consecutiveFailureCount: Int? = nil
    ) {
        self.area = Self.allowlisted(area, values: Self.allowedAreas)
        self.stage = Self.allowlisted(stage, values: Self.allowedStages)
        self.code = Self.allowlisted(code, values: Self.allowedCodes)
        self.correlationID = correlationID.uuidString.lowercased()
        self.level = level
        self.provider = provider.map { Self.allowlisted($0, values: Self.allowedProviders) }
        self.httpStatus = httpStatus.map { min(max($0, 100), 599) }
        self.networkState = networkState
        self.pendingCount = pendingCount.map { min(max($0, 0), 100_000) }
        self.consecutiveFailureCount = consecutiveFailureCount.map { min(max($0, 0), 10_000) }
    }

    /// Stable Sentry grouping message. It contains no user-provided data.
    public var message: String {
        "daypage.\(area).failure.\(code)"
    }

    private static let allowedAreas: Set<String> = ["auth", "sync", "config"]
    private static let allowedStages: Set<String> = [
        "preflight", "authorize", "exchange", "send", "verify", "sign_out",
        "outbox_read", "push", "pull", "launch",
    ]
    private static let allowedCodes: Set<String> = [
        "missing_credential", "service_unavailable", "invalid_email", "rate_limited",
        "otp_expired", "otp_mismatch", "otp_locked", "network_unavailable",
        "network_timeout", "network_error", "not_configured", "insecure_scheme",
        "memo_not_found", "invalid_response", "unauthorized", "forbidden",
        "server_error", "conflict", "rejected", "unexpected", "unknown",
    ]
    private static let allowedProviders: Set<String> = [
        "apple", "email_otp", "session", "supabase", "legacy_api", "unknown",
    ]

    private static func allowlisted(_ value: String, values: Set<String>) -> String {
        values.contains(value) ? value : "unknown"
    }
}

// MARK: - SentryAdapter (app-injected)

/// Bridge between Kit (which does NOT import Sentry — see ADR §3 "circular dependency"
/// resolution) and the real Sentry SDK in the app target.
///
/// Why we can't `import Sentry` in Kit:
/// 1. Sentry SDK ships a pre-built xcframework pinned to the Swift compiler
///    version it was built with (e.g. 5.9). When Kit links Sentry as a SwiftPM
///    package dep, Xcode resolves a SECOND copy that conflicts with the app
///    target's own Sentry version. This is what broke iOS build on first
///    attempt (Swift 6.3 vs 5.9.2 module incompatibility).
/// 2. Even if we matched versions, Kit consumers (DayPageMac, future
///    DayPageWatchKit, etc.) would all inherit a hard Sentry dependency they
///    might not want.
///
/// App targets implement this protocol with a thin wrapper around `SentrySDK`
/// and register it via `SentryReporter.adapter = MyAdapter()` during launch
/// (DayPageApp.init).
public protocol SentryAdapter: Sendable {
    /// True if the SDK has been initialised with a DSN. Used as a fast guard
    /// before building Breadcrumb objects.
    var isEnabled: Bool { get }

    /// Forward a breadcrumb to Sentry. Kit passes plain strings + the mirror
    /// SentryLevel; the adapter rebuilds the real Breadcrumb object.
    func breadcrumb(category: String, level: SentryLevel, message: String)

    /// Forward a captured error. Adapter implementations should fall back to
    /// the SDK's `capture(error:)`. Called from a few places where Kit wants
    /// the full crash event, not just a breadcrumb.
    func captureError(_ error: Error)

    /// Capture a bounded operational failure whose fields are safe by
    /// construction. This is preferred over forwarding arbitrary error text.
    func captureOperationalEvent(_ event: OperationalEvent)

    /// Start a Sentry transaction span. Kit holds the returned `SentrySpan`
    /// as an opaque handle. Returning `nil` is allowed (Noop adapter, SDK
    /// disabled) — callers must guard `if let span = ... { span.finish() }`.
    func startTransaction(name: String, operation: String) -> SentrySpan?
}

/// Opaque span handle. Kit only knows the methods declared here; the app
/// target's adapter wraps the real `Sentry.Span` and forwards.
public protocol SentrySpan: AnyObject, Sendable {
    func setTag(_ value: String, key: String)
    func finish()
}

/// Default no-op adapter. Active until the app target registers a real one.
/// Keeps tests and headless build contexts (e.g. `swift build`) from needing
/// the Sentry SDK at all.
public struct NoopSentryAdapter: SentryAdapter {
    public init() {}
    public var isEnabled: Bool { false }
    public func breadcrumb(category: String, level: SentryLevel, message: String) {}
    public func captureError(_ error: Error) {}
    public func captureOperationalEvent(_ event: OperationalEvent) {}
    public func startTransaction(name: String, operation: String) -> SentrySpan? { nil }
}

// MARK: - SentryReporter (Kit-facing facade)

/// Thin guard around `SentryAdapter`. Same surface the codebase has always
/// used (`SentryReporter.breadcrumb(category:level:message:)`,
/// `SentryReporter.isSentryEnabled`) — only the implementation changed: it
/// now routes through the injected adapter instead of calling `SentrySDK`
/// directly.
public enum SentryReporter {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _adapter: SentryAdapter = NoopSentryAdapter()

    /// App-target launch wires up the real Sentry SDK:
    /// `SentryReporter.adapter = AppSentryAdapter()`
    public static var adapter: SentryAdapter {
        get {
            lock.lock(); defer { lock.unlock() }
            return _adapter
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _adapter = newValue
        }
    }

    // MARK: Legacy DSN-based configure path
    //
    // Kept for backwards compatibility with call sites that wrote a DSN string
    // into UserDefaults before the adapter pattern existed. App targets should
    // now prefer `SentryReporter.adapter = ...` over `configure(dsn:)`. Both
    // forms can coexist — `configure(dsn:)` is a no-op if the adapter is
    // already enabled.

    public static let sentryDSNDefaultsKey = "DayPageStorage.SentryDSN"

    /// Kept for source compatibility; the actual SDK gating happens through
    /// the `adapter`'s `isEnabled` getter now. Writing the DSN here remains
    /// useful as a "was Sentry configured at launch?" diagnostic for log
    /// inspection.
    public static func configure(dsn: String) {
        UserDefaults.standard.set(dsn, forKey: sentryDSNDefaultsKey)
    }

    // MARK: Consent gate (issue #922)
    //
    // Remote crash diagnostics are opt-in and default OFF. The app target
    // registers a gate that reflects the persisted `DiagnosticsConsent` value
    // and it is re-evaluated at EVENT TIME — not cached — so revoking consent
    // blocks every future breadcrumb/error/span at this transport boundary even
    // if an adapter or SDK is still alive. A nil gate (Kit-only contexts, other
    // app targets) means "not consent-gated here" and preserves legacy behavior.

    nonisolated(unsafe) private static var _eventsGate: (@Sendable () -> Bool)?

    public static func setEventsGate(_ gate: (@Sendable () -> Bool)?) {
        lock.lock(); defer { lock.unlock() }
        _eventsGate = gate
    }

    /// Re-reads the consent gate for every event. Fail closed only when a gate
    /// exists and refuses — absence of a gate keeps headless/test contexts and
    /// non-consent app targets working as before.
    private static func eventsAllowed() -> Bool {
        lock.lock()
        let gate = _eventsGate
        lock.unlock()
        return gate?() ?? true
    }

    // MARK: Public guard

    public static var isSentryEnabled: Bool {
        adapter.isEnabled && eventsAllowed()
    }

    // MARK: Forwarding API

    public static func breadcrumb(
        category: String,
        level: SentryLevel = .info,
        message: String
    ) {
        // Legacy callers pass arbitrary note/error/network text. Never forward
        // that text, even with consent; use OperationalEvent for safe context.
    }

    public static func captureError(_ error: Error) {
        // NSError.userInfo and localized descriptions can contain transcripts,
        // response bodies, credentials, and account identifiers.
    }

    public static func captureOperationalEvent(_ event: OperationalEvent) {
        let a = adapter
        guard a.isEnabled, eventsAllowed() else { return }
        a.captureOperationalEvent(event)
    }

    /// Start a Sentry transaction span (returns nil when SDK disabled). Use
    /// `defer { span?.finish() }` at the call site.
    public static func startTransaction(name: String, operation: String) -> SentrySpan? {
        // Transaction/span names and tags are unconstrained user text.
        return nil
    }
}
