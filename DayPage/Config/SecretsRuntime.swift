import Foundation

// MARK: - Runtime Key Resolution
// GeneratedSecrets.swift 已被 gitignore（从 .env 自动生成）。
// 此文件已提交，提供计算属性，优先从 Keychain 读取运行时密钥，
// 回退到编译时写入的值（GeneratedSecrets.swift）。
// US-002: API keys are stored in Keychain (com.daypage.apikeys service)
// rather than UserDefaults to prevent iCloud backup exposure.
extension Secrets {
    static var resolvedDeepSeekApiKey: String {
        KeychainHelper.getAPIKey(for: "deepSeekApiKey") ?? deepSeekApiKey
    }
    static var resolvedOpenAIWhisperApiKey: String {
        KeychainHelper.getAPIKey(for: "openAIWhisperApiKey") ?? openAIWhisperApiKey
    }
    static var resolvedOpenWeatherApiKey: String {
        KeychainHelper.getAPIKey(for: "openWeatherApiKey") ?? openWeatherApiKey
    }
    static var resolvedGitHubToken: String {
        KeychainHelper.get(forKey: "githubToken") ?? ""
    }
}
