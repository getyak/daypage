import Foundation

/// Bridge between `DayPageKit` (which has no access to the gitignored
/// `Secrets`/`GeneratedSecrets.swift` in app targets) and the build-time
/// secrets baked into each app target.
///
/// Lifecycle: each app target wires up a concrete `KitSecretsProvider`
/// inside `DayPageApp.init` BEFORE constructing any Kit service that
/// reads a secret. Kit code reaches the provider through `KitSecrets.shared`.
///
/// Default behaviour (no provider configured): every accessor returns "".
/// Downstream services already treat empty strings as "not configured" and
/// surface a human-readable error, so the absent-provider path is safe.
public protocol KitSecretsProvider: Sendable {
    var sentryDSN: String { get }

    // DeepSeek (LLM)
    var deepSeekBaseURL: String { get }
    var deepSeekModel: String { get }
    var deepSeekApiKey: String { get }

    // OpenWeather
    var openWeatherApiKey: String { get }

    // GitHub bot token used by FeedbackService when filing issues
    var githubBotToken: String { get }
}

/// Default no-op provider. Returned when an app target has not yet called
/// `KitSecrets.register(_:)`. Services that depend on empty strings
/// surfacing as "not configured" continue to work unchanged.
public struct EmptyKitSecretsProvider: KitSecretsProvider {
    public init() {}
    public var sentryDSN: String { "" }
    public var deepSeekBaseURL: String { "" }
    public var deepSeekModel: String { "" }
    public var deepSeekApiKey: String { "" }
    public var openWeatherApiKey: String { "" }
    public var githubBotToken: String { "" }
}

/// Global registry. Kit code reads `KitSecrets.shared`; app code writes
/// `KitSecrets.register(provider)` once during launch.
public enum KitSecrets {
    nonisolated(unsafe) private static var _shared: KitSecretsProvider = EmptyKitSecretsProvider()
    private static let lock = NSLock()

    public static var shared: KitSecretsProvider {
        lock.lock(); defer { lock.unlock() }
        return _shared
    }

    public static func register(_ provider: KitSecretsProvider) {
        lock.lock(); defer { lock.unlock() }
        _shared = provider
    }
}
