import Foundation
import Security

/// `AuthService` 使用的最小化 Keychain 包装器，用于持久化
/// 如果存储在 `UserDefaults` 中会泄露 PII 的标识符
/// （例如 Apple 登录邮箱，Apple 仅首次登录时返回）。
/// 访问类为 `AfterFirstUnlockThisDeviceOnly`，
/// 以便后台刷新任务仍能读取值而无需 iCloud 同步。
public enum KeychainHelper {

    private static let service = serviceName("com.daypage.auth")
    private static let apiKeyService = serviceName("com.daypage.apikeys")

    /// Simulator signing may not enforce separate access groups. Dedicated QA
    /// apps therefore use distinct service names before any test can delete a
    /// familiar credential name. Normal app and macOS package behavior is unchanged.
    private static func serviceName(_ name: String) -> String {
        #if DEBUG && os(iOS)
        if let identity = Bundle.main.bundleIdentifier,
           identity == "com.daypage.app.qa-unit" || identity == "com.daypage.app.qa-ui" {
            return "\(identity).\(name)"
        }
        #endif
        return name
    }

    // MARK: - API Key Storage (US-002)

    /// Stores an API key securely in Keychain under the `com.daypage.apikeys` service.
    public static func setAPIKey(_ value: String, for identifier: String) {
        write(value, service: apiKeyService, account: identifier)
    }

    /// Update in place so an unsuccessful replacement cannot delete the old value.
    private static func write(_ value: String, service: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updated: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(base as CFDictionary, updated as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var attrs = base
        attrs[kSecValueData as String] = Data(value.utf8)
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

    /// Clear legacy defaults only once a Keychain value can be read back.
    /// Failed writes keep the legacy value for the next retry.
    public static func migrateAPIKeysFromUserDefaultsIfNeeded() {
        migrateAPIKeysFromUserDefaultsIfNeeded(
            defaults: .standard, read: getAPIKey(for:), write: setAPIKey(_:for:)
        )
    }

    static func migrateAPIKeysFromUserDefaultsIfNeeded(
        defaults: UserDefaults,
        read: (String) -> String?,
        write: (String, String) -> Void
    ) {
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
                let existing = defaults.string(forKey: udKey),
                !existing.isEmpty
            else { continue }
            // Only migrate if Keychain doesn't already have a value
            if read(keychainId) == nil {
                write(existing, keychainId)
                guard read(keychainId) == existing else { continue }
            }
            defaults.removeObject(forKey: udKey)
        }
    }

    // MARK: - Auth Token Storage

    public static func set(_ value: String, forKey key: String) {
        write(value, service: service, account: key)
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
