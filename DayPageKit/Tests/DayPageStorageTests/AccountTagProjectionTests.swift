// AccountTagProjectionTests.swift — #884 derived cache + consistency
// acceptance (T05/T06/T08/T10/T12/T13/T19/T20).
//
// All fixtures are synthetic under DAYPAGE_TEST_VAULT_ROOT (explicit vault
// roots). No real vault, network, credentials or account state.

import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

final class AccountTagProjectionTests: XCTestCase {

    private var vault: URL!
    private var realm: SyncRealmIdentity!

    override func setUpWithError() throws {
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-tag-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        realm = try SyncRealmTestSupport.realm()
    }

    override func tearDownWithError() throws {
        if let vault {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.appendingPathComponent("_agent/sync").path)
            try? FileManager.default.removeItem(at: vault)
        }
        vault = nil
        realm = nil
    }

    // MARK: - Fixture builders

    private func label(_ raw: String) -> ExactTagLabel {
        guard let value = ExactTagLabel(raw) else {
            preconditionFailure("fixture label \(raw) must validate")
        }
        return value
    }

    private func makeSnapshot(
        receiptCount: Int = 1,
        catalogue: [AccountTagCatalogueRow]? = nil,
        links: [AccountTagLinkRow]? = nil,
        markers: [AccountTagImportMarker]? = nil
    ) -> AccountTagProjectionSnapshot {
        let markerList = markers ?? (0..<receiptCount).map {
            AccountTagImportMarker(
                sourceSHA256: String(repeating: String(format: "%x", $0), count: 64),
                payloadHash: String(repeating: "a", count: 64),
                version: 1
            )
        }
        return AccountTagProjectionSnapshot(
            normalizedOrigin: realm.normalizedOrigin,
            ownerUUID: realm.userID,
            receiptCount: receiptCount,
            catalogue: catalogue ?? [AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true)],
            links: links ?? [AccountTagLinkRow(memoID: UUID(), label: label("#a"))],
            sourceMarkers: markerList,
            // Fixed timestamp so JSON cache round-trips compare exactly.
            fetchedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    private func cacheBytes() -> Data? {
        try? Data(contentsOf: AccountTagProjectionStore.cacheFileURL(vaultRoot: vault))
    }

    // MARK: - T05 marker race (count wrap, not paged-set equality)

    /// sourceB commits mid-read and sorts BEFORE an already-passed cursor, so
    /// BOTH paged marker scans only ever see sourceA — the exact-count wrap is
    /// what proves instability. Exhausted bounded retries leave the previous
    /// cache bytes untouched.
    func testCountRaceIsNeverStableAndOldCacheBytesStayUnchanged() async throws {
        let established = makeSnapshot(
            catalogue: [AccountTagCatalogueRow(label: label("#old"), inImportCatalog: true)],
            links: [AccountTagLinkRow(memoID: UUID(), label: label("#old"))]
        )
        try AccountTagProjectionStore.install(established, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        let before = try XCTUnwrap(cacheBytes())

        // Both paged scans see only sourceA, but the count moves 1 → 2 → 1 …
        let sourceA = AccountTagImportMarker(
            sourceSHA256: String(repeating: "a", count: 64),
            payloadHash: String(repeating: "b", count: 64),
            version: 1
        )
        let reader = ScriptedTagsReader(
            countScript: [1, 2, 1, 2, 1, 2],
            markerScript: [[sourceA]],
            catalogueRows: [AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true)],
            linkRows: [AccountTagLinkRow(memoID: UUID(), label: label("#a"))]
        )

        do {
            _ = try await AccountTagProjectionRefresh.fetch(
                reader: reader,
                realm: realm,
                maxAttempts: 3
            )
            XCTFail("count race must not produce a snapshot")
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, .countChanged)
        }
        XCTAssertEqual(cacheBytes(), before, "old cache bytes must be preserved")
        XCTAssertEqual(try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault).receiptCount, 1)
    }

    /// A single observed change retries boundedly and can then install the
    /// complete consistent state (eventual refresh under append-only writes).
    func testBoundedRetryInstallsCompleteConsistentState() async throws {
        let sourceA = AccountTagImportMarker(
            sourceSHA256: String(repeating: "a", count: 64),
            payloadHash: String(repeating: "b", count: 64),
            version: 1
        )
        let sourceB = AccountTagImportMarker(
            sourceSHA256: String(repeating: "a", count: 63) + "b",
            payloadHash: String(repeating: "c", count: 64),
            version: 1
        )
        let memo = UUID()
        let reader = ScriptedTagsReader(
            countScript: [1, 2, 2, 2],
            markerScript: [[sourceA], [sourceA, sourceB]],
            catalogueRows: [
                AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true),
                AccountTagCatalogueRow(label: label("#b"), inImportCatalog: true)
            ],
            linkRows: [
                AccountTagLinkRow(memoID: memo, label: label("#a")),
                AccountTagLinkRow(memoID: memo, label: label("#b"))
            ]
        )
        let snapshot = try await AccountTagProjectionRefresh.fetch(
            reader: reader,
            realm: realm,
            maxAttempts: 3
        )
        XCTAssertEqual(snapshot.receiptCount, 2)
        XCTAssertEqual(snapshot.sourceMarkers, [sourceA, sourceB])
        try AccountTagProjectionStore.install(snapshot, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        let stored = try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        XCTAssertEqual(stored.receiptCount, snapshot.receiptCount)
        XCTAssertEqual(stored.sourceMarkers, snapshot.sourceMarkers)
        XCTAssertEqual(stored.catalogue, snapshot.catalogue)
        XCTAssertEqual(stored.links, snapshot.links)
    }

    // MARK: - T06 stable refresh + complete tables

    /// countBefore == countAfter == 2, 2 markers, 1005 catalogue labels and
    /// complete links → full read installs; a tag-only import is discoverable
    /// with ZERO memo changes (nothing here reads memo feeds).
    func testStableFullReadInstallsCompleteTablesIncludingTagOnlyImport() async throws {
        var catalogue: [AccountTagCatalogueRow] = []
        var links: [AccountTagLinkRow] = []
        let memo = UUID()
        for index in 0..<1_005 {
            let exact = label(String(format: "#tag%04d", index))
            catalogue.append(AccountTagCatalogueRow(label: exact, inImportCatalog: true))
            links.append(AccountTagLinkRow(memoID: memo, label: exact))
        }
        let markers = (0..<2).map {
            AccountTagImportMarker(
                sourceSHA256: String(repeating: String(format: "%x", $0), count: 64),
                payloadHash: String(repeating: "a", count: 64),
                version: 1
            )
        }
        let reader = ScriptedTagsReader(
            countScript: [2, 2],
            markerScript: [markers],
            catalogueRows: catalogue,
            linkRows: links
        )
        let snapshot = try await AccountTagProjectionRefresh.fetch(reader: reader, realm: realm)
        XCTAssertEqual(snapshot.catalogue.count, 1_005)
        XCTAssertEqual(snapshot.links.count, 1_005)
        XCTAssertEqual(snapshot.receiptCount, 2)
        try AccountTagProjectionStore.install(snapshot, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)

        let stored = try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        XCTAssertEqual(stored.catalogue.count, 1_005)
        XCTAssertEqual(stored.links.count, 1_005)
        XCTAssertEqual(Set(stored.links.map { $0.memoID }), [memo])
    }

    // MARK: - T08 cheap periodic probe

    /// Unchanged count + markers reuse the complete matched-realm cache with
    /// NO catalogue/links re-download; a changed marker set is not fresh and
    /// a failed probe is never "fresh".
    func testCheapProbeReusesMatchedCacheWithoutFullDownload() async throws {
        let sourceA = AccountTagImportMarker(
            sourceSHA256: String(repeating: "a", count: 64),
            payloadHash: String(repeating: "b", count: 64),
            version: 1
        )
        let memo = UUID()
        let reader = ScriptedTagsReader(
            countScript: [1, 1, 1, 2],
            markerScript: [[sourceA], [sourceA], [sourceA]],
            catalogueRows: [AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true)],
            linkRows: [AccountTagLinkRow(memoID: memo, label: label("#a"))]
        )
        let snapshot = try await AccountTagProjectionRefresh.fetch(reader: reader, realm: realm)
        try AccountTagProjectionStore.install(snapshot, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        let catalogueCallsAfterFull = reader.catalogueCalls
        let linkCallsAfterFull = reader.linkCalls

        // Unchanged probe → fresh, without touching the full tables again.
        let fresh = try await AccountTagProjectionRefresh.isCacheFresh(
            reader: reader,
            cached: snapshot
        )
        XCTAssertTrue(fresh)
        XCTAssertEqual(reader.catalogueCalls, catalogueCallsAfterFull)
        XCTAssertEqual(reader.linkCalls, linkCallsAfterFull)

        // Changed count → not fresh.
        let stale = try await AccountTagProjectionRefresh.isCacheFresh(
            reader: reader,
            cached: snapshot
        )
        XCTAssertFalse(stale)

        // A failing probe throws — it is never "fresh".
        reader.failCount = AccountTagFetchError.countUnavailable
        do {
            let value = try await AccountTagProjectionRefresh.isCacheFresh(
                reader: reader,
                cached: snapshot
            )
            XCTFail("failed probe must not be fresh, got \(value)")
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, .countUnavailable)
        }
    }

    // MARK: - T10 stale generation cannot install or clear the new cache

    func testInvalidLeaseOnFreshVaultCreatesNoMetadataDirectories() throws {
        let fm = FileManager.default
        let raw = vault.appendingPathComponent("raw/2026-01-01.md")
        let bytes = Data("synthetic untouched raw bytes".utf8)
        try bytes.write(to: raw)
        let before = Set((fm.enumerator(atPath: vault.path)?.allObjects as? [String]) ?? [])
        XCTAssertFalse(fm.fileExists(atPath: vault.appendingPathComponent("_agent").path))
        let invalid = SyncSessionLease()
        invalid.invalidate()
        let unexpectedUpdate = expectation(description: "invalid lease posts no tag update")
        unexpectedUpdate.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .accountTagProjectionDidUpdate, object: nil, queue: nil
        ) { _ in unexpectedUpdate.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertThrowsError(try AccountTagProjectionStore.install(
            makeSnapshot(), realm: realm, lease: invalid, vaultRoot: vault
        )) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .leaseInvalidated)
        }
        XCTAssertFalse(fm.fileExists(atPath: vault.appendingPathComponent("_agent").path))
        XCTAssertEqual(Set((fm.enumerator(atPath: vault.path)?.allObjects as? [String]) ?? []), before)
        XCTAssertEqual(try Data(contentsOf: raw), bytes)
        wait(for: [unexpectedUpdate], timeout: 0.02)
    }

    func testStaleLeaseCannotInstallOverOrClearNewCache() throws {
        let oldLease = SyncSessionLease()
        let oldSnapshot = makeSnapshot(
            receiptCount: 1,
            catalogue: [AccountTagCatalogueRow(label: label("#old"), inImportCatalog: true)],
            links: [AccountTagLinkRow(memoID: UUID(), label: label("#old"))]
        )
        try AccountTagProjectionStore.install(oldSnapshot, realm: realm, lease: oldLease, vaultRoot: vault)

        // New session generation installs its own snapshot…
        let newLease = SyncSessionLease()
        let newSnapshot = makeSnapshot(
            receiptCount: 2,
            catalogue: [
                AccountTagCatalogueRow(label: label("#new-a"), inImportCatalog: true),
                AccountTagCatalogueRow(label: label("#new-b"), inImportCatalog: true)
            ],
            links: [AccountTagLinkRow(memoID: UUID(), label: label("#new-a"))],
            markers: [
                AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 64), payloadHash: String(repeating: "a", count: 64), version: 1),
                AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 63) + "b", payloadHash: String(repeating: "a", count: 64), version: 1)
            ]
        )
        try AccountTagProjectionStore.install(newSnapshot, realm: realm, lease: newLease, vaultRoot: vault)
        let newBytes = try XCTUnwrap(cacheBytes())

        // …then the OLD generation's late response arrives.
        oldLease.invalidate()
        XCTAssertThrowsError(
            try AccountTagProjectionStore.install(oldSnapshot, realm: realm, lease: oldLease, vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .leaseInvalidated)
        }
        XCTAssertEqual(cacheBytes(), newBytes, "stale install must not touch the new cache")
        XCTAssertEqual(
            try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault).receiptCount,
            2
        )
    }

    // MARK: - T12 corrupt / foreign / stale / symlink-guarded cache

    func testForeignCorruptAndStaleCachesAreTypedUnavailableNotEmptySuccess() throws {
        let cacheURL = AccountTagProjectionStore.cacheFileURL(vaultRoot: vault)

        // Missing cache → typed missing (never empty-success).
        XCTAssertThrowsError(
            try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .missing)
        }

        let valid = makeSnapshot()
        try AccountTagProjectionStore.install(valid, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)

        // Corrupt JSON preserves bytes and reports corrupt.
        let goodBytes = try XCTUnwrap(cacheBytes())
        try Data("{not json".utf8).write(to: cacheURL)
        XCTAssertThrowsError(
            try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .corrupt)
        }

        // Same origin + foreign owner UUID → foreign.
        let foreignOwner = AccountTagProjectionSnapshot(
            normalizedOrigin: realm.normalizedOrigin,
            ownerUUID: UUID(),
            receiptCount: 1,
            catalogue: [AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true)],
            links: [AccountTagLinkRow(memoID: UUID(), label: label("#a"))],
            sourceMarkers: [AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 64), payloadHash: String(repeating: "a", count: 64), version: 1)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(foreignOwner).write(to: cacheURL)
        XCTAssertThrowsError(
            try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .foreign)
        }

        // Foreign origin + same UUID → foreign.
        var crossOrigin = valid
        crossOrigin.normalizedOrigin = "https://other.example"
        try encoder.encode(crossOrigin).write(to: cacheURL)
        XCTAssertThrowsError(
            try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .foreign)
        }

        // Unknown schema version → staleVersion.
        var future = valid
        future.schemaVersion = 2
        try encoder.encode(future).write(to: cacheURL)
        XCTAssertThrowsError(
            try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .staleVersion)
        }

        // Restore the valid cache: complete snapshot reads offline again.
        try goodBytes.write(to: cacheURL)
        let restored = try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        XCTAssertEqual(restored, valid)

        // Internally inconsistent snapshots never install.
        let dangling = makeSnapshot(
            links: [AccountTagLinkRow(memoID: UUID(), label: label("#missing"))]
        )
        XCTAssertThrowsError(
            try AccountTagProjectionStore.install(dangling, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        ) { error in
            XCTAssertEqual(error as? AccountTagCacheError, .inconsistentSnapshot)
        }
    }

    /// Metadata symlinks are REJECTED fail-closed (review P1): any symlink at
    /// `_agent`, `_agent/sync` or the cache file — a one-hop in-Vault alias
    /// that CHAINS to the outside, a dangling target or a loop included — is
    /// `foreign` on read AND install. The outside sentinel tree stays
    /// byte-identical and no cache is ever adopted or written outside.
    func testMetadataSymlinksAreRejectedFailClosed() throws {
        let fm = FileManager.default
        let outside = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("daypage-tag-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("sentinel.bin")
        try Data("outside-sentinel".utf8).write(to: sentinel)
        let outsideBefore = try Self.fingerprintTree(outside)

        let valid = makeSnapshot()
        let agent = vault.appendingPathComponent("_agent")

        func expectForeign(_ context: String) {
            XCTAssertThrowsError(
                try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault),
                context
            ) { error in
                XCTAssertEqual(error as? AccountTagCacheError, .foreign, context)
            }
            XCTAssertThrowsError(
                try AccountTagProjectionStore.install(
                    valid, realm: realm, lease: SyncSessionLease(), vaultRoot: vault
                ),
                context
            ) { error in
                XCTAssertEqual(error as? AccountTagCacheError, .foreign, context)
            }
        }

        // 1) `_agent` directly escapes the Vault.
        try fm.createSymbolicLink(at: agent, withDestinationURL: outside)
        expectForeign("direct outside link")

        // 2) One-hop in-Vault alias that CHAINS outside: `_agent -> _alias
        //    -> outside`. Accepting the first hop was the P1 hole.
        try fm.removeItem(at: agent)
        let alias = vault.appendingPathComponent("_alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
        try fm.createSymbolicLink(at: agent, withDestinationURL: alias)
        expectForeign("chained in-vault alias")

        // 3) In-Vault alias whose target holds a VALID cache — still
        //    fail-closed: derived metadata never travels through links.
        try fm.removeItem(at: agent)
        try fm.removeItem(at: alias)
        try fm.createDirectory(
            at: vault.appendingPathComponent("_plain_agent/sync"),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(valid).write(
            to: vault.appendingPathComponent("_plain_agent/sync/account-tags-v1.json")
        )
        try fm.createSymbolicLink(
            at: agent,
            withDestinationURL: vault.appendingPathComponent("_plain_agent")
        )
        expectForeign("in-vault alias with valid cache")

        // 4) Dangling target.
        try fm.removeItem(at: agent)
        try fm.createSymbolicLink(
            atPath: agent.path,
            withDestinationPath: vault.appendingPathComponent("missing-entry").path
        )
        expectForeign("dangling link")

        // 5) Self loop.
        try fm.removeItem(at: agent)
        try fm.createSymbolicLink(atPath: agent.path, withDestinationPath: agent.path)
        expectForeign("self-referential loop")

        // 6) Symlinked `sync` directory.
        try fm.removeItem(at: agent)
        try fm.createDirectory(at: agent, withIntermediateDirectories: true)
        let syncDir = agent.appendingPathComponent("sync")
        try fm.createSymbolicLink(at: syncDir, withDestinationURL: outside)
        expectForeign("symlinked sync directory")

        // 7) Symlinked cache FILE.
        try fm.removeItem(at: syncDir)
        try fm.createDirectory(at: syncDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: syncDir.appendingPathComponent("account-tags-v1.json"),
            withDestinationURL: sentinel
        )
        expectForeign("symlinked cache file")

        // No attempt adopted or wrote anything outside the Vault.
        XCTAssertEqual(try Self.fingerprintTree(outside), outsideBefore)
    }

    /// Install I/O failure preserves the old cache (T11 store half).
    func testInstallIOFailurePreservesPreviousCache() throws {
        let valid = makeSnapshot()
        try AccountTagProjectionStore.install(valid, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        let before = try XCTUnwrap(cacheBytes())

        // Make the cache directory read-only: the atomic replace must fail
        // WITHOUT touching existing bytes.
        let syncDir = AccountTagProjectionStore.cacheFileURL(vaultRoot: vault).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: syncDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: syncDir.path)
        }

        var update = valid
        update.receiptCount = 2
        update.sourceMarkers = [
            AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 64), payloadHash: String(repeating: "a", count: 64), version: 1),
            AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 63) + "b", payloadHash: String(repeating: "a", count: 64), version: 1)
        ]
        XCTAssertThrowsError(
            try AccountTagProjectionStore.install(update, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        )
        XCTAssertEqual(cacheBytes(), before)
    }

    // MARK: - T13 raw deletion / conflict copy intersection

    func testViewsIntersectMembershipWithLiveRawUUIDs() throws {
        let memoA = UUID()
        let memoB = UUID()
        let conflictCopy = UUID()
        let unused = label("#unused")
        let snapshot = AccountTagProjectionSnapshot(
            normalizedOrigin: realm.normalizedOrigin,
            ownerUUID: realm.userID,
            receiptCount: 1,
            catalogue: [
                AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true),
                AccountTagCatalogueRow(label: label("#b"), inImportCatalog: true),
                AccountTagCatalogueRow(label: unused, inImportCatalog: true)
            ],
            links: [
                AccountTagLinkRow(memoID: memoA, label: label("#a")),
                AccountTagLinkRow(memoID: memoB, label: label("#b"))
            ],
            sourceMarkers: [AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 64), payloadHash: String(repeating: "a", count: 64), version: 1)]
        )

        // Raw contains A and B.
        var live: Set<UUID> = [memoA, memoB]
        XCTAssertEqual(
            snapshot.labels(forMemoID: memoA, liveMemoIDs: live).map(\.text),
            ["#a"]
        )
        XCTAssertEqual(
            snapshot.labels(forMemoID: memoB, liveMemoIDs: live).map(\.text),
            ["#b"]
        )

        // Raw deletion removes membership immediately — the cache can NOT
        // resurrect the deleted note.
        live = [memoA]
        XCTAssertTrue(snapshot.labels(forMemoID: memoB, liveMemoIDs: live).isEmpty)
        XCTAssertEqual(snapshot.memoIDs(containing: label("#b"), liveMemoIDs: live), [])

        // Everything deleted → zero active, catalogue unused labels remain.
        live = []
        XCTAssertTrue(snapshot.activeMembershipCounts(liveMemoIDs: live).isEmpty)
        XCTAssertEqual(snapshot.allLabels.map(\.text), ["#a", "#b", "#unused"])

        // A conflict copy keeps its OWN UUID: no inherited memberships.
        live = [conflictCopy, memoA]
        XCTAssertTrue(snapshot.labels(forMemoID: conflictCopy, liveMemoIDs: live).isEmpty)

        // Active counts follow the raw intersection only.
        live = [memoA]
        XCTAssertEqual(snapshot.activeMembershipCounts(liveMemoIDs: live), [label("#a"): 1])
    }

    // MARK: - T19 refresh/filter/detail reads write ONLY the derived cache

    func testRefreshAndReadsNeverTouchRawOutboxOrAccountBytes() async throws {
        // Synthetic raw content (all fixtures synthetic).
        let rawDay = vault.appendingPathComponent("raw/2026-01-01.md")
        let rawContent = """
        ---
        id: 7E1B9A62-0000-0000-0000-000000000001
        type: text
        created: 2026-01-01T00:00:00Z
        ---

        synthetic #body-only note

        <!-- daypage-memo-separator -->
        """
        try rawContent.write(to: rawDay, atomically: true, encoding: .utf8)
        let before = try Self.fingerprintTree(vault)

        // Refresh cycle: fetch (read-only protocol) + install + reads.
        let memo = UUID()
        let reader = ScriptedTagsReader(
            countScript: [1, 1],
            markerScript: [[AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 64), payloadHash: String(repeating: "a", count: 64), version: 1)]],
            catalogueRows: [AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true)],
            linkRows: [AccountTagLinkRow(memoID: memo, label: label("#a"))]
        )
        let snapshot = try await AccountTagProjectionRefresh.fetch(reader: reader, realm: realm)
        try AccountTagProjectionStore.install(snapshot, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        _ = try AccountTagProjectionStore.read(realm: realm, vaultRoot: vault)
        _ = snapshot.labels(forMemoID: memo, liveMemoIDs: [memo])
        _ = snapshot.activeMembershipCounts(liveMemoIDs: [memo])

        // Only the reader's read calls happened — no write RPC exists on the
        // capability protocol.
        XCTAssertEqual(reader.catalogueCalls, 1)
        XCTAssertEqual(reader.linkCalls, 1)
        XCTAssertEqual(reader.markerCalls, 1)

        // The ONLY file change is the derived cache.
        let after = try Self.fingerprintTree(vault)
        let changed = Set(after.keys).symmetricDifference(Set(before.keys))
            .union(before.filter { after[$0.key] != $0.value }.keys)
        let allowed = AccountTagProjectionStore.cacheFileURL(vaultRoot: vault).path
        XCTAssertEqual(changed, [allowed], "only the derived cache may change")
        XCTAssertEqual(
            after[rawDay.path],
            before[rawDay.path],
            "raw/YAML/body bytes must never change on tag refresh"
        )
    }

    // MARK: - T20 inconsistency: no install, previous cache kept

    func testMissingCountDecreasingCountAndBadOwnerNeverInstall() async throws {
        let established = makeSnapshot()
        try AccountTagProjectionStore.install(established, realm: realm, lease: SyncSessionLease(), vaultRoot: vault)
        let before = try XCTUnwrap(cacheBytes())

        // Missing exact count.
        let missing = ScriptedTagsReader(countScript: [], markerScript: [])
        missing.failCount = AccountTagFetchError.countUnavailable
        await assertFetchFails(missing, .countUnavailable)

        // Marker rewrite / cardinality mismatch (count 2, one marker row).
        let mismatched = ScriptedTagsReader(
            countScript: [2, 2, 2, 2],
            markerScript: [[AccountTagImportMarker(sourceSHA256: String(repeating: "a", count: 64), payloadHash: String(repeating: "a", count: 64), version: 1)]],
            catalogueRows: [],
            linkRows: []
        )
        await assertFetchFails(mismatched, .markerCountMismatch)

        // Decreasing count (C0 > C1) is also a change race.
        let decreasing = ScriptedTagsReader(countScript: [2, 1, 2, 1], markerScript: [[]])
        await assertFetchFails(decreasing, .countChanged)

        // Owner mismatch rows fail the round.
        let badOwner = ScriptedTagsReader(countScript: [0, 0], markerScript: [[]])
        badOwner.failCatalogue = AccountTagFetchError.invalidRows
        await assertFetchFails(badOwner, .invalidRows)

        XCTAssertEqual(cacheBytes(), before, "no partial/empty install on any failure")
    }

    private func assertFetchFails(
        _ reader: ScriptedTagsReader,
        _ expected: AccountTagFetchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AccountTagProjectionRefresh.fetch(
                reader: reader,
                realm: realm,
                maxAttempts: 2
            )
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Tag filter resolution contract (search-side, review items 3/5)

    /// "no filter", "eligible" and "unavailable" must never collapse into
    /// each other: an active selection with unreadable metadata is fail-closed
    /// unavailable (never unfiltered results), a zero-member selection matches
    /// NOTHING (never everything), and membership intersects live raw UUIDs.
    func testTagFilterResolutionDistinguishesNoFilterEligibleAndUnavailable() throws {
        let live = UUID()
        let deleted = UUID()
        let conflictCopy = UUID()
        let snapshot = AccountTagProjectionSnapshot(
            normalizedOrigin: realm.normalizedOrigin,
            ownerUUID: realm.userID,
            receiptCount: 1,
            catalogue: [AccountTagCatalogueRow(label: label("#a"), inImportCatalog: true)],
            links: [
                AccountTagLinkRow(memoID: live, label: label("#a")),
                AccountTagLinkRow(memoID: deleted, label: label("#a"))
            ],
            sourceMarkers: [AccountTagImportMarker(
                sourceSHA256: String(repeating: "a", count: 64),
                payloadHash: String(repeating: "a", count: 64),
                version: 1
            )],
            fetchedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let selection = Set([label("#a").identity])

        // Empty selection → no tag dimension (even with unreadable metadata).
        XCTAssertEqual(
            AccountTagProjectionFilter.resolve(selection: [], liveMemoIDs: [live], snapshot: nil),
            .noTagDimension
        )
        // Active selection + unreadable metadata → FAIL CLOSED.
        XCTAssertEqual(
            AccountTagProjectionFilter.resolve(selection: selection, liveMemoIDs: [live], snapshot: nil),
            .unavailable
        )
        // Ready → live intersection only (the deleted memo is NOT in the live
        // set; the conflict copy is live but inherits nothing).
        XCTAssertEqual(
            AccountTagProjectionFilter.resolve(
                selection: selection,
                liveMemoIDs: [live, conflictCopy],
                snapshot: snapshot
            ),
            .eligible([live])
        )
        // A link row for a deleted memo never re-enters through the filter.
        XCTAssertEqual(
            AccountTagProjectionFilter.resolve(
                selection: selection,
                liveMemoIDs: [conflictCopy],
                snapshot: snapshot
            ),
            .eligible([])
        )
        // Zero live members → empty eligible set: matches none, never all.
        XCTAssertEqual(
            AccountTagProjectionFilter.resolve(selection: selection, liveMemoIDs: [], snapshot: snapshot),
            .eligible([])
        )
    }

    // MARK: - Hashing helper

    private static func fingerprintTree(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let data = try Data(contentsOf: item)
            result[item.path] = data.base64EncodedString()
        }
        return result
    }
}

// MARK: - Scripted reader

/// Deterministic scriptable `RemoteAccountTagsReader` (last script entry
/// repeats). Counts/markers dequeue per call so race windows are exact.
private final class ScriptedTagsReader: RemoteAccountTagsReader, @unchecked Sendable {
    private let lock = NSLock()
    private var countScript: [Int]
    private var markerScript: [[AccountTagImportMarker]]
    private let catalogueRows: [AccountTagCatalogueRow]
    private let linkRows: [AccountTagLinkRow]

    private(set) var countCalls = 0
    private(set) var markerCalls = 0
    private(set) var catalogueCalls = 0
    private(set) var linkCalls = 0

    var failCount: AccountTagFetchError?
    var failCatalogue: AccountTagFetchError?
    var failLinks: AccountTagFetchError?

    init(
        countScript: [Int],
        markerScript: [[AccountTagImportMarker]],
        catalogueRows: [AccountTagCatalogueRow] = [],
        linkRows: [AccountTagLinkRow] = []
    ) {
        self.countScript = countScript
        self.markerScript = markerScript
        self.catalogueRows = catalogueRows
        self.linkRows = linkRows
    }

    func exactReceiptCount() async throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        countCalls += 1
        if let failCount { throw failCount }
        guard !countScript.isEmpty else { throw AccountTagFetchError.countUnavailable }
        return countScript.removeFirst()
    }

    func importMarkers() async throws -> [AccountTagImportMarker] {
        lock.lock()
        defer { lock.unlock() }
        markerCalls += 1
        guard !markerScript.isEmpty else { return [] }
        if markerScript.count > 1 {
            return markerScript.removeFirst()
        }
        return markerScript[0]
    }

    func catalogueRows() async throws -> [AccountTagCatalogueRow] {
        lock.lock()
        defer { lock.unlock() }
        catalogueCalls += 1
        if let failCatalogue { throw failCatalogue }
        return catalogueRows
    }

    func linkRows() async throws -> [AccountTagLinkRow] {
        lock.lock()
        defer { lock.unlock() }
        linkCalls += 1
        if let failLinks { throw failLinks }
        return linkRows
    }
}
