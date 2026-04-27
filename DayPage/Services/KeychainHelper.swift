import Foundation
import Security

/// `AuthService` 使用的最小化 Keychain 包装器，用于持久化
/// 如果存储在 `UserDefaults` 中会泄露 PII 的标识符
/// （例如 Apple 登录邮箱，Apple 仅首次登录时返回）。
/// 访问类为 `AfterFirstUnlockThisDeviceOnly`，
/// 以便后台刷新任务仍能读取值而无需 iCloud 同步。
enum KeychainHelper {

    private static let service = "com.daypage.auth"

    static func set(_ value: String, forKey key: String) {
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

    static func get(forKey key: String) -> String? {
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

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
