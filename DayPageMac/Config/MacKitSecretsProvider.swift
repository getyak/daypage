import Foundation
import DayPageServices
import DayPageStorage

// MARK: - MacKitSecretsProvider

/// M1 placeholder secrets provider for the Mac app. All API keys are empty
/// strings — services downstream (LLMClient, WeatherService, FeedbackService)
/// already handle the "" case by surfacing a "key not configured" error
/// instead of crashing. M2+ will wire up either a macOS-native Keychain read
/// or a Settings → API Keys flow.
struct MacKitSecretsProvider: KitSecretsProvider {
    var sentryDSN: String           { "" }
    var deepSeekBaseURL: String     { "" }
    var deepSeekModel: String       { "" }
    var deepSeekApiKey: String      { "" }
    var openWeatherApiKey: String   { "" }
    var githubBotToken: String      { "" }
}

// MARK: - MacSentryAdapter

/// M1 placeholder Sentry adapter. Returns `isEnabled = false` so the Kit
/// breadcrumb / span code paths short-circuit immediately. Wiring up the
/// real Sentry SDK for macOS is a future step (M5+) that depends on whether
/// we ship telemetry from the Mac client at all.
struct MacSentryAdapter: SentryAdapter {
    var isEnabled: Bool { false }
    func breadcrumb(category: String, level: SentryLevel, message: String) {}
    func captureError(_ error: Error) {}
    func startTransaction(name: String, operation: String) -> SentrySpan? { nil }
}
