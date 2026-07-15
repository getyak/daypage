import Foundation
import Sentry
import DayPageStorage
import DayPageServices

// MARK: - Runtime Key Resolution
//
// `GeneratedSecrets.swift` is gitignored and now intentionally empty (P0
// security audit, see `scripts/generate_secrets.sh`). Real secrets must be
// supplied at runtime through the Keychain (the in-app onboarding /
// Settings → API Keys flow writes into the `com.daypage.apikeys` service
// via `KeychainHelper`).
//
// The compile-time `Secrets.xxx` fall-throughs are kept only so that
// `KeychainHelper.getAPIKey(...) ?? Secrets.xxx` collapses to an empty
// string when nothing is configured — callers see `""` instead of crashing,
// and each service is responsible for surfacing a human-readable
// "key not configured" error.
//
// US-002: API keys are stored in Keychain (`com.daypage.apikeys` service)
// rather than UserDefaults to prevent iCloud backup exposure.
extension Secrets {
    static var resolvedDeepSeekApiKey: String {
        resolve(keychainName: "deepSeekApiKey", fallback: deepSeekApiKey)
    }
    static var resolvedOpenAIWhisperApiKey: String {
        resolve(keychainName: "openAIWhisperApiKey", fallback: openAIWhisperApiKey)
    }
    static var resolvedOpenWeatherApiKey: String {
        resolve(keychainName: "openWeatherApiKey", fallback: openWeatherApiKey)
    }
    static var resolvedGitHubToken: String {
        resolve(keychainName: "githubToken", fallback: kubotGitHubToken)
    }
    static var resolvedDoubaoASRAppID: String {
        resolve(keychainName: "doubaoASRAppID", fallback: doubaoASRAppID)
    }
    static var resolvedDoubaoASRAccessToken: String {
        resolve(keychainName: "doubaoASRAccessToken", fallback: doubaoASRAccessToken)
    }
    static var resolvedDoubaoASRSecretKey: String {
        resolve(keychainName: "doubaoASRSecretKey", fallback: doubaoASRSecretKey)
    }

    // MARK: - Internal

    private static func resolve(keychainName: String, fallback: String) -> String {
        if let stored = KeychainHelper.getAPIKey(for: keychainName), !stored.isEmpty {
            return stored
        }
        if !fallback.isEmpty {
            return fallback
        }
        #if DEBUG
        warnMissing(keychainName)
        #endif
        return ""
    }

    #if DEBUG
    /// Print a one-time warning (per key, per process) when a required secret
    /// is missing in both the Keychain and the compile-time placeholders.
    /// Without this, services silently receive `""` and fail downstream with
    /// opaque HTTP errors that hide the real onboarding issue.
    private static func warnMissing(_ key: String) {
        secretsWarnLock.lock()
        let alreadyWarned = secretsWarnedKeys.contains(key)
        if !alreadyWarned { secretsWarnedKeys.insert(key) }
        secretsWarnLock.unlock()

        if !alreadyWarned {
            print("[Secrets] \(key) not configured. Run scripts/generate_secrets.sh or set it via Settings → API Keys (writes to Keychain).")
        }
    }
    #endif
}

#if DEBUG
private let secretsWarnLock = NSLock()
private nonisolated(unsafe) var secretsWarnedKeys: Set<String> = []
#endif

// MARK: - AppKitSecretsProvider (M0 bridge)

/// Concrete `KitSecretsProvider` for the iOS app target. DayPageApp.init
/// instantiates this and registers it via `KitSecrets.register(_:)` so the
/// Kit-side `LLMClient` / `WeatherService` / `FeedbackService` etc. can read
/// the gitignored `Secrets` enum + Keychain-resolved keys without reaching
/// into the app target directly.
struct AppKitSecretsProvider: KitSecretsProvider {
    var sentryDSN: String { Secrets.sentryDSN }
    var deepSeekBaseURL: String { Secrets.deepSeekBaseURL }
    var deepSeekModel: String { Secrets.deepSeekModel }
    var deepSeekApiKey: String { Secrets.resolvedDeepSeekApiKey }
    var openWeatherApiKey: String { Secrets.resolvedOpenWeatherApiKey }
    var githubBotToken: String { Secrets.resolvedGitHubToken }
}

// MARK: - AppSentryAdapter (M0 bridge)

/// Concrete `DayPageStorage.SentryAdapter` for the iOS app target. Bridges Kit's
/// SentryReporter facade to the real Sentry SDK. DayPageApp.init registers via
/// `SentryReporter.adapter = AppSentryAdapter()`.
struct AppSentryAdapter: DayPageStorage.SentryAdapter {

    var isEnabled: Bool {
        !Secrets.sentryDSN.isEmpty
    }

    func breadcrumb(category: String, level: DayPageStorage.SentryLevel, message: String) {
        guard isEnabled else { return }
        let crumb = Breadcrumb()
        crumb.category = category
        crumb.message = message
        crumb.level = level.sentrySDKLevel
        SentrySDK.addBreadcrumb(crumb)
    }

    func captureError(_ error: Error) {
        guard isEnabled else { return }
        SentrySDK.capture(error: error)
    }

    func startTransaction(name: String, operation: String) -> DayPageStorage.SentrySpan? {
        guard isEnabled else { return nil }
        let sdkSpan = SentrySDK.startTransaction(name: name, operation: operation)
        return AppSentrySpan(span: sdkSpan)
    }
}

private extension DayPageStorage.SentryLevel {
    var sentrySDKLevel: Sentry.SentryLevel {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .warning
        case .error:   return .error
        case .fatal:   return .fatal
        }
    }
}

private final class AppSentrySpan: DayPageStorage.SentrySpan, @unchecked Sendable {
    private let span: any Span
    init(span: any Span) { self.span = span }
    func setTag(_ value: String, key: String) { span.setTag(value: value, key: key) }
    func finish() { span.finish() }
}
