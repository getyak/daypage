import Foundation
import Security

/// Device-only credentials, scoped to an explicitly configured service origin.
public enum KeychainSecretStore {
  private static let service = "com.daypage.local-ai"
  public struct Failure: LocalizedError {
    let status: OSStatus
    public var errorDescription: String? {
      "The device could not access the saved AI key. Unlock the device and try again."
    }
  }
  private static func query(origin: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: origin,
      kSecAttrSynchronizable as String: false,
    ]
  }
  public static func read(origin: String) throws -> String {
    var request = query(origin: origin)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw Failure(status: status) }
    return value
  }
  public static func save(_ value: String, origin: String) throws {
    let match = query(origin: origin)
    if value.isEmpty {
      let status = SecItemDelete(match as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw Failure(status: status)
      }
      return
    }
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = match
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw Failure(status: added) }
    } else if status != errSecSuccess {
      throw Failure(status: status)
    }
  }
}
