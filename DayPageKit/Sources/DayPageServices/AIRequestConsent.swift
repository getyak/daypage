import Foundation

// MARK: - AIAuthorizationError

/// Typed authorization failures for every AI/ASR outbound attempt.
///
/// Deliberately distinct from `LLMError` / transport errors so the UI can never
/// mistake "you did not authorize this send" for a network failure, and so the
/// retry classifier treats a denial as TERMINAL (issue #928):
///
///   - `aiDisabled`: the live master AI switch is off ("local only" mode).
///   - `screenshotCloudDisabled`: screenshot cloud analysis is a separate
///     explicit opt-in (default off) and is not enabled.
public enum AIAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    case aiDisabled
    case screenshotCloudDisabled

    public var errorDescription: String? {
        switch self {
        case .aiDisabled:
            return NSLocalizedString(
                "ai.consent.error.disabled",
                comment: "Shown when an AI/ASR send is blocked because the master AI switch is off"
            )
        case .screenshotCloudDisabled:
            return NSLocalizedString(
                "ai.consent.error.screenshot_disabled",
                comment: "Shown when a screenshot cloud send is blocked because screenshot cloud analysis is off"
            )
        }
    }
}

// MARK: - AIConsentChecking

/// The authorization dependency injected at outbound client boundaries
/// (`LLMClient`, screenshot understanding adapter, backend authoring requests,
/// Doubao ASR clients, credential test buttons). Production code passes
/// ``LiveAIConsent`` / ``LiveScreenshotCloudConsent``; tests inject fakes to
/// exercise transport behavior without touching global state.
public protocol AIConsentChecking: Sendable {
    /// Returns normally when the current outbound attempt is authorized.
    /// Throws ``AIAuthorizationError`` otherwise. Called BEFORE every
    /// transport attempt — never cache the result.
    func authorize() throws
}

/// Production checker: re-reads the live master switch on every call
/// (UserDefaults is the source of truth, so a toggle in Settings takes effect
/// on the very next attempt).
public struct LiveAIConsent: AIConsentChecking {
    public init() {}
    public func authorize() throws {
        try AIRequestConsent.authorize()
    }
}

/// Production checker for screenshot cloud understanding: requires the master
/// AI switch AND the separate screenshot cloud opt-in (default off).
public struct LiveScreenshotCloudConsent: AIConsentChecking {
    public init() {}
    public func authorize() throws {
        try AIRequestConsent.authorizeScreenshotCloud()
    }
}

/// Explicit permissive policy for tests whose subject is transport behavior
/// only (contract tests), never for production wiring.
public struct AllowAllAIConsent: AIConsentChecking {
    public init() {}
    public func authorize() throws {}
}

// MARK: - AIRequestConsent

/// The single outbound-authorization policy for AI/ASR traffic (issue #928).
///
/// Frozen policy: the existing master AI switch is enforced at every actual
/// new request boundary. Defaults and the reachable consent UI are preserved —
/// there is NO v2 explicit-grant/version requirement, and API keys are not
/// consent. Enforcement points call `authorize()` at attempt time (including
/// each retry and every frame/segment of an open stream).
public enum AIRequestConsent {

    // MARK: Enforcement

    /// Throws ``AIAuthorizationError`` unless the current outbound attempt is
    /// authorized by the live master switch. Reads live state on every call —
    /// do not cache.
    public nonisolated static func authorize(in store: UserDefaults = .standard) throws {
        guard AppSettings.aiFeaturesEnabled(in: store) else {
            throw AIAuthorizationError.aiDisabled
        }
    }

    /// Screenshot cloud analysis additionally requires its own explicit
    /// opt-in (default off). Master-off is reported as `aiDisabled` first so
    /// the stricter reason wins.
    public nonisolated static func authorizeScreenshotCloud(in store: UserDefaults = .standard) throws {
        try authorize(in: store)
        guard AppSettings.screenshotCloudAnalysisEnabled(in: store) else {
            throw AIAuthorizationError.screenshotCloudDisabled
        }
    }

    /// Live verdict for UI affordances (buttons, toggles). Authorization for
    /// real traffic must still go through `authorize()` at attempt time.
    public nonisolated static func isAuthorized(in store: UserDefaults = .standard) -> Bool {
        (try? authorize(in: store)) != nil
    }

    /// Live screenshot-cloud verdict for UI affordances.
    public nonisolated static func isScreenshotCloudAuthorized(in store: UserDefaults = .standard) -> Bool {
        (try? authorizeScreenshotCloud(in: store)) != nil
    }
}
