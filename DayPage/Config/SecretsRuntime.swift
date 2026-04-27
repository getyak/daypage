import Foundation

// MARK: - Runtime Key Resolution
// GeneratedSecrets.swift 已被 gitignore（从 .env 自动生成）。
// 此文件已提交，提供计算属性，优先使用
// 引导过程中保存的 UserDefaults 密钥，而非编译时写入的值。
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
