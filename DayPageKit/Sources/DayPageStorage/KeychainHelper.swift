import Foundation
import Security

/// `AuthService` 使用的最小化 Keychain 包装器，用于持久化
/// 如果存储在 `UserDefaults` 中会泄露 PII 的标识符
/// （例如 Apple 登录邮箱，Apple 仅首次登录时返回）。
/// 访问类为 `AfterFirstUnlockThisDeviceOnly`，
/// 以便后台刷新任务仍能读取值而无需 iCloud 同步。
public enum KeychainHelper {

    private static let service = "com.daypage.auth"
    private static let apiKeyService = "com.daypage.apikeys"

    // MARK: - API Key Storage (US-002)

    /// Stores an API key securely in Keychain under the `com.daypage.apikeys` service.
    public static func setAPIKey(_ value: String, for identifier: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: identifier,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Retrieves an API key from Keychain. Returns `nil` if not found or empty.
    public static func getAPIKey(for identifier: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Deletes an API key from Keychain.
    public static func deleteAPIKey(for identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: identifier,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Migrates any API keys stored in UserDefaults to Keychain, then removes them from UserDefaults.
    /// Safe to call multiple times — no-ops if the key is already in Keychain or absent from UserDefaults.
    public static func migrateAPIKeysFromUserDefaultsIfNeeded() {
        let migrations: [(udKey: String, keychainId: String)] = [
            ("runtimeDeepSeekKey",         "deepSeekApiKey"),
            ("runtimeOpenAIKey",           "openAIWhisperApiKey"),
            ("runtimeOpenWeatherKey",      "openWeatherApiKey"),
            ("runtimeDoubaoASRAppID",      "doubaoASRAppID"),
            ("runtimeDoubaoASRAccessToken","doubaoASRAccessToken"),
            ("runtimeDoubaoASRSecretKey",  "doubaoASRSecretKey"),
        ]
        for (udKey, keychainId) in migrations {
            guard
                let existing = UserDefaults.standard.string(forKey: udKey),
                !existing.isEmpty
            else { continue }
            // Only migrate if Keychain doesn't already have a value
            if getAPIKey(for: keychainId) == nil {
                setAPIKey(existing, for: keychainId)
            }
            UserDefaults.standard.removeObject(forKey: udKey)
        }
    }

    // MARK: - Auth Token Storage

    public static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // 删除后添加更简单，对我们的用例来说也足够原子化；
        // SecItemUpdate 需要第二个查询字典。
        SecItemDelete(base as CFDictionary)

        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
