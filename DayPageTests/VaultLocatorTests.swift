import XCTest
@testable import DayPage

/// Unit tests for VaultLocator protocol, LocalVaultLocator, iCloudVaultLocator,
/// and VaultInitializer.testOverrideURL — covering the acceptance criteria in issue #107.
final class VaultLocatorTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("VaultLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = nil
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - LocalVaultLocator

    func testLocalVaultLocator_isNotUsingiCloud() {
        let locator = LocalVaultLocator()
        XCTAssertFalse(locator.isUsingiCloud, "LocalVaultLocator must never report iCloud usage")
    }

    func testLocalVaultLocator_vaultURLEndsWithVault() {
        let locator = LocalVaultLocator()
        XCTAssertEqual(locator.vaultURL.lastPathComponent, "vault",
                       "LocalVaultLocator.vaultURL must end in 'vault'")
    }

    func testLocalVaultLocator_vaultURLIsInDocumentsDirectory() {
        let locator = LocalVaultLocator()
        let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertTrue(
            locator.vaultURL.path.hasPrefix(documentsDir.path),
            "LocalVaultLocator.vaultURL must be inside the app Documents directory"
        )
    }

    func testLocalVaultLocator_returnsConsistentURL() {
        // Multiple calls must return the same path (cached static let).
        let locator = LocalVaultLocator()
        let first = locator.vaultURL
        let second = locator.vaultURL
        XCTAssertEqual(first, second, "LocalVaultLocator.vaultURL must be stable across calls")
    }

    // MARK: - iCloudVaultLocator

    func testICloudVaultLocator_vaultURLContainsVaultComponent() {
        let locator = iCloudVaultLocator()
        // In the Simulator without an iCloud account the ubiquity container URL is nil,
        // so iCloudVaultLocator falls back to LocalVaultLocator.vaultURL.
        // Either way, the returned path must end with "vault".
        XCTAssertEqual(locator.vaultURL.lastPathComponent, "vault",
                       "iCloudVaultLocator.vaultURL must end in 'vault' (local fallback or iCloud path)")
    }

    func testICloudVaultLocator_isUsingiCloud_matchesContainerAvailability() {
        let locator = iCloudVaultLocator()
        let containerAvailable = fm.url(forUbiquityContainerIdentifier: locator.containerID) != nil
        XCTAssertEqual(
            locator.isUsingiCloud, containerAvailable,
            "isUsingiCloud must reflect whether the ubiquity container URL is non-nil"
        )
    }

    // MARK: - VaultInitializer.testOverrideURL

    func testOverrideURL_nil_returnsDelegateVaultURL() {
        VaultInitializer.testOverrideURL = nil
        let expected = VaultInitializer.shared.vaultURL
        XCTAssertEqual(VaultInitializer.vaultURL, expected,
                       "When testOverrideURL is nil, vaultURL must match shared.vaultURL")
    }

    func testOverrideURL_set_takesHighestPriority() {
        let fakeVault = tempDir.appendingPathComponent("fake-vault")
        VaultInitializer.testOverrideURL = fakeVault
        XCTAssertEqual(VaultInitializer.vaultURL, fakeVault,
                       "testOverrideURL must override shared.vaultURL when set")
    }

    func testOverrideURL_cleared_resumesDelegateURL() {
        let fakeVault = tempDir.appendingPathComponent("fake-vault")
        VaultInitializer.testOverrideURL = fakeVault
        XCTAssertEqual(VaultInitializer.vaultURL, fakeVault)

        VaultInitializer.testOverrideURL = nil
        let expected = VaultInitializer.shared.vaultURL
        XCTAssertEqual(VaultInitializer.vaultURL, expected,
                       "After clearing testOverrideURL, vaultURL must revert to shared.vaultURL")
    }

    func testOverrideURL_doesNotMutateShared() {
        let before = VaultInitializer.shared.vaultURL
        let fakeVault = tempDir.appendingPathComponent("fake-vault")
        VaultInitializer.testOverrideURL = fakeVault
        let after = VaultInitializer.shared.vaultURL
        XCTAssertEqual(before, after,
                       "testOverrideURL must not mutate VaultInitializer.shared")
    }
}
