import Foundation
import Testing
import DayPageStorage
@testable import DayPageServices

/// Issue #922 — regression tests for the fail-closed "Clear local data" policy.
///
/// The danger action must NEVER delete an iCloud or noncanonical active vault,
/// and must NEVER run with an authenticated cloud account. When blocked, the
/// mutation must not run at all: vault, keys, and preferences are preserved by
/// construction, and no other directory is ever deleted as a substitute.
@Suite("Local data reset fail-closed policy (issue #922)")
struct LocalDataResetPolicyTests {

    // MARK: Fixtures

    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDataResetPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeContext(
        active: URL,
        canonical: URL,
        iCloudLocator: Bool = false,
        vaultLocation: VaultLocation = .local,
        authenticated: Bool = false
    ) -> LocalDataResetPolicy.Context {
        LocalDataResetPolicy.Context(
            activeVaultURL: active,
            canonicalLocalVaultURL: canonical,
            locatorKind: iCloudLocator ? .iCloud : .local,
            vaultLocationPreference: vaultLocation,
            hasAuthenticatedCloudAccount: authenticated
        )
    }

    // MARK: Allowed

    @MainActor
    @Test("A locator change after validation cannot redirect the deletion")
    func deletionUsesTheValidatedURL() throws {
        let local = try makeScratchDir()
        let cloud = try makeScratchDir()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: cloud)
        }
        let localFile = local.appendingPathComponent("local.md")
        let cloudFile = cloud.appendingPathComponent("cloud.md")
        try Data("local".utf8).write(to: localFile)
        try Data("cloud must survive".utf8).write(to: cloudFile)
        var liveURL = local
        let decision = LocalDataResetPolicy.performIfAllowed(
            contextProvider: {
                let captured = self.makeContext(active: liveURL, canonical: local)
                liveURL = cloud // The next locator lookup would return iCloud.
                return captured
            },
            mutation: { verifiedURL in
                #expect(verifiedURL.standardizedFileURL == local.standardizedFileURL.resolvingSymlinksInPath())
                try? FileManager.default.removeItem(at: verifiedURL)
            }
        )
        #expect(decision == .allowed)
        #expect(liveURL == cloud)
        #expect(!FileManager.default.fileExists(atPath: localFile.path))
        #expect(try Data(contentsOf: cloudFile) == Data("cloud must survive".utf8))
    }

    @Test("Canonical local vault with no iCloud and no account is allowed")
    func canonicalLocalVaultIsAllowed() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }
        let decision = LocalDataResetPolicy.evaluate(
            makeContext(active: vault, canonical: vault)
        )
        #expect(decision == .allowed)
        #expect(decision.isAllowed)
        #expect(decision.blockReason == nil)
    }

    @Test("A symlinked path to the canonical vault still compares equal")
    func symlinkedCanonicalPathIsAllowed() throws {
        let realVault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: realVault) }
        let linkParent = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: linkParent) }
        let link = linkParent.appendingPathComponent("vault-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realVault)

        // `/var/...` vs `/private/var/...` style aliasing must not fake a
        // mismatch (or a match) — the policy compares standardized, resolved paths.
        let decision = LocalDataResetPolicy.evaluate(
            makeContext(active: link, canonical: realVault)
        )
        #expect(decision == .allowed)
    }

    // MARK: iCloud blocks

    @Test("iCloud locator blocks even when the resolved URL equals the canonical local URL")
    func iCloudFallbackToLocalPathIsBlocked() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }
        // iCloudVaultLocator falls back to the local path while the ubiquity
        // container is unavailable — the wipe must still be refused.
        let decision = LocalDataResetPolicy.evaluate(
            makeContext(active: vault, canonical: vault, iCloudLocator: true)
        )
        #expect(decision == .blocked(.iCloudVault))
    }

    @Test("An unknown locator cannot authorize deletion even at a matching path")
    func unknownLocatorIsBlocked() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }
        var context = makeContext(active: vault, canonical: vault)
        context.locatorKind = .unknown
        #expect(LocalDataResetPolicy.evaluate(context) == .blocked(.nonCanonicalVault))
    }

    @Test("iCloud vault location preference blocks a local-path fallback")
    func iCloudPreferenceIsBlocked() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }
        let decision = LocalDataResetPolicy.evaluate(
            makeContext(active: vault, canonical: vault, vaultLocation: .iCloud)
        )
        #expect(decision == .blocked(.iCloudVault))
    }

    // MARK: Noncanonical vault blocks — no substituted deletion

    @MainActor
    @Test("A noncanonical active vault blocks and deletes neither vault")
    func noncanonicalActiveVaultIsBlocked() throws {
        let activeVault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: activeVault) }
        let canonicalVault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: canonicalVault) }

        let activeFile = activeVault.appendingPathComponent("raw-precious.md")
        let canonicalFile = canonicalVault.appendingPathComponent("raw-precious.md")
        try Data("precious".utf8).write(to: activeFile)
        try Data("precious".utf8).write(to: canonicalFile)

        var mutationRan = false
        let decision = LocalDataResetPolicy.performIfAllowed(
            contextProvider: {
                self.makeContext(active: activeVault, canonical: canonicalVault)
            },
            mutation: { _ in
                mutationRan = true
                try? FileManager.default.removeItem(at: activeVault)
                try? FileManager.default.removeItem(at: canonicalVault)
            }
        )

        #expect(decision == .blocked(.nonCanonicalVault))
        #expect(!mutationRan)
        // The policy must not substitute deletion of ANY directory.
        #expect(FileManager.default.fileExists(atPath: activeFile.path))
        #expect(FileManager.default.fileExists(atPath: canonicalFile.path))
    }

    // MARK: Authenticated account blocks — state preserved

    @MainActor
    @Test("An authenticated cloud account blocks and preserves vault, keys and preferences")
    func authenticatedAccountIsBlockedAndStatePreserved() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }

        let suite = "LocalDataResetPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preference-stays", forKey: "themeMode")

        var mutationRan = false
        let decision = LocalDataResetPolicy.performIfAllowed(
            contextProvider: {
                self.makeContext(active: vault, canonical: vault, authenticated: true)
            },
            mutation: { _ in
                mutationRan = true
                try? FileManager.default.removeItem(at: vault)
                defaults.removeObject(forKey: "themeMode")
            }
        )

        #expect(decision == .blocked(.authenticatedCloudAccount))
        #expect(!mutationRan)
        #expect(FileManager.default.fileExists(atPath: vault.path))
        #expect(defaults.string(forKey: "themeMode") == "preference-stays")
    }

    // MARK: Fail closed on unresolved state

    @Test("Non-file or empty vault URLs fail closed")
    func unresolvedVaultURLsFailClosed() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }

        let nonFile = URL(string: "https://example.invalid/vault") ?? vault
        #expect(LocalDataResetPolicy.evaluate(
            makeContext(active: nonFile, canonical: vault)
        ) == .blocked(.unresolvedVault))
        #expect(LocalDataResetPolicy.evaluate(
            makeContext(active: vault, canonical: nonFile)
        ) == .blocked(.unresolvedVault))

        let root = URL(fileURLWithPath: "/")
        #expect(LocalDataResetPolicy.evaluate(
            makeContext(active: root, canonical: root)
        ) == .blocked(.unresolvedVault))
    }

    // MARK: View-state race cannot bypass

    @MainActor
    @Test("A stale enabled button state cannot bypass the mutation-time recheck")
    func staleEnabledStateCannotBypass() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }

        // View draws while everything looks safe…
        let viewState = makeContext(active: vault, canonical: vault)
        #expect(LocalDataResetPolicy.evaluate(viewState).isAllowed)

        // …then the account signs in before the confirmation dialog resolves.
        var mutationRan = false
        let decision = LocalDataResetPolicy.performIfAllowed(
            contextProvider: {
                self.makeContext(active: vault, canonical: vault, authenticated: true)
            },
            mutation: { _ in mutationRan = true }
        )

        #expect(decision == .blocked(.authenticatedCloudAccount))
        #expect(!mutationRan)
        #expect(FileManager.default.fileExists(atPath: vault.path))
    }

    @MainActor
    @Test("Mutation runs exactly once against fresh state when allowed")
    func mutationRunsWhenAllowed() throws {
        let vault = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: vault) }

        var providerCalls = 0
        var mutationRuns = 0
        let decision = LocalDataResetPolicy.performIfAllowed(
            contextProvider: {
                providerCalls += 1
                return self.makeContext(active: vault, canonical: vault)
            },
            mutation: { _ in mutationRuns += 1 }
        )

        #expect(decision == .allowed)
        #expect(providerCalls == 1)
        #expect(mutationRuns == 1)
    }
}
