import Foundation

// MARK: - Runtime Key Resolution
// GeneratedSecrets.swift is gitignored (auto-generated from .env).
// This file is committed and provides computed vars that prefer
// UserDefaults keys saved during Onboarding over the compiled-in values.
extension Secrets {
    static var resolvedDeepSeekApiKey: String {
        UserDefaults.standard.string(forKey: "runtimeDeepSeekKey").flatMap { $0.isEmpty ? nil : $0 } ?? deepSeekApiKey
    }
    static var resolvedOpenAIWhisperApiKey: String {
        UserDefaults.standard.string(forKey: "runtimeOpenAIKey").flatMap { $0.isEmpty ? nil : $0 } ?? openAIWhisperApiKey
    }
    static var resolvedOpenWeatherApiKey: String {
        UserDefaults.standard.string(forKey: "runtimeOpenWeatherKey").flatMap { $0.isEmpty ? nil : $0 } ?? openWeatherApiKey
    }
}
