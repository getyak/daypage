import Foundation

// MARK: - SentryLevel (Kit-side mirror)

/// Mirror of Sentry's `SentryLevel` enum so Kit callers (RawStorage,
/// ConflictMerger, LLMClient, …) can specify a level without `import Sentry`.
/// The app target's `SentryAdapter` impl bridges these to the real
/// `Sentry.SentryLevel` values at the SDK boundary.
public enum SentryLevel: Sendable {
    case debug
    case info
    case warning
    case error
    case fatal
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

    // MARK: Public guard

    public static var isSentryEnabled: Bool {
        adapter.isEnabled
    }

    // MARK: Forwarding API

    public static func breadcrumb(
        category: String,
        level: SentryLevel = .info,
        message: String
    ) {
        let a = adapter
        guard a.isEnabled else { return }
        a.breadcrumb(category: category, level: level, message: message)
    }

    public static func captureError(_ error: Error) {
        let a = adapter
        guard a.isEnabled else { return }
        a.captureError(error)
    }

    /// Start a Sentry transaction span (returns nil when SDK disabled). Use
    /// `defer { span?.finish() }` at the call site.
    public static func startTransaction(name: String, operation: String) -> SentrySpan? {
        let a = adapter
        guard a.isEnabled else { return nil }
        return a.startTransaction(name: name, operation: operation)
    }
}
