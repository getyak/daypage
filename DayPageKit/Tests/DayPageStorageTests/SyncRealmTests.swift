import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

/// Realm isolation regressions: origin normalization, configuration pairing,
/// token claim pre-checks, same-server user proof, account sidecar
/// compatibility (fail closed + preserve), and generation-lease linearization.
final class SyncRealmTests: XCTestCase {
    private var vault: URL!
    private var previousVault: URL?

    override func setUpWithError() throws {
        previousVault = VaultInitializer.testOverrideURL
        vault = SyncRealmTestSupport.fixtureRoot
            .appendingPathComponent("sync-realm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousVault
        try? FileManager.default.removeItem(at: vault)
    }

    // MARK: - Origin normalization

    func testOriginNormalizationIsStrict() throws {
        XCTAssertEqual(
            try SyncRealmOrigin(validating: "https://Example.COM").normalized,
            "https://example.com"
        )
        XCTAssertEqual(
            try SyncRealmOrigin(validating: "https://example.com/").normalized,
            "https://example.com"
        )
        XCTAssertEqual(
            try SyncRealmOrigin(validating: "https://example.com:443").normalized,
            "https://example.com"
        )
        XCTAssertEqual(
            try SyncRealmOrigin(validating: "https://example.com:8443").normalized,
            "https://example.com:8443"
        )
        XCTAssertEqual(
            try SyncRealmOrigin(validating: URL(string: "https://example.com")!).normalized,
            "https://example.com"
        )

        let rejected = [
            "http://example.com",
            "https://user:pass@example.com",
            "https://user@example.com",
            "https://example.com:",
            "https://example.com:abc",
            "https://example.com:99999",
            "https://example.com/path",
            "https://example.com/path/",
            "https://example.com?query=1",
            "https://example.com#fragment",
            "https://ho%6Dst.example",
            "https://",
            "example.com",
        ]
        for raw in rejected {
            XCTAssertThrowsError(
                try SyncRealmOrigin(validating: raw),
                "expected rejection for \(raw)"
            ) { error in
                guard case SyncRealmError.invalidOrigin = error else {
                    return XCTFail("unexpected error for \(raw): \(error)")
                }
            }
        }
    }

    func testRealmIdentitySeparatesOriginAndUser() throws {
        let user = UUID()
        let originA = try SyncRealmOrigin(validating: "https://a.example")
        let originB = try SyncRealmOrigin(validating: "https://b.example")
        let sameUserOtherOrigin = SyncRealmIdentity(origin: originB, userID: user)
        let otherUserSameOrigin = SyncRealmIdentity(origin: originA, userID: UUID())

        XCTAssertNotEqual(SyncRealmIdentity(origin: originA, userID: user), sameUserOtherOrigin)
        XCTAssertNotEqual(SyncRealmIdentity(origin: originA, userID: user), otherUserSameOrigin)
    }

    // MARK: - Configuration pairing

    func testPartialConfigurationOverrideFailsClosed() throws {
        // Complete fallback pair.
        let selected = try SyncConfigurationPair.select(
            tiers: [],
            fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
        )
        XCTAssertEqual(selected.origin.normalized, "https://a.example")

        // First complete tier wins.
        let tiered = try SyncConfigurationPair.select(
            tiers: [
                SyncConfigurationTier(url: "https://b.example", key: "key-b"),
                SyncConfigurationTier(url: "https://c.example", key: "key-c"),
            ],
            fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
        )
        XCTAssertEqual(tiered.origin.normalized, "https://b.example")
        XCTAssertEqual(tiered.publishableKey, "key-b")

        // URL without key at one tier must NOT borrow the key from another.
        XCTAssertThrowsError(
            try SyncConfigurationPair.select(
                tiers: [SyncConfigurationTier(url: "https://b.example", key: nil)],
                fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
            )
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .partialConfigurationOverride)
        }

        // Key without URL at one tier must NOT borrow the URL from another.
        XCTAssertThrowsError(
            try SyncConfigurationPair.select(
                tiers: [SyncConfigurationTier(url: nil, key: "key-b")],
                fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
            )
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .partialConfigurationOverride)
        }

        // Mixed tiers (URL from env, key from plist) fail, never mix.
        XCTAssertThrowsError(
            try SyncConfigurationPair.select(
                tiers: [
                    SyncConfigurationTier(url: "https://b.example", key: nil),
                    SyncConfigurationTier(url: nil, key: "key-c"),
                ],
                fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
            )
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .partialConfigurationOverride)
        }

        // Empty key and non-HTTPS pairs fail closed too.
        XCTAssertThrowsError(
            try SyncConfigurationPair.select(
                tiers: [],
                fallback: SyncConfigurationTier(url: "https://a.example", key: "  ")
            )
        )
        XCTAssertThrowsError(
            try SyncConfigurationPair.select(
                tiers: [],
                fallback: SyncConfigurationTier(url: "http://a.example", key: "key-a")
            )
        )
    }

    // MARK: - Token claims and server user proof

    private func syntheticToken(
        issuer: String,
        subject: String,
        role: String = "authenticated",
        expiresAt: Date = Date(timeIntervalSinceNow: 3_600)
    ) throws -> String {
        func base64URL(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try base64URL(["alg": "HS256", "typ": "JWT"])
        let payload = try base64URL([
            "iss": issuer,
            "sub": subject,
            "role": role,
            "exp": expiresAt.timeIntervalSince1970,
        ])
        return "\(header).\(payload).c2lnbmF0dXJl"
    }

    func testTokenClaimMismatchIsRejectedBeforeAnyRequest() async throws {
        let user = UUID()
        let origin = "https://a.example"
        let identity = try SyncRealmIdentity(originURL: XCTUnwrap(URL(string: origin)), userID: user)
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: origin)),
            publishableKey: "key-a"
        )
        let recorder = RecordingTransport()
        let valid = try syntheticToken(
            issuer: "\(origin)/auth/v1",
            subject: user.uuidString.lowercased()
        )

        // Wrong issuer (foreign realm) — no request may be sent.
        let foreignIssuer = try syntheticToken(
            issuer: "https://b.example/auth/v1",
            subject: user.uuidString.lowercased()
        )
        await assertVerificationFails(
            token: foreignIssuer,
            configuration: configuration,
            transport: recorder,
            expectedUserID: user
        )
        // Wrong subject — no request may be sent.
        let foreignSubject = try syntheticToken(
            issuer: "\(origin)/auth/v1",
            subject: UUID().uuidString.lowercased()
        )
        await assertVerificationFails(
            token: foreignSubject,
            configuration: configuration,
            transport: recorder,
            expectedUserID: user
        )
        // Wrong role.
        let wrongRole = try syntheticToken(
            issuer: "\(origin)/auth/v1",
            subject: user.uuidString.lowercased(),
            role: "anon"
        )
        await assertVerificationFails(
            token: wrongRole,
            configuration: configuration,
            transport: recorder,
            expectedUserID: user
        )
        // Expired.
        let expired = try syntheticToken(
            issuer: "\(origin)/auth/v1",
            subject: user.uuidString.lowercased(),
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        await assertVerificationFails(
            token: expired,
            configuration: configuration,
            transport: recorder,
            expectedUserID: user
        )
        let callsBefore = await recorder.calls.count
        XCTAssertEqual(callsBefore, 0)

        // Server proof mismatch: claims pass, but /auth/v1/user names another
        // user. Decoded claims alone are never authentication proof.
        recorder.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let body = try JSONSerialization.data(
                withJSONObject: ["id": UUID().uuidString.lowercased()]
            )
            return (body, response)
        }
        do {
            _ = try await SyncSessionVerifier.verifiedSession(
                configuration: configuration,
                accessToken: valid,
                transport: recorder,
                expectedUserID: user
            )
            XCTFail("expected server user mismatch")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .serverUserMismatch)
        }
        // Exactly one same-origin proof request, and nothing else.
        let callsAfter = await recorder.calls.count
        XCTAssertEqual(callsAfter, 1)
        let recordedCalls = await recorder.calls
        let first = try XCTUnwrap(recordedCalls.first)
        XCTAssertEqual(first, "\(origin)/auth/v1/user")

        // Happy path installs one consistent context.
        recorder.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let body = try JSONSerialization.data(
                withJSONObject: ["id": user.uuidString.lowercased()]
            )
            return (body, response)
        }
        let session = try await SyncSessionVerifier.verifiedSession(
            configuration: configuration,
            accessToken: valid,
            transport: recorder,
            expectedUserID: user
        )
        XCTAssertEqual(session.identity.userID, user)
        XCTAssertEqual(session.identity.normalizedOrigin, origin)
        XCTAssertEqual(session.context.serverVerifiedUserID, user)
    }

    private func assertVerificationFails(
        token: String,
        configuration: SyncBackendConfiguration,
        transport: RecordingTransport,
        expectedUserID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await SyncSessionVerifier.verifiedSession(
                configuration: configuration,
                accessToken: token,
                transport: transport,
                expectedUserID: expectedUserID
            )
            XCTFail("expected verification failure", file: file, line: line)
        } catch {
            // Bounded errors only.
            switch error {
            case SyncRealmError.sessionTokenInvalid, SyncRealmError.serverUserMismatch:
                break
            default:
                XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - Account sidecar compatibility (fail closed + preserve)

    private var accountStateURL: URL { SyncAccountStateStore.stateURL }

    private func realm(_ origin: String, _ user: UUID) throws -> SyncRealmIdentity {
        try SyncRealmIdentity(
            originURL: XCTUnwrap(URL(string: origin)),
            userID: user
        )
    }

    func testSchemaV1AccountStateFailsClosedAndIsPreserved() throws {
        let user = UUID()
        let legacy = """
        {"pull_cursor":7,"schema_version":1,"user_id":"\(user.uuidString.lowercased())"}
        """
        try FileManager.default.createDirectory(
            at: accountStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: accountStateURL)

        let identity = try realm("https://a.example", user)
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity)) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .legacyRealmUnverified)
        }
        XCTAssertThrowsError(try SyncAccountStateStore.pullCursor(for: identity))
        XCTAssertThrowsError(try SyncAccountStateStore.advancePullCursor(to: 99, for: identity))
        XCTAssertThrowsError(try SyncAccountStateStore.boundRealm())

        // Bytes untouched: no clearing, reset or migration.
        XCTAssertEqual(try Data(contentsOf: accountStateURL), Data(legacy.utf8))
    }

    func testCorruptAccountStateFailsClosedAndIsPreserved() throws {
        let corrupt = Data("{not json".utf8)
        try FileManager.default.createDirectory(
            at: accountStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try corrupt.write(to: accountStateURL)

        let identity = try realm("https://a.example", UUID())
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity)) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .invalidState)
        }
        XCTAssertEqual(try Data(contentsOf: accountStateURL), corrupt)
        XCTAssertFalse(SyncAccountStateStore.isUnclaimedVault())
    }

    func testUnknownLegacyTransferObligationsBlockFirstBindAndArePreserved() throws {
        let sidecar = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyState = """
        {"records":[{"id":"upload:legacy"}],"schema_version":1}
        """
        try Data(legacyState.utf8).write(to: sidecar)

        let identity = try realm("https://a.example", UUID())
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity)) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .legacyRealmUnverified)
        }
        XCTAssertFalse(SyncAccountStateStore.isUnclaimedVault())
        XCTAssertEqual(try Data(contentsOf: sidecar), Data(legacyState.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountStateURL.path))
    }

    func testPartialDownloadFilesBlockFirstBind() throws {
        let downloads = SyncTransferSidecarBinding.partialDownloadsDirectory(vaultRoot: vault)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("partial".utf8).write(
            to: downloads.appendingPathComponent("legacy.partial")
        )

        let identity = try realm("https://a.example", UUID())
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity)) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .legacyRealmUnverified)
        }
    }

    func testGenuineFirstBindPreservesOfflineOutboxAndRestoresCursor() throws {
        // Offline capture before any account exists: a true first claim may
        // bind WITHOUT losing queued notes.
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        let memo = Memo(body: "offline queued note")
        try SyncOutboxStore.recordUpsert(
            memo,
            vaultPath: "raw/2026-10-01.md",
            vaultRoot: vault
        )
        let outboxBefore = try Data(contentsOf: SyncOutboxStore.outboxURL(for: vault))
        let user = UUID()
        let identity = try realm("https://a.example", user)

        XCTAssertEqual(try SyncAccountStateStore.bind(to: identity), 0)
        XCTAssertEqual(try SyncAccountStateStore.boundRealm(), identity)
        // Outbox bytes untouched by binding.
        XCTAssertEqual(try Data(contentsOf: SyncOutboxStore.outboxURL(for: vault)), outboxBefore)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)

        // Monotonic cursor: restart restores, a delayed page cannot rewind.
        try SyncAccountStateStore.advancePullCursor(to: 42, for: identity)
        XCTAssertEqual(try SyncAccountStateStore.bind(to: identity), 42)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: identity), 42)
        try SyncAccountStateStore.advancePullCursor(to: 12, for: identity)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: identity), 42)
    }

    func testRealmMismatchHoldsAccountCursorAndState() throws {
        let user = UUID()
        let identityA = try realm("https://a.example", user)
        XCTAssertEqual(try SyncAccountStateStore.bind(to: identityA), 0)
        try SyncAccountStateStore.advancePullCursor(to: 5, for: identityA)
        let stateBefore = try Data(contentsOf: accountStateURL)

        // Same UUID, different origin.
        let identityB = try realm("https://b.example", user)
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identityB)) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .originMismatch(
                expected: "https://a.example",
                actual: "https://b.example"
            ))
        }
        XCTAssertThrowsError(try SyncAccountStateStore.pullCursor(for: identityB))
        XCTAssertThrowsError(try SyncAccountStateStore.advancePullCursor(to: 9, for: identityB))

        // Different UUID, same origin.
        let identityC = try realm("https://a.example", UUID())
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identityC)) { error in
            guard case SyncAccountStateError.accountMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try SyncAccountStateStore.pullCursor(for: identityC))

        // Nothing was rebound, rewound or rewritten.
        XCTAssertEqual(try Data(contentsOf: accountStateURL), stateBefore)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: identityA), 5)
    }

    func testInvalidationDuringProofRefusesTokenAndSkipsEffects() async throws {
        let user = UUID()
        let realm = try self.realm("https://a.example", user)
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: "key-a"
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: user,
            serverVerifiedAt: Date()
        )
        let t0 = try SyncRealmTestSupport.token(realm: realm)
        let t1 = try SyncRealmTestSupport.token(
            realm: realm,
            issuer: realm.origin.authIssuer,
            subject: user.uuidString.lowercased(),
            expiresAt: Date(timeIntervalSince1970: 4_000_000_003)
        )
        let transport = SuspendingProofTransport(userID: user)
        let lease = SyncSessionLease()
        let prover = SyncSessionTokenProver(
            context: context,
            lease: lease,
            proofTransport: transport,
            seededToken: t0,
            seededClaims: try SyncSessionTokenClaims.decode(t0)
        )

        let proof = Task {
            try await prover.verifiedToken(t1)
        }
        await transport.waitUntilEntered()
        // The session is replaced while the T1 proof is suspended.
        lease.invalidate()
        await transport.releaseAll()

        do {
            _ = try await proof.value
            XCTFail("proof finishing after invalidation must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        // No cache write happened; later use refuses without new requests.
        do {
            _ = try await prover.verifiedToken(t1)
            XCTFail("invalidated prover must refuse")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    func testAllComponentsShareOneTokenProofCache() throws {
        // The uploader, puller and downloader consume ONE session-scoped
        // exact-token prover, so a successful proof is reused across push,
        // pull and media paths for the same live token.
        let realm = try self.realm("https://a.example", UUID())
        let session = try SyncRealmTestSupport.session(realm: realm)
        let recorder = RecordingTransport()
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: recorder,
            fileTransport: recorder,
            accessTokenProvider: { "" }
        )
        let puller = SupabaseSyncPuller(
            session: session,
            transport: recorder,
            fileTransport: recorder,
            accessTokenProvider: { "" }
        )
        let downloader = SupabaseAttachmentDownloader(
            session: session,
            fileTransport: recorder
        )
        XCTAssertTrue(uploader.session.tokens === puller.session.tokens)
        XCTAssertTrue(puller.session.tokens === downloader.session.tokens)
        XCTAssertTrue(uploader.session.lease === downloader.session.lease)
    }

    // MARK: - Transfer sidecar structural/schema hardening

    private func writeTransferSidecar(_ json: String) throws {
        let url = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: url)
    }

    private func assertUnprovenAndPreserved(
        _ name: String,
        json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try writeTransferSidecar(json)
        let before = try Data(contentsOf: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault))
        let identity = try realm("https://a.example", UUID())
        let verdict = SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)
        XCTAssertEqual(verdict, .unproven, name, file: file, line: line)
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity), name) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .legacyRealmUnverified, file: file, line: line)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: accountStateURL.path),
            name,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try Data(contentsOf: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)),
            before,
            name,
            file: file,
            line: line
        )
        XCTAssertFalse(SyncAccountStateStore.isUnclaimedVault(), name, file: file, line: line)
    }

    func testUnknownOrCorruptTransferShapesAreHeldNotClaimable() throws {
        // Unknown schema with mistyped records: never downgraded to empty.
        try assertUnprovenAndPreserved(
            "unknown-schema-wrong-records",
            json: #"{"schema_version":99,"records":{"opaque":1}}"#
        )
        try FileManager.default.removeItem(
            at: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        )

        // Valid realm header + corrupt records: corruption wins over header.
        let user = UUID()
        let realm = try self.realm("https://a.example", user)
        try assertUnprovenAndPreserved(
            "valid-header-corrupt-records",
            json: #"{"schema_version":1,"records":"opaque","realm_origin":"\#(realm.normalizedOrigin)","realm_user_id":"\#(realm.userID.uuidString.lowercased())"}"#
        )
        try FileManager.default.removeItem(
            at: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        )

        // Partial (one-sided) realm header is corruption, not absence.
        try assertUnprovenAndPreserved(
            "partial-header",
            json: #"{"schema_version":1,"records":[],"realm_origin":"https://a.example"}"#
        )
        try FileManager.default.removeItem(
            at: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        )

        // Malformed header values are corruption too.
        try assertUnprovenAndPreserved(
            "malformed-header",
            json: #"{"schema_version":1,"records":[],"realm_origin":"not a url","realm_user_id":"not-a-uuid"}"#
        )
        try FileManager.default.removeItem(
            at: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        )

        // Records array with elements missing required fields.
        try assertUnprovenAndPreserved(
            "record-missing-fields",
            json: #"{"schema_version":1,"records":[{"id":"upload:x"}],"blocked_records":[]}"#
        )
        try FileManager.default.removeItem(
            at: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        )

        // Blocked records mistyped.
        try assertUnprovenAndPreserved(
            "blocked-mistyped",
            json: #"{"schema_version":1,"records":[],"blocked_records":"nope"}"#
        )
        try FileManager.default.removeItem(
            at: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        )

        // Missing `records` key entirely is an unknown shape.
        try assertUnprovenAndPreserved(
            "records-missing",
            json: #"{"schema_version":1}"#
        )
    }

    func testInvalidPartialDirectoryIsUnreadableNotAbsent() throws {
        // A regular FILE where the downloads directory belongs cannot be
        // enumerated: absence must never be inferred from unreadability.
        let downloads = SyncTransferSidecarBinding.partialDownloadsDirectory(vaultRoot: vault)
        try FileManager.default.createDirectory(
            at: downloads.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("synthetic".utf8).write(to: downloads)

        let identity = try realm("https://a.example", UUID())
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .unproven
        )
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity)) { error in
            XCTAssertEqual(error as? SyncAccountStateError, .legacyRealmUnverified)
        }
        XCTAssertEqual(try Data(contentsOf: downloads), Data("synthetic".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountStateURL.path))
    }

    func testNonRegularPartialEntriesCountAsHeldState() throws {
        let downloads = SyncTransferSidecarBinding.partialDownloadsDirectory(vaultRoot: vault)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        // A dangling symlink inside downloads/ is held state, not absence.
        try FileManager.default.createSymbolicLink(
            at: downloads.appendingPathComponent("dangling"),
            withDestinationURL: URL(fileURLWithPath: "/nonexistent/elsewhere")
        )
        let identity = try realm("https://a.example", UUID())
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .unproven
        )
        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: identity))
    }

    func testValidEmptySidecarStillAllowsClaimAndSameRealmRestart() throws {
        // Genuine no-obligation state stays claimable, and a proven header
        // keeps working without any rewrite.
        let user = UUID()
        let identity = try realm("https://a.example", user)
        try writeTransferSidecar(#"{"blocked_records":[],"records":[],"schema_version":1}"#)
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .claimable
        )
        XCTAssertEqual(try SyncAccountStateStore.bind(to: identity), 0)

        // After the first claim the store writes its own state; the transfer
        // sidecar can later be claimed by the same realm.
        let memo = Memo(body: "claim-restart")
        _ = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memo.id,
            descriptors: [],
            realm: identity
        )
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .proven
        )
        XCTAssertThrowsError(
            try AttachmentTransferStore.pendingDownloads(
                realm: try self.realm("https://a.example", UUID())
            )
        )
    }

    // MARK: - Exact-token proof (NATIVE-TOKEN-001)

    func testEveryNewTokenNeedsFreshServerProofBeforeEffects() async throws {
        let user = UUID()
        let realm = try self.realm("https://a.example", user)
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: "key-a"
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: user,
            serverVerifiedAt: Date()
        )
        let t0 = try SyncRealmTestSupport.token(realm: realm)
        let t1 = try SyncRealmTestSupport.token(
            realm: realm,
            issuer: realm.origin.authIssuer,
            subject: user.uuidString.lowercased(),
            expiresAt: Date(timeIntervalSince1970: 4_000_000_001)
        )
        XCTAssertNotEqual(t0, t1)

        let recorder = RecordingTransport()
        var serverUser = user.uuidString.lowercased()
        recorder.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let body = try JSONSerialization.data(withJSONObject: ["id": serverUser])
            return (body, response)
        }
        let lease = SyncSessionLease()
        let prover = SyncSessionTokenProver(
            context: context,
            lease: lease,
            proofTransport: recorder,
            seededToken: t0,
            seededClaims: try SyncSessionTokenClaims.decode(t0)
        )

        // The exact seeded token reuses its proof without another request.
        _ = try await prover.verifiedToken(t0)
        var calls = await recorder.calls
        XCTAssertEqual(calls.count, 0)

        // A NEW token value needs a fresh same-origin proof that fails here:
        // the token is refused and no proof is cached.
        serverUser = UUID().uuidString.lowercased()
        do {
            _ = try await prover.verifiedToken(t1)
            XCTFail("unproven token must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .serverUserMismatch)
        }
        calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)

        // A successful proof for T1 caches ONLY T1 (shared reuse afterwards).
        serverUser = user.uuidString.lowercased()
        _ = try await prover.verifiedToken(t1)
        _ = try await prover.verifiedToken(t1)
        calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)

        // Wrong-claim tokens never reach the network at all.
        let foreign = try SyncRealmTestSupport.token(
            realm: try self.realm("https://b.example", user)
        )
        do {
            _ = try await prover.verifiedToken(foreign)
            XCTFail("foreign-issuer token must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionTokenInvalid(.issuer))
        }
        calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)

        // After invalidation neither cache reuse nor new proof writes happen.
        lease.invalidate()
        do {
            _ = try await prover.verifiedToken(t0)
            XCTFail("invalidated lease must refuse cached token")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        do {
            _ = try await prover.verifiedToken(t1)
            XCTFail("invalidated lease must refuse re-proof")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
    }

    func testUnprovenNewTokenStopsUploaderBeforeAnyEffect() async throws {
        // T0 proven at install; the provider then returns a same-UUID T1 whose
        // server proof fails. Zero transfer writes, zero mutation requests.
        let user = UUID()
        let realm = try self.realm("https://a.example", user)
        let t0 = try SyncRealmTestSupport.token(realm: realm)
        let t1 = try SyncRealmTestSupport.token(
            realm: realm,
            issuer: realm.origin.authIssuer,
            subject: user.uuidString.lowercased(),
            expiresAt: Date(timeIntervalSince1970: 4_000_000_002)
        )
        let recorder = RecordingTransport()
        recorder.handler = { request in
            if request.url?.absoluteString.hasSuffix("/auth/v1/user") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (Data(), response)
            }
            XCTFail("no non-proof request may be sent")
            throw UnexpectedRequest()
        }
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: "key-a"
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: user,
            serverVerifiedAt: Date()
        )
        let session = SyncSession(
            context: context,
            proofTransport: recorder,
            seededToken: t0,
            seededClaims: try SyncSessionTokenClaims.decode(t0)
        )
        let uploader = SupabaseSyncUploader(
            session: session,
            transport: recorder,
            fileTransport: recorder,
            accessTokenProvider: { t1 }
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: UUID(),
            kind: .delete,
            revision: 3,
            modifiedAt: Date(),
            contentHash: nil,
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: 0
        )
        do {
            _ = try await uploader.upload(operation: operation)
            XCTFail("unproven refreshed token must stop the mutation")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .serverUserUnverified(status: 401))
        }
        // The only request ever sent is the failed same-origin user proof; no
        // transfer state was prepared or rewritten.
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first, "\(realm.normalizedOrigin)/auth/v1/user")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AttachmentTransferStore.stateURL.path)
        )
    }

    // MARK: - Valid sidecar positives (schema-1 compatibility)

    func testValidEmptySchema1SidecarIsClaimableAndProvable() throws {
        let user = UUID()
        let identity = try realm("https://a.example", user)

        // Empty schema-1 document without a header: genuine claimable state
        // (JSON `1` is an integer here, never rejected via Bool bridging).
        let empty = #"{"records":[],"schema_version":1}"#
        try writeTransferSidecar(empty)
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .claimable
        )
        XCTAssertEqual(try SyncAccountStateStore.bind(to: identity), 0)
        // Binding never touches the transfer sidecar bytes.
        XCTAssertEqual(
            try Data(contentsOf: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)),
            Data(empty.utf8)
        )

        // Empty schema-1 document WITH a matching header is proven; the same
        // realm restarts cleanly and a foreign realm is never rebound.
        let headerDoc = #"{"realm_origin":"https://a.example","realm_user_id":"\#(user.uuidString.lowercased())","records":[],"schema_version":1}"#
        try writeTransferSidecar(headerDoc)
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .proven
        )
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: identity), 0)
        XCTAssertThrowsError(
            try AttachmentTransferStore.pendingDownloads(
                realm: try self.realm("https://a.example", UUID())
            )
        ) { error in
            XCTAssertEqual(error as? SyncRealmError, .realmMismatch)
        }
    }

    func testStoreEncodedTransferStateIsProvenForSameRealm() throws {
        // Real AttachmentTransferStore-encoded legal state, then same-realm
        // restart and first account claim over the proven sidecar.
        let user = UUID()
        let identity = try self.realm("https://a.example", user)
        let memoID = UUID()
        let digest = String(repeating: "d", count: 64)
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest,
            sizeBytes: 8,
            mimeType: "image/png",
            objectKey: "\(user.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(digest).png",
            originalFilename: "legal.png"
        )
        _ = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID,
            descriptors: [descriptor],
            realm: identity
        )
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .proven
        )
        // Same-realm restart keeps working and keeps the header binding.
        let items = try AttachmentTransferStore.pendingDownloads(realm: identity)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity),
            .proven
        )
        // A genuine first claim is allowed over the proven sidecar.
        XCTAssertEqual(try SyncAccountStateStore.bind(to: identity), 0)
        XCTAssertEqual(try SyncAccountStateStore.boundRealm(), identity)
    }

    func testTypedRecordCorruptionStaysUnprovenUnderMatchingHeader() throws {
        let user = UUID()
        let identity = try realm("https://a.example", user)
        let goodRecord =
            #"{"direction":"upload","id":"upload:x","local_path":"raw/assets/x.png","memo_id":"\#(UUID().uuidString.lowercased())","descriptor":{"content_sha256":"\#(String(repeating: "a", count: 64))","kind":"photo","mime_type":"image/png","object_key":"\#(user.uuidString.lowercased())/\#(UUID().uuidString.lowercased())/\#(String(repeating: "a", count: 64)).png","original_filename":"x.png","position":0,"size_bytes":8},"status":"pending","upload_offset":0,"updated_at":"2026-10-01T00:00:00Z"}"#
        let header = #""realm_origin":"https://a.example","realm_user_id":"\#(user.uuidString.lowercased())",""#

        func doc(_ records: String) -> String {
            #"{\#(header)\#(records),"schema_version":1}"#
        }

        // A matching header must NEVER outrank corrupt record values.
        try assertUnprovenAndPreserved(
            "null-record-fields",
            json: doc(#"records:[{"direction":null,"id":null,"local_path":null,"memo_id":null,"descriptor":null,"status":null,"upload_offset":null,"updated_at":null}]"#)
        )
        try assertUnprovenAndPreserved(
            "wrong-uuid",
            json: doc(#"records:[{"direction":"upload","id":"upload:x","local_path":"raw/assets/x.png","memo_id":"not-a-uuid","descriptor":{"content_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","kind":"photo","mime_type":"image/png","object_key":"k","original_filename":"x.png","position":0,"size_bytes":8},"status":"pending","upload_offset":0,"updated_at":"2026-10-01T00:00:00Z"}]"#)
        )
        try assertUnprovenAndPreserved(
            "bad-enum",
            json: doc(#"records:[{"direction":"sideways","id":"upload:x","local_path":"raw/assets/x.png","memo_id":"\#(UUID().uuidString.lowercased())","descriptor":{"content_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","kind":"photo","mime_type":"image/png","object_key":"k","original_filename":"x.png","position":0,"size_bytes":8},"status":"pending","upload_offset":0,"updated_at":"2026-10-01T00:00:00Z"}]"#)
        )
        try assertUnprovenAndPreserved(
            "bad-date",
            json: doc(#"records:[{"direction":"upload","id":"upload:x","local_path":"raw/assets/x.png","memo_id":"\#(UUID().uuidString.lowercased())","descriptor":{"content_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","kind":"photo","mime_type":"image/png","object_key":"k","original_filename":"x.png","position":0,"size_bytes":8},"status":"pending","upload_offset":0,"updated_at":"not-a-date"}]"#)
        )
        try assertUnprovenAndPreserved(
            "bad-descriptor",
            json: doc(#"records:[{"direction":"upload","id":"upload:x","local_path":"raw/assets/x.png","memo_id":"\#(UUID().uuidString.lowercased())","descriptor":{"content_sha256":"zzzz","kind":"photo","mime_type":"image/png","object_key":"k","original_filename":"x.png","position":-1,"size_bytes":-8},"status":"pending","upload_offset":0,"updated_at":"2026-10-01T00:00:00Z"}]"#)
        )
        // A legal record plus ONE corrupt sibling stays unproven.
        try assertUnprovenAndPreserved(
            "one-corrupt-sibling",
            json: doc(#"records:[\#(goodRecord),{"direction":"upload","id":"bad"}]"#)
        )

        // Schema version values are strict integers: booleans, null and
        // fractions are all corruption, never "schema 1".
        for (label, schema) in [
            ("bool-true", "true"),
            ("bool-false", "false"),
            ("null-schema", "null"),
            ("fractional-schema", "1.5"),
            ("unknown-schema", "2"),
        ] {
            try assertUnprovenAndPreserved(
                label,
                json: #"{\#(header)"records":[],"schema_version":\#(schema)}"#
            )
        }

        // And the same positives stay claimable/proven after all negatives.
        let identity2 = try realm("https://a.example", UUID())
        try writeTransferSidecar(#"{"records":[],"schema_version":1}"#)
        XCTAssertEqual(
            SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity2),
            .claimable
        )
    }

    // MARK: - Exact-token singleflight (per exact value)

    func testTokenSingleflightKeepsResultsPerExactValue() async throws {
        let user = UUID()
        let realm = try self.realm("https://a.example", user)
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: "key-a"
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: user,
            serverVerifiedAt: Date()
        )
        let t1 = try SyncRealmTestSupport.token(
            realm: realm, expiresAt: Date(timeIntervalSince1970: 4_000_000_010)
        )
        let t2 = try SyncRealmTestSupport.token(
            realm: realm, expiresAt: Date(timeIntervalSince1970: 4_000_000_020)
        )
        XCTAssertNotEqual(t1, t2)

        let transport = OrderedProofTransport(userID: user)
        let prover = SyncSessionTokenProver(
            context: context,
            lease: SyncSessionLease(),
            proofTransport: transport
        )

        let taskA = Task { try await prover.verifiedToken(t1) }
        await transport.waitUntilEntered(0)
        let taskB1 = Task { try await prover.verifiedToken(t2) }
        await transport.waitUntilEntered(1)
        // Second B joins B's flight: no third request, no cross-token sharing.
        let taskB2 = Task { try await prover.verifiedToken(t2) }

        // Complete A FIRST even though B started later.
        await transport.release(0)
        let resultA = try await taskA.value
        XCTAssertEqual(resultA.value, t1)

        await transport.release(1)
        let resultB1 = try await taskB1.value
        let resultB2 = try await taskB2.value
        XCTAssertEqual(resultB1.value, t2)
        XCTAssertEqual(resultB2.value, t2)
        let requests = await transport.requests
        XCTAssertEqual(requests, 2, "one flight per exact token value")

        // Reverse completion order with an error on the later value: the
        // earlier proof stays unaffected. Both values are FRESH (uncached).
        let t3 = try SyncRealmTestSupport.token(
            realm: realm, expiresAt: Date(timeIntervalSince1970: 4_000_000_030)
        )
        let t4 = try SyncRealmTestSupport.token(
            realm: realm, expiresAt: Date(timeIntervalSince1970: 4_000_000_040)
        )
        let taskC = Task { try await prover.verifiedToken(t3) }
        await transport.waitUntilEntered(2)
        let taskD1 = Task { try await prover.verifiedToken(t4) }
        await transport.waitUntilEntered(3)
        let taskD2 = Task { try await prover.verifiedToken(t4) }
        await transport.markFailing(3)
        await transport.release(3)
        do {
            _ = try await taskD1.value
            XCTFail("failed proof must fail its waiters")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .serverUserUnverified(status: 500))
        }
        do {
            _ = try await taskD2.value
            XCTFail("failed proof must fail its waiters")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .serverUserUnverified(status: 500))
        }
        await transport.release(2)
        let resultC = try await taskC.value
        XCTAssertEqual(resultC.value, t3)
        let finalRequests = await transport.requests
        XCTAssertEqual(finalRequests, 4, "no flight bleed across distinct values")
    }

    // MARK: - Proof completion currency (clock + gate linearization)

    func testProofCompletionRefusesExpiredCandidateAtCurrentClock() async throws {
        let user = UUID()
        let realm = try self.realm("https://a.example", user)
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: "key-a"
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: user,
            serverVerifiedAt: Date()
        )
        let expiry = Date(timeIntervalSince1970: 5_000_000_100)
        let token = try SyncRealmTestSupport.token(realm: realm, expiresAt: expiry)
        let transport = OrderedProofTransport(userID: user)
        let clock = MutableClock(now: Date(timeIntervalSince1970: 5_000_000_000))
        let prover = SyncSessionTokenProver(
            context: context,
            lease: SyncSessionLease(),
            proofTransport: transport,
            clock: { clock.now }
        )

        let task = Task { try await prover.verifiedToken(token) }
        await transport.waitUntilEntered(0)
        // The proof FINISHES after the candidate already expired.
        clock.now = expiry.addingTimeInterval(1)
        await transport.release(0)

        do {
            _ = try await task.value
            XCTFail("expired candidate must not finalize a capability")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionTokenInvalid(.expired))
        }
        // No cache write happened: a later use is refused again without any
        // further request (the claim pre-check fails at the current clock).
        do {
            _ = try await prover.verifiedToken(token)
            XCTFail("still-expired candidate must be refused")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionTokenInvalid(.expired))
        }
        let requestsAfter = await transport.requests
        XCTAssertEqual(requestsAfter, 1)

        // Cached hits obey the CURRENT expiry too.
        let unexpired = try SyncRealmTestSupport.token(
            realm: realm, expiresAt: Date(timeIntervalSince1970: 5_000_000_500)
        )
        let seeded = SyncSessionTokenProver(
            context: context,
            lease: SyncSessionLease(),
            proofTransport: transport,
            seededToken: unexpired,
            seededClaims: try SyncSessionTokenClaims.decode(unexpired),
            clock: { clock.now }
        )
        _ = try await seeded.verifiedToken(unexpired)
        clock.now = Date(timeIntervalSince1970: 5_000_000_600)
        do {
            _ = try await seeded.verifiedToken(unexpired)
            XCTFail("cached token must obey current expiry")
        } catch {
            XCTAssertEqual(error as? SyncRealmError, .sessionTokenInvalid(.expired))
        }
    }

    // MARK: - Raw commit publishes notifications after both gates (R6)

    @MainActor
    func testCommittedRemoteWritePublishesAfterReleasingLease() async throws {
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        let lease = SyncSessionLease()
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        let change = SyncRemoteChange(
            id: memoID, type: "text", body: "synthetic notification ordering",
            createdAt: created, pinnedAt: nil, location: nil, weather: nil,
            device: "synthetic", source: "ios", vaultPath: nil,
            sourceModifiedAt: nil, contentHash: nil, syncRevision: 1,
            lastSyncDeviceId: nil, deletedAt: nil, changeSequence: 1
        )
        let dayKey = RawStorage.fileURL(for: created)
            .deletingPathExtension().lastPathComponent
        let published = expectation(description: "committed day notification")
        let token = NotificationCenter.default.addObserver(
            forName: .rawStorageDidWrite, object: nil, queue: .main
        ) { note in
            guard note.userInfo?[RawStorage.writtenDayStringKey] as? String == dayKey else { return }
            // A main observer can race the real sign-out/configuration path.
            // Bounded wait makes the old in-gate ordering fail instead of
            // hanging the test process: invalidate cannot finish until the
            // gate is free, and publishing must not hold the gate.
            let invalidated = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                lease.invalidate()
                invalidated.signal()
            }
            XCTAssertEqual(invalidated.wait(timeout: .now() + 1), .success)
            published.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = try await Task.detached {
            try RawStorage.applyRemoteChanges([change], sessionLease: lease)
        }.value
        await fulfillment(of: [published], timeout: 3)

        // The durable commit completed (pre-invalidation ordering), the
        // notification published after both gates were released, and the
        // invalidation linearized without deadlock.
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertFalse(lease.isValid)
        XCTAssertEqual(try RawStorage.read(for: created).first?.id, memoID)
        XCTAssertEqual(try RawStorage.read(for: created).first?.body, change.body)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }

    // MARK: - Generation lease linearization

    func testWithValidityRefusesCommitAfterInvalidation() throws {
        let lease = SyncSessionLease()
        var committed = 0
        _ = try lease.withValidity { committed += 1 }
        XCTAssertEqual(committed, 1)
        XCTAssertTrue(lease.isValid)

        lease.invalidate()
        XCTAssertFalse(lease.isValid)
        XCTAssertThrowsError(try lease.withValidity { committed += 1 }) { error in
            XCTAssertEqual(error as? SyncRealmError, .sessionInvalidated)
        }
        XCTAssertThrowsError(try lease.assertValid())
        // The refused commit performed no effect.
        XCTAssertEqual(committed, 1)
    }

    /// A commit that entered the gate BEFORE invalidation linearizes may run
    /// to completion; invalidation cannot tear it apart. Every later commit
    /// is refused.
    func testInvalidationLinearizesAgainstInFlightCommit() throws {
        let lease = SyncSessionLease()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var committedValue: Int?
        var failedCommit = false

        DispatchQueue.global().async {
            do {
                _ = try lease.withValidity {
                    entered.signal()
                    release.wait()
                    committedValue = 1
                }
            } catch {
                failedCommit = true
            }
            done.signal()
        }
        entered.wait()

        // Invalidations block on the in-flight commit (shared lock).
        let invalidated = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            lease.invalidate()
            invalidated.signal()
        }
        release.signal()
        invalidated.wait()
        done.wait()

        XCTAssertEqual(committedValue, 1)
        XCTAssertFalse(failedCommit)
        XCTAssertThrowsError(try lease.withValidity { committedValue = 2 })
        XCTAssertEqual(committedValue, 1)
    }

    func testInvalidationMidCommitStillFinishesDocumentedOrdering() throws {
        // The recursive gate models the documented ordering: a commit that
        // already entered may observe an invalidation request and still
        // finish; subsequent commits are refused.
        let lease = SyncSessionLease()
        var effects: [String] = []
        _ = try lease.withValidity {
            effects.append("before")
            lease.invalidate()
            effects.append("after")
        }
        XCTAssertEqual(effects, ["before", "after"])
        XCTAssertThrowsError(try lease.withValidity { effects.append("late") })
        XCTAssertEqual(effects, ["before", "after"])
    }
}

// MARK: - Fakes

private struct UnexpectedRequest: Error {}

/// Deterministic proof transport: each request parks on its own gate until
/// the test releases it, enabling exact interleavings.
private actor OrderedProofTransport: HTTPTransport {
    private let userID: UUID
    private var nextIndex = 0
    private var entered: [Int: CheckedContinuation<Void, Never>] = [:]
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var failing: Set<Int> = []
    private(set) var requests = 0

    init(userID: UUID) {
        self.userID = userID
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = nextIndex
        nextIndex += 1
        requests += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gates[index] = continuation
            entered[index]?.resume()
            entered[index] = nil
        }
        if failing.contains(index) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(), response)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let body = try JSONSerialization.data(
            withJSONObject: ["id": userID.uuidString.lowercased()]
        )
        return (body, response)
    }

    func waitUntilEntered(_ index: Int) async {
        if gates[index] != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entered[index] = continuation
        }
    }

    func release(_ index: Int) {
        gates[index]?.resume()
        gates[index] = nil
    }

    func markFailing(_ index: Int) {
        failing.insert(index)
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        self.value = now
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}



/// Pauses inside `/auth/v1/user` proof handling so tests can invalidate the
/// lease mid-proof deterministically.
private actor SuspendingProofTransport: HTTPTransport {
    private let userID: UUID
    private var entered: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    init(userID: UUID) {
        self.userID = userID
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if entered != nil {
                entered?.resume()
                entered = nil
                gate = continuation
            } else {
                gate = continuation
            }
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let body = try JSONSerialization.data(
            withJSONObject: ["id": userID.uuidString.lowercased()]
        )
        return (body, response)
    }

    func waitUntilEntered() async {
        if gate != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            entered = continuation
        }
    }

    func releaseAll() {
        gate?.resume()
        gate = nil
    }
}



/// Shared builders for other DayPageStorage test files (single test module).
enum SyncRealmTestSupport {
    static var fixtureRoot: URL {
        ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }

    static func realm(
        origin: String = "https://example.supabase.co",
        user: UUID = UUID()
    ) throws -> SyncRealmIdentity {
        try SyncRealmIdentity(
            originURL: XCTUnwrap(URL(string: origin)),
            userID: user
        )
    }

    /// A session whose exact-token proof cache is pre-seeded with the same
    /// deterministic token `token(realm:)` builds, so test providers that
    /// return that value never need a proof transport.
    static func session(realm: SyncRealmIdentity, key: String = "sb_test_key") throws -> SyncSession {
        let configuration = try SyncBackendConfiguration(
            url: XCTUnwrap(URL(string: realm.normalizedOrigin)),
            publishableKey: key
        )
        let context = try SyncSessionContext(
            identity: realm,
            configuration: configuration,
            serverVerifiedUserID: realm.userID,
            serverVerifiedAt: Date()
        )
        let seed = try token(realm: realm)
        return SyncSession(
            context: context,
            proofTransport: nil,
            seededToken: seed,
            seededClaims: try SyncSessionTokenClaims.decode(seed)
        )
    }

    /// Deterministic synthetic token (sorted JSON keys + fixed expiry) so
    /// repeated calls for the same realm produce the identical string.
    static func token(
        realm: SyncRealmIdentity,
        issuer: String? = nil,
        subject: String? = nil,
        role: String = "authenticated",
        expiresAt: Date = Date(timeIntervalSince1970: 4_000_000_000)
    ) throws -> String {
        func base64URL(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try base64URL(["alg": "HS256", "typ": "JWT"])
        let payload = try base64URL([
            "iss": issuer ?? realm.origin.authIssuer,
            "sub": subject ?? realm.userID.uuidString.lowercased(),
            "role": role,
            "exp": expiresAt.timeIntervalSince1970,
        ])
        return "\(header).\(payload).c2lnbmF0dXJl"
    }

    /// Typed token for direct downloader/media tests.
    static func verifiedToken(
        _ value: String,
        realm: SyncRealmIdentity
    ) throws -> SyncVerifiedAccessToken {
        let claims = try SyncSessionTokenClaims.decode(try token(realm: realm))
        return SyncVerifiedAccessToken(
            value: value,
            claims: claims
        )
    }
}

private actor RecordingTransport: HTTPTransport, AttachmentFileTransport {
    nonisolated(unsafe) var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))?
    private(set) var calls: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls.append(request.url?.absoluteString ?? "")
        guard let handler else { throw UnexpectedRequest() }
        return try handler(request)
    }

    func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        calls.append(request.url?.absoluteString ?? "")
        throw UnexpectedRequest()
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        calls.append(request.url?.absoluteString ?? "")
        throw UnexpectedRequest()
    }
}
