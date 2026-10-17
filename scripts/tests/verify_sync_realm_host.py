#!/usr/bin/env python3
"""Verify native sync realm isolation with a focused Foundation host harness.

Compiles and executes a host harness against the ACTUAL sources:

  - DayPageKit/Sources/DayPageStorage/SyncRealm.swift
  - DayPageKit/Sources/DayPageStorage/SyncAccountStateStore.swift
  - DayPageKit/Sources/DayPageStorage/HTTPTransport.swift (interface needed by
    the same-server user proof)

plus a minimal `VaultInitializer` test adapter (the production initializer
pulls in DayPageModels and iCloud locators that are out of scope here). There
is NO mirrored model or guard implementation and no fake implementation
assertions: every check executes the real normalization, sidecar compatibility,
cursor and generation-lease code. Real networking is denied by construction —
the harness never touches URLSession; the one network-facing entry point
(`SyncSessionVerifier`) runs against an injected fake transport.

Coverage: origin normalization, configuration pair selection, JWT claim
pre-checks, same-server `/auth/v1/user` proof, account/legacy/preservation and
cursor behavior, and generation-lease linearization (including the documented
pre-invalidation commit ordering).

All fixtures and the harness binary live under the registered artifact root
passed via --artifact-root. Each run removes its disposable fixture/build
children afterwards and retains aggregate evidence (results + source SHA-256
hashes + swiftc -frontend -parse syntax-only receipts for changed Apple files).
The parse step is explicitly NOT a full app/Xcode/SwiftPM build.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

BASE_COMMIT = "56736224e7f493d58739a29ba1fad8367bf643b0"

REPO_RELATIVE_SOURCES = [
    "DayPageKit/Sources/DayPageStorage/SyncRealm.swift",
    "DayPageKit/Sources/DayPageStorage/SyncAccountStateStore.swift",
    "DayPageKit/Sources/DayPageStorage/HTTPTransport.swift",
]

VAULT_ADAPTER = '''\
// Minimal VaultInitializer test adapter for the host harness.
//
// The production VaultInitializer.swift is intentionally not compiled here:
// it pulls in DayPageModels, iCloud ubiquity locators and app sandbox paths
// that are outside this bounded batch. SyncAccountStateStore only reads
// `VaultInitializer.vaultURL`, which this adapter resolves to the per-run
// fixture root provided by the verification script. Nothing else is modeled.
import Foundation

public enum VaultInitializer {
    public static var testOverrideURL: URL?

    public static var vaultURL: URL {
        if let override = testOverrideURL { return override }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("daypage-harness-unset-vault", isDirectory: true)
    }
}
'''

HARNESS_MAIN = r'''
// Foundation host harness — executes the ACTUAL SyncRealm.swift and
// SyncAccountStateStore.swift sources compiled into this binary. Fixtures are
// created under DAYPAGE_HARNESS_FIXTURE_ROOT (registered artifact root).
import Foundation

// MARK: - Minimal check runner

struct HarnessFailure: Error {}

final class Harness {
    static var results: [(name: String, ok: Bool, detail: String)] = []

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok, detail))
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " :: \(detail)")")
    }

    static func checkThrows<T>(
        _ name: String,
        _ body: () throws -> T,
        matches: (Error) -> Bool = { _ in true }
    ) {
        do {
            _ = try body()
            check(name, false, "expected an error, none thrown")
        } catch {
            check(name, matches(error), "got \(error)")
        }
    }
}

// MARK: - Fake transport (real networking is never used)

struct UnexpectedHarnessRequest: Error {}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse) = { _ in
        throw UnexpectedHarnessRequest()
    }) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        recorded.append(request.url?.absoluteString ?? "")
        let handler = self.handler
        lock.unlock()
        return try handler(request)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Fixture helpers

// Assigned from DAYPAGE_HARNESS_FIXTURE_ROOT in the entry point below.
var fixtureRootPath: String = ""

func freshFixtureVault(_ label: String) -> URL {
    let root = URL(fileURLWithPath: fixtureRootPath, isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    VaultInitializer.testOverrideURL = root
    return root
}

func write(_ text: String, to url: URL) {
    writeData(Data(text.utf8), to: url)
}

func writeData(_ data: Data, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try! data.write(to: url)
}

func readBytes(_ url: URL) -> Data {
    (try? Data(contentsOf: url)) ?? Data()
}

func realm(_ origin: String, _ user: UUID) -> SyncRealmIdentity {
    try! SyncRealmIdentity(originURL: URL(string: origin)!, userID: user)
}

func token(
    issuer: String,
    subject: String,
    role: String = "authenticated",
    expiresAt: Date = Date(timeIntervalSinceNow: 3_600)
) throws -> String {
    func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = try encode(["alg": "HS256", "typ": "JWT"])
    let payload = try encode([
        "iss": issuer,
        "sub": subject,
        "role": role,
        "exp": expiresAt.timeIntervalSince1970,
    ])
    return "\(header).\(payload).c2lnbmF0dXJl"
}

// MARK: - 1. Origin normalization

func runOriginNormalization() {
    let valid: [(String, String)] = [
        ("https://Example.COM", "https://example.com"),
        ("https://example.com/", "https://example.com"),
        ("https://example.com:443", "https://example.com"),
        ("https://example.com:8443", "https://example.com:8443"),
    ]
    for (raw, expected) in valid {
        do {
            let origin = try SyncRealmOrigin(validating: raw)
            Harness.check("origin.accept \(raw)", origin.normalized == expected, "got \(origin.normalized)")
        } catch {
            Harness.check("origin.accept \(raw)", false, "unexpected \(error)")
        }
    }

    let rejected = [
        "http://example.com",
        "https://user:pass@example.com",
        "https://user@example.com",
        "https://example.com:",
        "https://example.com:abc",
        "https://example.com:99999",
        "https://example.com/path",
        "https://example.com?query=1",
        "https://example.com#frag",
        "https://ho%6Dst.example",
        "https://",
        "example.com",
    ]
    for raw in rejected {
        Harness.checkThrows("origin.reject \(raw)") {
            try SyncRealmOrigin(validating: raw)
        } matches: { error in
            if case SyncRealmError.invalidOrigin = error { return true }
            return false
        }
    }

    let origin = try! SyncRealmOrigin(validating: "https://a.example")
    Harness.check("origin.matchesRoot resource path", origin.matchesRoot(URL(string: "https://a.example/storage/v1/x")!))
    Harness.check("origin.matchesRoot rejects foreign", !origin.matchesRoot(URL(string: "https://a.example.evil.test/x")!))
    Harness.check("origin.matchesRoot rejects port drift", !origin.matchesRoot(URL(string: "https://a.example:8443/x")!))
}

// MARK: - 2. Configuration pair selection

func runConfigurationPair() {
    do {
        let selected = try SyncConfigurationPair.select(
            tiers: [SyncConfigurationTier(url: "https://b.example", key: "key-b")],
            fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
        )
        Harness.check("config.completeTierWins", selected.origin.normalized == "https://b.example" && selected.publishableKey == "key-b")
    } catch {
        Harness.check("config.completeTierWins", false, "unexpected \(error)")
    }

    Harness.checkThrows("config.urlOnlyOverride") {
        try SyncConfigurationPair.select(
            tiers: [SyncConfigurationTier(url: "https://b.example", key: nil)],
            fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
        )
    } matches: { $0 as? SyncRealmError == .partialConfigurationOverride }

    Harness.checkThrows("config.keyOnlyOverride") {
        try SyncConfigurationPair.select(
            tiers: [SyncConfigurationTier(url: nil, key: "key-b")],
            fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
        )
    } matches: { $0 as? SyncRealmError == .partialConfigurationOverride }

    Harness.checkThrows("config.mixedTiers") {
        try SyncConfigurationPair.select(
            tiers: [
                SyncConfigurationTier(url: "https://b.example", key: nil),
                SyncConfigurationTier(url: nil, key: "key-c"),
            ],
            fallback: SyncConfigurationTier(url: "https://a.example", key: "key-a")
        )
    } matches: { $0 as? SyncRealmError == .partialConfigurationOverride }
}

// MARK: - 3. Token claims + same-server user proof (fake transport)

func runTokenAndServerProof() async {
    let user = UUID()
    let origin = "https://a.example"
    let identity = realm(origin, user)
    let configuration = try! SyncBackendConfiguration(
        url: URL(string: origin)!,
        publishableKey: "key-a"
    )

    let foreignIssuer = try! token(issuer: "https://b.example/auth/v1", subject: user.uuidString.lowercased())
    let recorder = FakeTransport()
    do {
        _ = try await SyncSessionVerifier.verifiedSession(
            configuration: configuration,
            accessToken: foreignIssuer,
            transport: recorder,
            expectedUserID: user
        )
        Harness.check("token.foreignIssuerRejected", false, "verification unexpectedly passed")
    } catch {
        Harness.check("token.foreignIssuerRejected", error as? SyncRealmError == .sessionTokenInvalid(.issuer), "got \(error)")
    }
    Harness.check("token.foreignIssuerSendsZeroRequests", recorder.calls.isEmpty)

    let foreignSubject = try! token(issuer: "\(origin)/auth/v1", subject: UUID().uuidString.lowercased())
    Harness.checkThrows("token.foreignSubjectRejected") {
        try SyncSessionTokenClaims.decode(foreignSubject).verify(for: identity)
    } matches: { $0 as? SyncRealmError == .sessionTokenInvalid(.subject) }

    let wrongRole = try! token(issuer: "\(origin)/auth/v1", subject: user.uuidString.lowercased(), role: "anon")
    Harness.checkThrows("token.wrongRoleRejected") {
        try SyncSessionTokenClaims.decode(wrongRole).verify(for: identity)
    } matches: { $0 as? SyncRealmError == .sessionTokenInvalid(.role) }

    let expired = try! token(
        issuer: "\(origin)/auth/v1",
        subject: user.uuidString.lowercased(),
        expiresAt: Date(timeIntervalSinceNow: -30)
    )
    Harness.checkThrows("token.expiredRejected") {
        try SyncSessionTokenClaims.decode(expired).verify(for: identity)
    } matches: { $0 as? SyncRealmError == .sessionTokenInvalid(.expired) }

    // Decoded claims are NOT auth proof: the server names another user.
    let valid = try! token(issuer: "\(origin)/auth/v1", subject: user.uuidString.lowercased())
    let mismatchRecorder = FakeTransport { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let body = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString.lowercased()])
        return (body, response)
    }
    do {
        _ = try await SyncSessionVerifier.verifiedSession(
            configuration: configuration,
            accessToken: valid,
            transport: mismatchRecorder,
            expectedUserID: user
        )
        Harness.check("proof.serverUserMismatch", false, "verification unexpectedly passed")
    } catch {
        Harness.check("proof.serverUserMismatch", error as? SyncRealmError == .serverUserMismatch, "got \(error)")
    }
    Harness.check("proof.exactlyOneSameOriginRequest", mismatchRecorder.calls == ["\(origin)/auth/v1/user"])

    // Happy path installs one consistent context.
    let happyRecorder = FakeTransport { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let body = try JSONSerialization.data(withJSONObject: ["id": user.uuidString.lowercased()])
        return (body, response)
    }
    do {
        let session = try await SyncSessionVerifier.verifiedSession(
            configuration: configuration,
            accessToken: valid,
            transport: happyRecorder,
            expectedUserID: user
        )
        Harness.check(
            "proof.happyPathContext",
            session.identity == identity
                && session.context.serverVerifiedUserID == user
                && session.identity.normalizedOrigin == origin
        )
    } catch {
        Harness.check("proof.happyPathContext", false, "unexpected \(error)")
    }
}

// MARK: - 4. Account sidecar compatibility / preservation / cursor

func runAccountSidecar() {
    let userA = UUID()
    let userB = UUID()

    // 4a. Schema-v1 (no origin) fails closed and preserves bytes.
    do {
        _ = freshFixtureVault("account-v1")
        let legacy = "{\"pull_cursor\":7,\"schema_version\":1,\"user_id\":\"\(userA.uuidString.lowercased())\"}"
        write(legacy, to: SyncAccountStateStore.stateURL)
        let identity = realm("https://a.example", userA)
        Harness.checkThrows("account.v1BindFailsClosed") {
            try SyncAccountStateStore.bind(to: identity)
        } matches: { $0 as? SyncAccountStateError == .legacyRealmUnverified }
        Harness.checkThrows("account.v1CursorReadFailsClosed") {
            try SyncAccountStateStore.pullCursor(for: identity)
        }
        Harness.checkThrows("account.v1CursorAdvanceFailsClosed") {
            try SyncAccountStateStore.advancePullCursor(to: 99, for: identity)
        }
        Harness.check("account.v1BytesPreserved", readBytes(SyncAccountStateStore.stateURL) == Data(legacy.utf8))
        Harness.check("account.v1NotUnclaimed", !SyncAccountStateStore.isUnclaimedVault())
    }

    // 4b. Corrupt state fails closed and preserves bytes.
    do {
        _ = freshFixtureVault("account-corrupt")
        let corrupt = Data("{not json".utf8)
        write("{not json", to: SyncAccountStateStore.stateURL)
        let identity = realm("https://a.example", userA)
        Harness.checkThrows("account.corruptBindFailsClosed") {
            try SyncAccountStateStore.bind(to: identity)
        } matches: { $0 as? SyncAccountStateError == .invalidState }
        Harness.check("account.corruptBytesPreserved", readBytes(SyncAccountStateStore.stateURL) == corrupt)
    }

    // 4c. Unproven legacy cloud obligations block a first claim; nothing is
    //     cleared or migrated.
    do {
        let vault = freshFixtureVault("account-legacy-transfers")
        let legacyState = "{\"records\":[{\"id\":\"upload:legacy\"}],\"schema_version\":1}"
        write(legacyState, to: SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault))
        let identity = realm("https://a.example", userA)
        Harness.checkThrows("account.unknownTransfersBlockFirstBind") {
            try SyncAccountStateStore.bind(to: identity)
        } matches: { $0 as? SyncAccountStateError == .legacyRealmUnverified }
        Harness.check(
            "account.unknownTransfersPreserved",
            readBytes(SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)) == Data(legacyState.utf8)
        )
        Harness.check("account.unknownTransfersNoAccountFile", !FileManager.default.fileExists(atPath: SyncAccountStateStore.stateURL.path))
    }

    // 4d. Partial download files are cloud obligations too.
    do {
        let vault = freshFixtureVault("account-partials")
        let partial = SyncTransferSidecarBinding.partialDownloadsDirectory(vaultRoot: vault)
            .appendingPathComponent("legacy.partial")
        write("partial", to: partial)
        Harness.checkThrows("account.partialFilesBlockFirstBind") {
            try SyncAccountStateStore.bind(to: realm("https://a.example", userA))
        } matches: { $0 as? SyncAccountStateError == .legacyRealmUnverified }
        Harness.check("account.partialFilesPreserved", FileManager.default.fileExists(atPath: partial.path))
    }

    // 4d2. Probe-parity hardening: unknown schema, valid header + corrupt
    //      records, and an invalid partial directory must all fail closed
    //      with the original bytes preserved (independent parent probe).
    do {
        let vault = freshFixtureVault("account-probe-unknown-schema")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        let original = try! JSONSerialization.data(withJSONObject: [
            "schema_version": 99,
            "records": ["opaque": 1],
        ])
        writeData(original, to: transfer)
        let identity = realm("https://a.example", userA)
        Harness.check(
            "probe.unknownSchemaVerdict",
            String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)) == "unproven"
        )
        Harness.checkThrows("probe.unknownSchemaBindRejected") {
            try SyncAccountStateStore.bind(to: identity)
        } matches: { $0 as? SyncAccountStateError == .legacyRealmUnverified }
        Harness.check(
            "probe.unknownSchemaNoBinding",
            !FileManager.default.fileExists(atPath: SyncAccountStateStore.stateURL.path)
        )
        Harness.check("probe.unknownSchemaBytesPreserved", readBytes(transfer) == original)
    }
    do {
        let vault = freshFixtureVault("account-probe-header-corrupt")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        let original = try! JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "records": "opaque",
            "realm_origin": "https://a.example",
            "realm_user_id": userA.uuidString.lowercased(),
        ])
        writeData(original, to: transfer)
        let identity = realm("https://a.example", userA)
        Harness.check(
            "probe.headerCorruptRecordsVerdict",
            String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)) == "unproven"
        )
        Harness.checkThrows("probe.headerCorruptRecordsBindRejected") {
            try SyncAccountStateStore.bind(to: identity)
        } matches: { $0 as? SyncAccountStateError == .legacyRealmUnverified }
        Harness.check(
            "probe.headerCorruptRecordsNoBinding",
            !FileManager.default.fileExists(atPath: SyncAccountStateStore.stateURL.path)
        )
        Harness.check("probe.headerCorruptRecordsBytesPreserved", readBytes(transfer) == original)
    }
    do {
        let vault = freshFixtureVault("account-probe-partial-dir")
        let downloads = SyncTransferSidecarBinding.partialDownloadsDirectory(vaultRoot: vault)
        try! FileManager.default.createDirectory(
            at: downloads.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! Data("synthetic".utf8).write(to: downloads)
        let identity = realm("https://a.example", userA)
        Harness.check(
            "probe.invalidPartialDirVerdict",
            String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)) == "unproven"
        )
        Harness.checkThrows("probe.invalidPartialDirBindRejected") {
            try SyncAccountStateStore.bind(to: identity)
        } matches: { $0 as? SyncAccountStateError == .legacyRealmUnverified }
        Harness.check(
            "probe.invalidPartialDirNoBinding",
            !FileManager.default.fileExists(atPath: SyncAccountStateStore.stateURL.path)
        )
        Harness.check(
            "probe.invalidPartialDirBytesPreserved",
            readBytes(downloads) == Data("synthetic".utf8)
        )
    }

    // 4e. Genuine first bind keeps the offline outbox; restart restores the
    //     cursor; cursor stays monotonic.
    do {
        let vault = freshFixtureVault("account-first-bind")
        let outboxURL = SyncTransferSidecarBinding.syncDirectory(vaultRoot: vault)
            .appendingPathComponent("outbox-v1.json")
        let outboxBytes = Data("{\"schema_version\":1,\"operations\":[\"offline-intent\"]}".utf8)
        write("{\"schema_version\":1,\"operations\":[\"offline-intent\"]}", to: outboxURL)
        let identity = realm("https://a.example", userA)
        do {
            let cursor = try SyncAccountStateStore.bind(to: identity)
            Harness.check("account.firstBindCursorZero", cursor == 0)
        } catch {
            Harness.check("account.firstBindCursorZero", false, "unexpected \(error)")
        }
        Harness.check("account.firstBindOutboxPreserved", readBytes(outboxURL) == outboxBytes)
        do {
            try SyncAccountStateStore.advancePullCursor(to: 42, for: identity)
            let restarted = try SyncAccountStateStore.bind(to: identity)
            Harness.check("account.restartRestoresCursor", restarted == 42, "got \(restarted)")
            try SyncAccountStateStore.advancePullCursor(to: 12, for: identity)
            let afterRewind = try SyncAccountStateStore.pullCursor(for: identity)
            Harness.check("account.cursorMonotonic", afterRewind == 42, "got \(afterRewind)")
        } catch {
            Harness.check("account.cursorFlow", false, "unexpected \(error)")
        }
    }

    // 4f. Realm mismatch (same UUID / different origin and reverse) holds
    //     every byte.
    do {
        _ = freshFixtureVault("account-realm-mismatch")
        let identityA = realm("https://a.example", userA)
        _ = try? SyncAccountStateStore.bind(to: identityA)
        try? SyncAccountStateStore.advancePullCursor(to: 5, for: identityA)
        let stateBefore = readBytes(SyncAccountStateStore.stateURL)

        let identityB = realm("https://b.example", userA)
        Harness.checkThrows("account.sameUserOtherOriginRejected") {
            try SyncAccountStateStore.bind(to: identityB)
        } matches: {
            $0 as? SyncAccountStateError == .originMismatch(expected: "https://a.example", actual: "https://b.example")
        }
        let identityC = realm("https://a.example", userB)
        Harness.checkThrows("account.otherUserSameOriginRejected") {
            try SyncAccountStateStore.bind(to: identityC)
        } matches: {
            if case SyncAccountStateError.accountMismatch = $0 { return true }
            return false
        }
        Harness.check("account.mismatchStatePreserved", readBytes(SyncAccountStateStore.stateURL) == stateBefore)
        do {
            let cursor = try SyncAccountStateStore.pullCursor(for: identityA)
            Harness.check("account.mismatchCursorIntact", cursor == 5, "got \(cursor)")
        } catch {
            Harness.check("account.mismatchCursorIntact", false, "unexpected \(error)")
        }
    }
}

// MARK: - 4b. Valid sidecar positives (schema-1 compatibility)

func runValidSidecarPositives() {
    let user = UUID()
    let identity = realm("https://a.example", user)

    // Empty schema-1 document without header: genuine first-claim state.
    do {
        let vault = freshFixtureVault("account-valid-empty-v1")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        let original = try! JSONSerialization.data(withJSONObject: [
            "records": [], "schema_version": 1,
        ])
        writeData(original, to: transfer)
        Harness.check(
            "valid.emptySchema1UnclaimedVerdict",
            String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)) == "claimable"
        )
        do {
            _ = try SyncAccountStateStore.bind(to: identity)
            Harness.check("valid.emptySchema1UnclaimedBinds", true)
        } catch {
            Harness.check("valid.emptySchema1UnclaimedBinds", false, "unexpected \(error)")
        }
        Harness.check(
            "valid.emptySchema1UnclaimedAccountCreated",
            FileManager.default.fileExists(atPath: SyncAccountStateStore.stateURL.path)
        )
        Harness.check("valid.emptySchema1UnclaimedBytesPreserved", readBytes(transfer) == original)
        do {
            let restarted = try SyncAccountStateStore.bind(to: identity)
            Harness.check("valid.emptySchema1UnclaimedRestartCursor", restarted == 0)
        } catch {
            Harness.check("valid.emptySchema1UnclaimedRestartCursor", false, "unexpected \(error)")
        }
    }

    // Empty schema-1 document with a MATCHING header: proven, restartable,
    // never rebound to a foreign realm.
    do {
        let vault = freshFixtureVault("account-valid-header-v1")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        let original = try! JSONSerialization.data(withJSONObject: [
            "realm_origin": "https://a.example",
            "realm_user_id": user.uuidString.lowercased(),
            "records": [],
            "schema_version": 1,
        ])
        writeData(original, to: transfer)
        Harness.check(
            "valid.emptySchema1MatchingHeaderVerdict",
            String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)) == "proven"
        )
        do {
            _ = try SyncAccountStateStore.bind(to: identity)
            Harness.check("valid.emptySchema1MatchingHeaderBinds", true)
        } catch {
            Harness.check("valid.emptySchema1MatchingHeaderBinds", false, "unexpected \(error)")
        }
        Harness.check("valid.emptySchema1MatchingHeaderBytesPreserved", readBytes(transfer) == original)
        let foreign = realm("https://a.example", UUID())
        let foreignVerdict = String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: foreign))
        Harness.check(
            "valid.emptySchema1MatchingHeaderForeign",
            foreignVerdict.hasPrefix("foreign"),
            "got \(foreignVerdict)"
        )
    }

    // Fully typed record document (store-compatible values) is proven; the
    // same shape with a null/wrong value stays unproven even under a
    // matching header.
    let goodRecord: [String: Any] = [
        "id": "upload:harness",
        "memo_id": UUID().uuidString.lowercased(),
        "local_path": "raw/assets/x.png",
        "descriptor": [
            "content_sha256": String(repeating: "a", count: 64),
            "kind": "photo",
            "mime_type": "image/png",
            "object_key": "\(user.uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(String(repeating: "a", count: 64)).png",
            "original_filename": "x.png",
            "position": 0,
            "size_bytes": 8,
        ],
        "direction": "upload",
        "status": "pending",
        "upload_offset": 0,
        "updated_at": "2026-10-01T00:00:00Z",
    ]
    let header: [String: Any] = [
        "realm_origin": "https://a.example",
        "realm_user_id": user.uuidString.lowercased(),
    ]
    do {
        let vault = freshFixtureVault("account-valid-typed-record")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        var object = header
        object["records"] = [goodRecord]
        object["schema_version"] = 1
        writeData(try! JSONSerialization.data(withJSONObject: object), to: transfer)
        Harness.check(
            "valid.typedRecordMatchingHeaderVerdict",
            String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity)) == "proven"
        )
    }
    do {
        let vault = freshFixtureVault("account-valid-null-record")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        var object = header
        object["records"] = [[
            "id": NSNull(), "memo_id": NSNull(), "local_path": NSNull(),
            "descriptor": NSNull(), "direction": NSNull(), "status": NSNull(),
            "upload_offset": NSNull(), "updated_at": NSNull(),
        ]]
        object["schema_version"] = 1
        writeData(try! JSONSerialization.data(withJSONObject: object), to: transfer)
        let verdict = String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity))
        Harness.check("valid.nullRecordMatchingHeaderUnproven", verdict == "unproven", "got \(verdict)")
        Harness.checkThrows("valid.nullRecordMatchingHeaderBindRejected") {
            try SyncAccountStateStore.bind(to: identity)
        }
    }

    // Schema version is a strict integer: booleans, null and fractions never
    // pass as schema 1, and unknown versions stay unproven.
    for (label, schema) in [
        ("boolTrue", "true"),
        ("boolFalse", "false"),
        ("null", "null"),
        ("fractional", "1.5"),
        ("unknown", "2"),
    ] {
        let vault = freshFixtureVault("account-schema-\(label)")
        let transfer = SyncTransferSidecarBinding.transfersFileURL(vaultRoot: vault)
        let json = #"{"records":[],"schema_version":\#(schema)}"#
        writeData(Data(json.utf8), to: transfer)
        let verdict = String(describing: SyncTransferSidecarBinding.inspect(vaultRoot: vault, expecting: identity))
        Harness.check("valid.schema\(label)Unproven", verdict == "unproven", "got \(verdict)")
    }
}

// MARK: - 4c. Exact-token proof cache (fake transport, no networking)

func runTokenProver() async {
    let user = UUID()
    let identity = realm("https://a.example", user)
    let configuration = try! SyncBackendConfiguration(
        url: URL(string: "https://a.example")!,
        publishableKey: "key-a"
    )
    let context = try! SyncSessionContext(
        identity: identity,
        configuration: configuration,
        serverVerifiedUserID: user,
        serverVerifiedAt: Date()
    )
    func makeToken(_ tag: Int) throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try encode(["alg": "HS256", "typ": "JWT"])
        let payload = try encode([
            "iss": identity.origin.authIssuer,
            "sub": user.uuidString.lowercased(),
            "role": "authenticated",
            "exp": Date(timeIntervalSince1970: 6_000_000_000 + Double(tag)).timeIntervalSince1970,
        ])
        return "\(header).\(payload).c2lnbmF0dXJl"
    }

    // Singleflight per exact value: A and B complete in reverse start order,
    // each result carries exactly its own requested token.
    do {
        let transport = OrderedProofTransport(userID: user)
        let prover = SyncSessionTokenProver(
            context: context,
            lease: SyncSessionLease(),
            proofTransport: transport
        )
        let t1 = try! makeToken(1)
        let t2 = try! makeToken(2)
        let taskA = Task { try await prover.verifiedToken(t1) }
        await transport.waitUntilEntered(0)
        let taskB1 = Task { try await prover.verifiedToken(t2) }
        await transport.waitUntilEntered(1)
        let taskB2 = Task { try await prover.verifiedToken(t2) }

        await transport.release(0)
        do {
            let resultA = try await taskA.value
            Harness.check("proof.singleflightAOwnValue", resultA.value == t1)
        } catch {
            Harness.check("proof.singleflightAOwnValue", false, "unexpected \(error)")
        }
        await transport.release(1)
        do {
            let resultB1 = try await taskB1.value
            let resultB2 = try await taskB2.value
            Harness.check(
                "proof.singleflightBOwnValueBothWaiters",
                resultB1.value == t2 && resultB2.value == t2
            )
        } catch {
            Harness.check("proof.singleflightBOwnValueBothWaiters", false, "unexpected \(error)")
        }
        Harness.check("proof.singleflightTwoRequests", transport.requests == 2, "got \(transport.requests)")
    }

    // Completion currency: a candidate that expires while its proof is in
    // flight must be refused at the CURRENT clock and never cached.
    do {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 6_000_000_000))
        let transport = OrderedProofTransport(userID: user)
        let prover = SyncSessionTokenProver(
            context: context,
            lease: SyncSessionLease(),
            proofTransport: transport,
            clock: { clock.now }
        )
        let token = try! makeToken(3) // expires 6_000_000_003
        let task = Task { try await prover.verifiedToken(token) }
        await transport.waitUntilEntered(0)
        clock.now = Date(timeIntervalSince1970: 6_000_000_010)
        await transport.release(0)
        do {
            _ = try await task.value
            Harness.check("proof.expiredAtCompletionRefused", false, "capability returned after expiry")
        } catch {
            Harness.check(
                "proof.expiredAtCompletionRefused",
                (error as? SyncRealmError) == .sessionTokenInvalid(.expired),
                "got \(error)"
            )
        }
        Harness.check("proof.expiredNotCached", transport.requests == 1)
    }
}

// MARK: - 5. Generation lease linearization

func runGenerationLease() {
    // 5a. Refused commits run no effect.
    do {
        let lease = SyncSessionLease()
        var committed = 0
        _ = try? lease.withValidity { committed += 1 }
        lease.invalidate()
        Harness.checkThrows("lease.refusedCommitThrows") {
            try lease.withValidity { committed += 1 }
        } matches: { $0 as? SyncRealmError == .sessionInvalidated }
        Harness.check("lease.refusedCommitNoEffect", committed == 1, "got \(committed)")
    }

    // 5b. A commit that entered before invalidation finishes; invalidation
    //     linearizes after it and later commits are refused.
    do {
        let lease = SyncSessionLease()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var committedValue: Int?
        var commitFailed = false

        DispatchQueue.global().async {
            do {
                _ = try lease.withValidity {
                    entered.signal()
                    release.wait()
                    committedValue = 1
                }
            } catch {
                commitFailed = true
            }
            done.signal()
        }
        entered.wait()

        let invalidated = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            lease.invalidate()
            invalidated.signal()
        }
        release.signal()
        invalidated.wait()
        done.wait()

        Harness.check("lease.preInvalidationCommitFinishes", committedValue == 1 && !commitFailed)
        Harness.checkThrows("lease.postInvalidationRefused") {
            try lease.withValidity { committedValue = 2 }
        } matches: { $0 as? SyncRealmError == .sessionInvalidated }
        Harness.check("lease.postInvalidationNoEffect", committedValue == 1)
    }

    // 5c. Documented ordering: an invalidation observed from INSIDE an
    //     already-entered commit does not tear the commit apart.
    do {
        let lease = SyncSessionLease()
        var effects: [String] = []
        do {
            _ = try lease.withValidity {
                effects.append("before")
                lease.invalidate()
                effects.append("after")
            }
        } catch {
            Harness.check("lease.midCommitOrdering", false, "commit torn by \(error)")
        }
        Harness.check("lease.midCommitOrdering", effects == ["before", "after"], "got \(effects)")
        let refused = (try? lease.withValidity { effects.append("late") }) == nil
        Harness.check("lease.afterMidCommitRefused", refused && effects == ["before", "after"])
    }
}

// MARK: - Entry point

// MARK: - Fakes for the token-proof cases

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

final class OrderedProofTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let userID: UUID
    private var nextIndex = 0
    private var entered: [Int: CheckedContinuation<Void, Never>] = [:]
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var requestCount = 0

    init(userID: UUID) {
        self.userID = userID
    }

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        requestCount += 1
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            gates[index] = continuation
            let waiter = entered[index]
            entered[index] = nil
            lock.unlock()
            waiter?.resume()
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
        lock.lock()
        if gates[index] != nil {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if gates[index] != nil {
                lock.unlock()
                continuation.resume()
            } else {
                entered[index] = continuation
                lock.unlock()
            }
        }
    }

    func release(_ index: Int) {
        lock.lock()
        let gate = gates[index]
        gates[index] = nil
        lock.unlock()
        gate?.resume()
    }
}

guard let envFixtureRoot = ProcessInfo.processInfo.environment["DAYPAGE_HARNESS_FIXTURE_ROOT"],
      !envFixtureRoot.isEmpty else {
    print("FAIL harness.fixtureRootMissing :: DAYPAGE_HARNESS_FIXTURE_ROOT not set")
    exit(2)
}
fixtureRootPath = envFixtureRoot

runOriginNormalization()
runConfigurationPair()
runValidSidecarPositives()
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    await runTokenAndServerProof()
    await runTokenProver()
    semaphore.signal()
}
semaphore.wait()
runAccountSidecar()
runGenerationLease()

let failed = Harness.results.filter { !$0.ok }
print("HARNESS_SUMMARY passed=\(Harness.results.count - failed.count) failed=\(failed.count)")
if !failed.isEmpty {
    exit(1)
}
'''


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_command(command: list[str], cwd: pathlib.Path, env: dict | None = None):
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=1800,
    )
    return completed


def changed_swift_files(repo_root: pathlib.Path) -> list[str]:
    names: set[str] = set()
    diff = run_command(
        ["git", "diff", "--name-only", BASE_COMMIT, "--", "*.swift"], repo_root
    )
    if diff.returncode == 0:
        names.update(line for line in diff.stdout.splitlines() if line.strip())
    untracked = run_command(
        ["git", "ls-files", "--others", "--exclude-standard", "--", "*.swift"], repo_root
    )
    if untracked.returncode == 0:
        names.update(line for line in untracked.stdout.splitlines() if line.strip())
    apple_prefixes = ("DayPage/", "DayPageMac/", "DayPageKit/", "DayPageTests/", "DayPageWatch/", "DayPageWidget/")
    return sorted(name for name in names if name.startswith(apple_prefixes))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact-root",
        required=True,
        help="Registered artifact root for fixtures, binaries and evidence",
    )
    args = parser.parse_args()

    repo_root = pathlib.Path(__file__).resolve().parents[2]
    artifact_root = pathlib.Path(args.artifact_root).resolve()
    if not pathlib.Path(args.artifact_root).is_absolute():
        print("ERROR --artifact-root must be an absolute path", file=sys.stderr)
        return 2
    if artifact_root in (pathlib.Path("/"), pathlib.Path.home()):
        print("ERROR refusing suspicious artifact root", file=sys.stderr)
        return 2
    artifact_root.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = artifact_root / "work" / f"run-{timestamp}-{os.getpid()}"
    fixtures_dir = run_dir / "fixtures"
    bin_dir = run_dir / "bin"
    for directory in (fixtures_dir, bin_dir):
        directory.mkdir(parents=True, exist_ok=True)

    def under_root(path: pathlib.Path) -> bool:
        try:
            path.resolve().relative_to(artifact_root)
            return True
        except ValueError:
            return False

    # ---- gather actual sources + hashes -----------------------------------
    source_paths: list[pathlib.Path] = []
    source_hashes: dict[str, str] = {}
    for relative in REPO_RELATIVE_SOURCES:
        path = repo_root / relative
        if not path.is_file():
            print(f"ERROR missing required source {relative}", file=sys.stderr)
            return 2
        source_paths.append(path)
        source_hashes[relative] = sha256_file(path)

    adapter_path = run_dir / "VaultInitializerAdapter.swift"
    adapter_path.write_text(VAULT_ADAPTER, encoding="utf-8")
    # Top-level executable code requires the file to be named main.swift.
    harness_main_path = run_dir / "main.swift"
    harness_main_path.write_text(HARNESS_MAIN, encoding="utf-8")
    source_hashes["<generated>/VaultInitializerAdapter.swift"] = sha256_file(adapter_path)
    source_hashes["<generated>/host_harness_main.swift"] = sha256_file(harness_main_path)

    # ---- compile the focused Foundation host harness ---------------------
    binary_path = bin_dir / "sync_realm_host_harness"
    compile_command = [
        "swiftc",
        "-swift-version", "5",
        "-o", str(binary_path),
        *[str(path) for path in source_paths],
        str(adapter_path),
        str(harness_main_path),
    ]
    compiled = run_command(compile_command, repo_root)
    if compiled.returncode != 0 or not binary_path.is_file():
        print("ERROR harness compilation failed", file=sys.stderr)
        print(compiled.stdout, file=sys.stderr)
        print(compiled.stderr, file=sys.stderr)
        shutil.rmtree(run_dir, ignore_errors=True)
        return 2
    if not under_root(binary_path):
        print("ERROR harness binary escaped the artifact root", file=sys.stderr)
        return 2

    # ---- execute the harness --------------------------------------------
    env = dict(os.environ)
    env["DAYPAGE_HARNESS_FIXTURE_ROOT"] = str(fixtures_dir)
    executed = run_command([str(binary_path)], run_dir, env=env)
    harness_output = executed.stdout + executed.stderr
    print(harness_output.strip())

    harness_results = []
    for line in harness_output.splitlines():
        if line.startswith(("PASS ", "FAIL ")):
            status, _, rest = line.partition(" ")
            name, _, detail = rest.partition(" :: ")
            harness_results.append(
                {"name": name, "status": "pass" if status == "PASS" else "fail", "detail": detail}
            )
    summary_line = next(
        (line for line in harness_output.splitlines() if line.startswith("HARNESS_SUMMARY")), ""
    )
    harness_ok = executed.returncode == 0 and "failed=0" in summary_line and bool(harness_results)

    # ---- syntax-only parse receipts for changed Apple files --------------
    parse_results = []
    parse_ok = True
    for relative in changed_swift_files(repo_root):
        parsed = run_command(
            ["swiftc", "-frontend", "-parse", relative], repo_root
        )
        entry_ok = parsed.returncode == 0
        parse_ok = parse_ok and entry_ok
        parse_results.append({"file": relative, "status": "ok" if entry_ok else "failed"})
    parse_results.append(
        {
            "file": "<note>",
            "status": "syntax-only",
            "detail": "swiftc -frontend -parse is not a full app/Xcode/SwiftPM build",
        }
    )

    # ---- aggregate evidence (retained) + disposable cleanup --------------
    evidence_dir = artifact_root / "evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    evidence_path = evidence_dir / "sync-realm-host-evidence.json"
    evidence = {"aggregate": "sync-realm-host", "runs": []}
    if evidence_path.is_file():
        try:
            existing = json.loads(evidence_path.read_text(encoding="utf-8"))
            if isinstance(existing.get("runs"), list):
                evidence = existing
        except (ValueError, OSError):
            pass

    compiler = run_command(["swiftc", "--version"], repo_root)
    evidence["runs"].append(
        {
            "timestamp": timestamp,
            "artifact_root": str(artifact_root),
            "compiler": compiler.stdout.strip().splitlines()[0] if compiler.stdout.strip() else "unknown",
            "source_sha256": source_hashes,
            "harness": {
                "compiled": True,
                "exit_code": executed.returncode,
                "summary": summary_line,
                "results": harness_results,
            },
            "parse_syntax_only": parse_results,
            "result": "pass" if (harness_ok and parse_ok) else "fail",
        }
    )
    evidence_path.write_text(json.dumps(evidence, indent=1, sort_keys=True), encoding="utf-8")

    # Disposable fixture/build children of THIS run are removed; aggregate
    # evidence and source hashes are retained above.
    shutil.rmtree(run_dir, ignore_errors=True)

    print(f"EVIDENCE {evidence_path}")
    print(f"RESULT {'pass' if (harness_ok and parse_ok) else 'fail'}")
    if not harness_ok:
        print("ERROR harness checks failed", file=sys.stderr)
        return 1
    if not parse_ok:
        print("ERROR syntax-only parse failed for changed Apple files", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
