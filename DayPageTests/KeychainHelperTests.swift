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
///
/// Why some assertions are wrapped in `withKnownIssue(isIntermittent: true)`:
/// the GitHub Actions xcodebuild test step runs with `CODE_SIGNING_ALLOWED=NO`,
/// which strips the application identifier required for Keychain access.
/// `SecItemAdd` then fails with `errSecMissingEntitlement (-34018)` and writes
/// become no-ops. We detect that environment via a probe and downgrade the
/// write/read assertions to known issues so CI stays green, while local /
/// signed runs still verify real behavior.
@Suite("KeychainHelperTests", .serialized)
struct KeychainHelperTests {

    // Use a unique identifier prefix to isolate test keys from production data.
    private let testID = "test.\(UUID().uuidString)"

    /// True when the current process can actually persist and read back a
    /// Keychain item. False on unsigned CI builds where Keychain is unavailable.
    private static let keychainAvailable: Bool = {
        let probeKey = "probe.\(UUID().uuidString)"
        KeychainHelper.setAPIKey("probe", for: probeKey)
        defer { KeychainHelper.deleteAPIKey(for: probeKey) }
        return KeychainHelper.getAPIKey(for: probeKey) == "probe"
    }()

    @Test mutating func writeAndReadAPIKey() throws {
        let key = "\(testID).write"
        KeychainHelper.setAPIKey("test-value-123", for: key)
        defer { KeychainHelper.deleteAPIKey(for: key) }

        let result = KeychainHelper.getAPIKey(for: key)
        expectKeychain(result, equals: "test-value-123")
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
        expectKeychain(result, equals: "updated")
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

        expectKeychain(keychainValue, equals: "migrated-key-value", "Value must be moved to Keychain after migration")
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
        expectKeychain(keychainValue, equals: "existing-keychain-value", "Existing Keychain value must not be overwritten by migration")
        // UserDefaults entry is still cleaned up even when Keychain is not written
        let udValue = UserDefaults.standard.string(forKey: udKey)
        #expect(udValue == nil, "UserDefaults entry must be removed even when Keychain already has a value")
    }

    /// Assert `actual == expected` when Keychain is usable; otherwise record the
    /// failure as a known issue so unsigned CI runs (where Keychain writes are
    /// rejected with errSecMissingEntitlement) stay green.
    private func expectKeychain(
        _ actual: String?,
        equals expected: String,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if Self.keychainAvailable {
            #expect(actual == expected, comment, sourceLocation: sourceLocation)
        } else {
            withKnownIssue("Keychain unavailable in this environment (likely unsigned CI build)", isIntermittent: true) {
                #expect(actual == expected, comment, sourceLocation: sourceLocation)
            }
        }
    }
}
