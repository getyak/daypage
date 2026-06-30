import Foundation
import DayPageStorage

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
public extension Secrets {
    public static var resolvedDeepSeekApiKey: String {
        resolve(keychainName: "deepSeekApiKey", fallback: deepSeekApiKey)
    }
    public static var resolvedOpenAIWhisperApiKey: String {
        resolve(keychainName: "openAIWhisperApiKey", fallback: openAIWhisperApiKey)
    }
    public static var resolvedOpenWeatherApiKey: String {
        resolve(keychainName: "openWeatherApiKey", fallback: openWeatherApiKey)
    }
    public static var resolvedGitHubToken: String {
        resolve(keychainName: "githubToken", fallback: kubotGitHubToken)
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
