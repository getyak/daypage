import Foundation
import XCTest
@testable import DayPageStorage

final class KeychainMigrationTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "daypage.keychain-migration-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testFailedWriteKeepsLegacyValueForRetry() throws {
        try withDefaults { defaults in
            defaults.set("synthetic-legacy-key", forKey: "runtimeDeepSeekKey")
            var writes = 0
            KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded(
                defaults: defaults, read: { _ in nil }, write: { _, _ in writes += 1 }
            )
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(defaults.string(forKey: "runtimeDeepSeekKey"), "synthetic-legacy-key")
        }
    }

    func testSuccessfulMigrationClearsLegacyOnlyAfterReadbackAndIsIdempotent() throws {
        try withDefaults { defaults in
            defaults.set("synthetic-legacy-key", forKey: "runtimeDeepSeekKey")
            var keychain: [String: String] = [:]
            var writes = 0
            for _ in 0..<2 {
                KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded(
                    defaults: defaults, read: { keychain[$0] },
                    write: { value, key in keychain[key] = value; writes += 1 }
                )
            }
            XCTAssertEqual(keychain["deepSeekApiKey"], "synthetic-legacy-key")
            XCTAssertNil(defaults.string(forKey: "runtimeDeepSeekKey"))
            XCTAssertEqual(writes, 1)
        }
    }

    func testExistingKeychainValueWinsWithoutWrite() throws {
        try withDefaults { defaults in
            defaults.set("synthetic-legacy-key", forKey: "runtimeDeepSeekKey")
            KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded(
                defaults: defaults,
                read: { $0 == "deepSeekApiKey" ? "synthetic-current-key" : nil },
                write: { _, _ in XCTFail("Migration must not overwrite an existing credential") }
            )
            XCTAssertNil(defaults.string(forKey: "runtimeDeepSeekKey"))
        }
    }
}
