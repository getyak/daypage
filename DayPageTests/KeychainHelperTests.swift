import Testing
import Foundation
@testable import DayPage

/// Unit tests for KeychainHelper API-key storage — write/read/delete cycle
/// and UserDefaults migration. Acceptance criteria for US-002.
///
/// `.serialized`: the two migration tests below exercise
/// `migrateAPIKeysFromUserDefaultsIfNeeded()`, which hard-codes the real key
/// pair ("runtimeDeepSeekKey" → "deepSeekApiKey"). They therefore share one
/// fixed Keychain/UserDefaults slot and cannot run in parallel without one
/// test's seeded value leaking into the other. Serializing the whole suite
/// keeps them deterministic.
@Suite("KeychainHelperTests", .serialized)
struct KeychainHelperTests {

    // Use a unique identifier prefix to isolate test keys from production data.
    private let testID = "test.\(UUID().uuidString)"

    @Test mutating func writeAndReadAPIKey() throws {
        let key = "\(testID).write"
        KeychainHelper.setAPIKey("test-value-123", for: key)
        defer { KeychainHelper.deleteAPIKey(for: key) }

        let result = KeychainHelper.getAPIKey(for: key)
        #expect(result == "test-value-123")
    }

    @Test mutating func deleteAPIKey_returnsNilAfterDeletion() throws {
        let key = "\(testID).delete"
        KeychainHelper.setAPIKey("to-be-deleted", for: key)
        KeychainHelper.deleteAPIKey(for: key)

        let result = KeychainHelper.getAPIKey(for: key)
        #expect(result == nil)
    }

    @Test mutating func overwriteAPIKey_returnsNewValue() throws {
        let key = "\(testID).overwrite"
        KeychainHelper.setAPIKey("original", for: key)
        defer { KeychainHelper.deleteAPIKey(for: key) }

        KeychainHelper.setAPIKey("updated", for: key)
        let result = KeychainHelper.getAPIKey(for: key)
        #expect(result == "updated")
    }

    @Test func getMissingKey_returnsNil() {
        let result = KeychainHelper.getAPIKey(for: "nonexistent.\(UUID().uuidString)")
        #expect(result == nil)
    }

    @Test mutating func emptyStringIsStoredButTreatedAsNil() throws {
        // setAPIKey with empty string should store it; getAPIKey returns nil for empty
        // (matches the `!value.isEmpty` guard in getAPIKey).
        let key = "\(testID).empty"
        KeychainHelper.setAPIKey("", for: key)
        defer { KeychainHelper.deleteAPIKey(for: key) }

        let result = KeychainHelper.getAPIKey(for: key)
        #expect(result == nil, "Empty string stored in Keychain should be returned as nil by getAPIKey")
    }

    @Test mutating func migrateFromUserDefaults_movesValueToKeychain() throws {
        let udKey = "runtimeDeepSeekKey"
        let keychainID = "deepSeekApiKey"

        // Seed UserDefaults and ensure Keychain is clean
        KeychainHelper.deleteAPIKey(for: keychainID)
        UserDefaults.standard.set("migrated-key-value", forKey: udKey)
        defer {
            UserDefaults.standard.removeObject(forKey: udKey)
            KeychainHelper.deleteAPIKey(for: keychainID)
        }

        KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded()

        let keychainValue = KeychainHelper.getAPIKey(for: keychainID)
        let udValue = UserDefaults.standard.string(forKey: udKey)

        #expect(keychainValue == "migrated-key-value", "Value must be moved to Keychain after migration")
        #expect(udValue == nil, "UserDefaults entry must be removed after migration")
    }

    @Test mutating func migrateFromUserDefaults_doesNotOverwriteExistingKeychainValue() throws {
        let udKey = "runtimeDeepSeekKey"
        let keychainID = "deepSeekApiKey"

        // Pre-seed Keychain with a value
        KeychainHelper.setAPIKey("existing-keychain-value", for: keychainID)
        UserDefaults.standard.set("ud-value", forKey: udKey)
        defer {
            UserDefaults.standard.removeObject(forKey: udKey)
            KeychainHelper.deleteAPIKey(for: keychainID)
        }

        KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded()

        let keychainValue = KeychainHelper.getAPIKey(for: keychainID)
        #expect(keychainValue == "existing-keychain-value", "Existing Keychain value must not be overwritten by migration")
        // UserDefaults entry is still cleaned up even when Keychain is not written
        let udValue = UserDefaults.standard.string(forKey: udKey)
        #expect(udValue == nil, "UserDefaults entry must be removed even when Keychain already has a value")
    }
}
