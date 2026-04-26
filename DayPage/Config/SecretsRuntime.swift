import Foundation

// MARK: - Runtime Key Resolution
// GeneratedSecrets.swift is gitignored (auto-generated from .env).
// This file is committed and provides computed vars that prefer
// UserDefaults keys saved during Onboarding over the compiled-in values.
extension Secrets {
    static var resolvedDashScopeApiKey: String {
        UserDefaults.standard.string(forKey: "runtimeDashScopeKey").flatMap { $0.isEmpty ? nil : $0 } ?? dashScopeApiKey
    }
    static var resolvedOpenAIWhisperApiKey: String {
        UserDefaults.standard.string(forKey: "runtimeOpenAIKey").flatMap { $0.isEmpty ? nil : $0 } ?? openAIWhisperApiKey
    }
    static var resolvedOpenWeatherApiKey: String {
        UserDefaults.standard.string(forKey: "runtimeOpenWeatherKey").flatMap { $0.isEmpty ? nil : $0 } ?? openWeatherApiKey
    }
}
