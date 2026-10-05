import Foundation
import XCTest
@testable import DayPageStorage

final class VaultResolutionConcurrencyTests: XCTestCase {
    private struct FixedLocator: VaultLocator {
        let vaultURL: URL
        var isUsingiCloud: Bool { false }
    }

    func testConcurrentLocatorAndOverrideChangesKeepCompleteURLSnapshots() {
        let previousLocator = VaultInitializer.shared
        let previousOverride = VaultInitializer.testOverrideURL
        defer {
            VaultInitializer.shared = previousLocator
            VaultInitializer.testOverrideURL = previousOverride
        }

        let roots = (0..<8).map {
            URL(fileURLWithPath: "/vault-resolution-fixture/\($0)/" + String(repeating: "segment", count: 20))
        }
        let allowed = Set(roots)
        VaultInitializer.shared = FixedLocator(vaultURL: roots[0])
        VaultInitializer.testOverrideURL = nil
        let failureLock = NSLock()
        var invalidSnapshots = 0

        DispatchQueue.concurrentPerform(iterations: 20_000) { index in
            switch index % 4 {
            case 0:
                VaultInitializer.shared = FixedLocator(vaultURL: roots[index % roots.count])
            case 1:
                VaultInitializer.testOverrideURL = roots[index % roots.count]
            case 2:
                VaultInitializer.testOverrideURL = nil
            default:
                if !allowed.contains(VaultInitializer.vaultURL) {
                    failureLock.lock()
                    invalidSnapshots += 1
                    failureLock.unlock()
                }
            }
        }
        XCTAssertEqual(invalidSnapshots, 0)
    }

    func testLocatorCanReadOverrideWithoutHoldingTheStateLock() {
        struct ReentrantLocator: VaultLocator {
            let fallback: URL
            var vaultURL: URL { VaultInitializer.testOverrideURL ?? fallback }
            var isUsingiCloud: Bool { false }
        }
        let previousLocator = VaultInitializer.shared
        let previousOverride = VaultInitializer.testOverrideURL
        defer {
            VaultInitializer.shared = previousLocator
            VaultInitializer.testOverrideURL = previousOverride
        }
        let root = URL(fileURLWithPath: "/vault-resolution-reentrant-fixture")
        VaultInitializer.testOverrideURL = nil
        VaultInitializer.shared = ReentrantLocator(fallback: root)
        XCTAssertEqual(VaultInitializer.vaultURL, root)
    }
}
