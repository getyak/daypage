// SupabaseAccountTagsReaderTests.swift — #884 T03/T04/T09/T20 reader
// acceptance over a synthetic in-memory tag server.
//
// The fake transport serves the REAL PostgREST table semantics the production
// reader speaks (keyset paging, limit, exact count headers) and captures the
// exact `URLRequest` bytes so encoding assertions run against real requests.
// No network, no credentials, no real vault.

import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

final class SupabaseAccountTagsReaderTests: XCTestCase {

    private var realm: SyncRealmIdentity!
    private var session: SyncSession!

    override func setUpWithError() throws {
        realm = try SyncRealmTestSupport.realm()
        session = try SyncRealmTestSupport.session(realm: realm)
    }

    override func tearDown() {
        realm = nil
        session = nil
    }

    private func makeReader(
        _ server: FakeTagTables,
        pageSize: Int = 500,
        maxPagesPerTable: Int = SupabaseAccountTagsReader.defaultMaxPagesPerTable
    ) -> SupabaseAccountTagsReader {
        let bound = realm!
        return SupabaseAccountTagsReader(
            session: session,
            transport: server,
            accessTokenProvider: { try SyncRealmTestSupport.token(realm: bound) },
            pageSize: pageSize,
            maxPagesPerTable: maxPagesPerTable
        )
    }

    // MARK: - T03 complete keyset paging (1005 labels / 1005 links / 1005 memos)

    func testPagingCompletesBeyondOneThousandWithoutTruncation() async throws {
        let server = FakeTagTables()
        let owner = realm.userID
        var catalogue: [[String: Any]] = [
            ["user_id": owner.uuidString.lowercased(), "label": "#shared", "in_import_catalog": false]
        ]
        var links: [[String: Any]] = []
        let memoIDs = (0..<1_005).map { Self.memoUUID(index: $0) }
        for index in 0..<1_005 {
            let label = String(format: "#tag%04d", index)
            catalogue.append([
                "user_id": owner.uuidString.lowercased(),
                "label": label,
                "in_import_catalog": true
            ])
            // One memo carries 1005 links across catalogue page boundaries …
            links.append([
                "user_id": owner.uuidString.lowercased(),
                "memo_id": memoIDs[0].uuidString.lowercased(),
                "label": label
            ])
        }
        // … and 1005 memos share #shared.
        for memoID in memoIDs {
            links.append([
                "user_id": owner.uuidString.lowercased(),
                "memo_id": memoID.uuidString.lowercased(),
                "label": "#shared"
            ])
        }
        server.catalogue = Self.sortedCatalogue(catalogue)
        server.links = Self.sortedLinks(links)
        server.markers = (0..<2).map { index in
            [
                "user_id": owner.uuidString.lowercased(),
                "source_sha256": String(repeating: String(format: "%x", index), count: 64),
                "payload_hash": String(repeating: "a", count: 64),
                "version": 1
            ]
        }

        let reader = makeReader(server)
        let catalogueRows = try await reader.catalogueRows()
        let linkRows = try await reader.linkRows()
        let markers = try await reader.importMarkers()
        let count = try await reader.exactReceiptCount()

        XCTAssertEqual(catalogueRows.count, 1_006)
        XCTAssertEqual(linkRows.count, 2_010)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(count, 2)
        // No silent 1000-row stop: 1006 catalogue rows = pages 500/500/6.
        XCTAssertEqual(server.calls(table: "user_tags"), 3)
        // 2010 links = 500*4 + 10.
        XCTAssertEqual(server.calls(table: "memo_tag_links"), 5)
        // Exact label bytes survive multi-page keyset cursors.
        XCTAssertEqual(catalogueRows.first?.label.text, "#shared")
        XCTAssertTrue(catalogueRows.contains { $0.label.text == "#tag1004" })
        // No per-memo N+1: link paging is table-keyset only.
        XCTAssertFalse(server.requests.contains {
            ($0.url?.absoluteString ?? "").contains("in.(")
        })
    }

    /// Exactly 1000 rows must still issue the follow-up request that proves
    /// the END of the table instead of trusting a full final page.
    func testExactlyFullFinalPageStillVerifiesEnd() async throws {
        let server = FakeTagTables()
        let owner = realm.userID
        server.catalogue = (0..<1_000).map { index in
            [
                "user_id": owner.uuidString.lowercased(),
                "label": String(format: "#t%06d", index),
                "in_import_catalog": false
            ]
        }
        let reader = makeReader(server)
        let rows = try await reader.catalogueRows()
        XCTAssertEqual(rows.count, 1_000)
        XCTAssertEqual(server.calls(table: "user_tags"), 3)
    }

    /// Malformed pages fail the WHOLE round: out-of-order rows, duplicates, a
    /// non-advancing cursor and over-long pages are all typed failures.
    func testOutOfOrderDuplicateNonAdvancingAndOverlongPagesFailWholeRound() async throws {
        let owner = realm.userID
        func row(_ label: String) -> [String: Any] {
            ["user_id": owner.uuidString.lowercased(), "label": label, "in_import_catalog": false]
        }

        // Out-of-order.
        let unordered = FakeTagTables()
        unordered.catalogue = [row("#b"), row("#a")]
        await assertCatalogueFails(unordered, .invalidRows)

        // Duplicate.
        let duplicate = FakeTagTables()
        duplicate.catalogue = [row("#a"), row("#a")]
        await assertCatalogueFails(duplicate, .invalidRows)

        // Non-advancing cursor (buggy server ignores the keyset filter).
        let nonAdvancing = FakeTagTables()
        nonAdvancing.ignoreCursor = true
        nonAdvancing.catalogue = [row("#a"), row("#b"), row("#a"), row("#c")]
        nonAdvancing.forcePageSize = 2
        await assertCatalogueFails(nonAdvancing, .invalidRows)

        // Over-long page (more rows than the requested limit).
        let overlong = FakeTagTables()
        overlong.catalogue = [row("#a"), row("#b")]
        overlong.overfill = true
        overlong.forcePageSize = 1
        await assertCatalogueFails(overlong, .invalidRows)

        // Foreign owner row.
        let foreign = FakeTagTables()
        foreign.catalogue = [
            ["user_id": UUID().uuidString.lowercased(), "label": "#a", "in_import_catalog": false]
        ]
        await assertCatalogueFails(foreign, .invalidRows)
    }

    private func assertCatalogueFails(
        _ server: FakeTagTables,
        _ expected: AccountTagFetchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reader = makeReader(server, pageSize: server.forcePageSize ?? 500)
        do {
            _ = try await reader.catalogueRows()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - T04 query encoding

    /// ["#a+b", "#a b", "#a%20b", "#a,b", "#a\"b", "#a\\b", "#a&b", "#a/b",
    /// "#a_(b)*"] — real URLs carry unreserved-only percent encoding exactly
    /// once, nested literals escape quotes/backslashes, top-level cursors stay
    /// raw, and one decode restores the exact input bytes (no '+'→space).
    func testQueryEncodingRoundTripsExactLabelBytes() async throws {
        let labels = [
            "#a+b", "#a b", "#a%20b", "#a,b", "#a\"b",
            "#a\\b", "#a&b", "#a/b", "#a_(b)*"
        ]
        let sorted = labels.sorted { byteLessThan(Data($0.utf8), Data($1.utf8)) }
        let server = FakeTagTables()
        let owner = realm.userID
        server.catalogue = Self.sortedCatalogue(labels.map {
            ["user_id": owner.uuidString.lowercased(), "label": $0, "in_import_catalog": true]
        })
        let memo = Self.memoUUID(index: 42)
        server.links = Self.sortedLinks(labels.map {
            [
                "user_id": owner.uuidString.lowercased(),
                "memo_id": memo.uuidString.lowercased(),
                "label": $0
            ]
        })

        // pageSize 1 → every label becomes a keyset cursor exactly once.
        let reader = makeReader(server, pageSize: 1)
        _ = try await reader.catalogueRows()
        _ = try await reader.linkRows()

        let requests = server.requests
        XCTAssertTrue(requests.count >= 20)
        let joined = requests
            .map { $0.url?.absoluteString ?? "" }
            .joined(separator: "\n")

        // Percent-encoded forms appear; raw specials never leak into URLs.
        XCTAssertTrue(joined.contains("%2B"), "literal + must be %2B")
        XCTAssertTrue(joined.contains("%20"), "space must be %20")
        XCTAssertTrue(joined.contains("%25"), "% must be %25")
        XCTAssertTrue(joined.contains("%23"), "# must be %23")
        XCTAssertTrue(joined.contains("%26"), "& must be %26")
        XCTAssertTrue(joined.contains("%22"), "quote must be %22")
        XCTAssertTrue(joined.contains("%5C"), "backslash must be %5C")
        XCTAssertTrue(joined.contains("%28"), "( must be %28")
        XCTAssertTrue(joined.contains("%2A"), "* must be %2A")
        XCTAssertFalse(joined.contains("#a"), "raw label text must never appear unencoded")
        XCTAssertFalse(joined.contains("+"), "literal + must never appear unencoded")

        // Top-level `gt` cursors are RAW values (never quoted).
        for label in sorted {
            let request = try XCTUnwrap(
                requests.first {
                    Self.decodedPairs($0).contains { $0.0 == "label" && $0.1 == "gt.\(label)" }
                },
                "missing top-level cursor request"
            )
            let query = Self.query(of: request)
            XCTAssertTrue(query.contains("label=gt."))
            XCTAssertFalse(query.contains("label=gt.%22"), "top-level gt must not be quoted")
        }

        // Nested composite cursors: quoted + escaped, one encode, exact bytes.
        let memoID = memo.uuidString.lowercased()
        for label in sorted {
            let escaped = label
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let expectedOr = "(memo_id.gt.\(memoID),and(memo_id.eq.\(memoID),label.gt.\"\(escaped)\"))"
            let request = try XCTUnwrap(
                requests.first {
                    Self.decodedPairs($0).contains { $0.0 == "or" && $0.1 == expectedOr }
                },
                "missing nested cursor"
            )
            // One decode restores EXACT input bytes (no '+'→space, no
            // double-decode, quotes/backslashes unescaped once).
            let decoded = try XCTUnwrap(
                Self.decodedPairs(request).first { $0.0 == "or" }
            ).1
            let literalStart = try XCTUnwrap(decoded.range(of: "label.gt.")).upperBound
            var literal = String(decoded[literalStart...])
            XCTAssertTrue(literal.hasPrefix("\""))
            literal = String(literal.dropFirst().dropLast(3))
            let restored = Self.unescapeFilterLiteral(literal)
            XCTAssertEqual(Data(restored.utf8), Data(label.utf8))
        }

        // Everything the reader sent was a GET with the verified bearer and
        // no write verb.
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testSingleEncodingHelpersMatchContract() {
        XCTAssertEqual(SupabaseAccountTagQuery.encodeValue("#a+b c"), "%23a%2Bb%20c")
        XCTAssertEqual(SupabaseAccountTagQuery.encodeValue("a/b"), "a%2Fb")
        XCTAssertEqual(SupabaseAccountTagQuery.encodeValue("a_(b)*"), "a_%28b%29%2A")
        XCTAssertEqual(SupabaseAccountTagQuery.encodeValue("50"), "50")
        XCTAssertEqual(SupabaseAccountTagQuery.quoteFilterLiteral("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    // MARK: - Review regressions: count-probe auth, combining marks, wire types

    /// The exact-count probe must carry the SAME verified bearer as table
    /// reads (the receipt table is authenticated-only). Regression for the
    /// review P1 where the probe sent no Authorization at all.
    func testCountProbeCarriesTheExactVerifiedBearer() async throws {
        let server = FakeTagTables()
        server.markers = []
        let reader = makeReader(server)

        let count = try await reader.exactReceiptCount()
        XCTAssertEqual(count, 0)

        let countRequests = server.requests.filter {
            $0.value(forHTTPHeaderField: "Prefer") == "count=exact"
        }
        XCTAssertEqual(countRequests.count, 1)
        let request = try XCTUnwrap(countRequests.first)
        let expectedToken = try SyncRealmTestSupport.token(realm: realm)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(expectedToken)",
            "count probe must send the exact session-proven bearer"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_test_key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "0-0")
        XCTAssertEqual(request.httpMethod, "GET")

        // The same probe with an invalidated lease sends ZERO requests.
        session.lease.invalidate()
        do {
            _ = try await reader.exactReceiptCount()
            XCTFail("expected lease failure")
        } catch {
            // refused before any send
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    /// ASCII quote/backslash/plus immediately followed by a combining mark
    /// form ONE Swift `Character`; escaping must therefore work on Unicode
    /// scalars, or the quote/backslash slips through unescaped and the
    /// nested filter grammar breaks.
    func testNestedCursorsEscapeScalarsBeforeCombiningMarks() async throws {
        let labels = [
            "#a\u{22}\u{301}z",   // quote + combining acute
            "#a\u{5C}\u{301}z",   // backslash + combining acute
            "#a+\u{301}z",        // plus + combining acute
            "#a\u{301}\u{301}z"   // combining marks only (never escaped)
        ]
        let sorted = labels.sorted { byteLessThan(Data($0.utf8), Data($1.utf8)) }
        let server = FakeTagTables()
        let owner = realm.userID
        server.catalogue = Self.sortedCatalogue(labels.map {
            ["user_id": owner.uuidString.lowercased(), "label": $0, "in_import_catalog": true]
        })
        let memo = Self.memoUUID(index: 7)
        server.links = Self.sortedLinks(labels.map {
            [
                "user_id": owner.uuidString.lowercased(),
                "memo_id": memo.uuidString.lowercased(),
                "label": $0
            ]
        })

        // pageSize 1 → every label becomes a nested keyset cursor.
        let reader = makeReader(server, pageSize: 1)
        _ = try await reader.linkRows()

        // Hard-coded escaped literals (scalar-level escaping).
        let expectedEscaped: [String: String] = [
            // quote escaped to \" with the combining mark untouched
            "#a\u{22}\u{301}z": "#a\\\"\u{301}z",
            // backslash escaped to \\ with the combining mark untouched
            "#a\u{5C}\u{301}z": "#a\\\\\u{301}z",
            // plus is grammar-inert (percent-encoded as %2B later)
            "#a+\u{301}z": "#a+\u{301}z",
            // combining marks alone are preserved byte-exact
            "#a\u{301}\u{301}z": "#a\u{301}\u{301}z"
        ]
        let memoID = memo.uuidString.lowercased()
        for label in sorted {
            let escaped = try XCTUnwrap(expectedEscaped[label])
            let expectedOr = "(memo_id.gt.\(memoID),and(memo_id.eq.\(memoID),label.gt.\"\(escaped)\"))"
            let request = try XCTUnwrap(
                server.requests.first {
                    Self.decodedPairs($0).contains { $0.0 == "or" && $0.1 == expectedOr }
                },
                "missing escaped nested cursor"
            )
            // One decode restores EXACT input bytes for every cursor.
            let decoded = try XCTUnwrap(
                Self.decodedPairs(request).first { $0.0 == "or" }
            ).1
            let literalStart = try XCTUnwrap(decoded.range(of: "label.gt.")).upperBound
            var literal = String(decoded[literalStart...])
            XCTAssertTrue(literal.hasPrefix("\""))
            literal = String(literal.dropFirst().dropLast(3))
            let restored = Self.unescapeFilterLiteral(literal)
            XCTAssertEqual(Data(restored.utf8), Data(label.utf8))
        }

        // The escaping shows up percent-encoded in the real request bytes.
        let joined = server.requests
            .map { $0.url?.absoluteString ?? "" }
            .joined(separator: "\n")
        XCTAssertTrue(joined.contains("%5C%22"), "escaped quote must be %5C%22")
        XCTAssertTrue(joined.contains("%5C%5C"), "escaped backslash must be %5C%5C")
        XCTAssertTrue(joined.contains("%2B"), "plus must stay %2B")
    }

    /// Wrong wire types must fail the round instead of coercing through
    /// NSNumber bridging: `version: true` is NOT 1 and
    /// `in_import_catalog: 1` is NOT true. Correct wire types pass.
    func testWrongWireTypesAreRejectedNotCoerced() async throws {
        let owner = realm.userID
        let goodHash = String(repeating: "a", count: 64)

        // `version: true` (bool where the contract says integer).
        let boolVersion = FakeTagTables()
        boolVersion.markers = [[
            "user_id": owner.uuidString.lowercased(),
            "source_sha256": goodHash,
            "payload_hash": String(repeating: "b", count: 64),
            "version": true
        ]]
        await assertMarkersFail(boolVersion)

        // `in_import_catalog: 1` (number where the contract says bool).
        let numberFlag = FakeTagTables()
        numberFlag.catalogue = [[
            "user_id": owner.uuidString.lowercased(),
            "label": "#a",
            "in_import_catalog": 1
        ]]
        await assertCatalogueFails(numberFlag, .invalidRows)

        // Correct wire types are accepted.
        let goodTypes = FakeTagTables()
        goodTypes.markers = [[
            "user_id": owner.uuidString.lowercased(),
            "source_sha256": goodHash,
            "payload_hash": String(repeating: "b", count: 64),
            "version": 1
        ]]
        goodTypes.catalogue = [[
            "user_id": owner.uuidString.lowercased(),
            "label": "#a",
            "in_import_catalog": true
        ]]
        let reader = makeReader(goodTypes)
        let markers = try await reader.importMarkers()
        let catalogue = try await reader.catalogueRows()
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.version, 1)
        XCTAssertEqual(catalogue.count, 1)
        XCTAssertEqual(catalogue.first?.inImportCatalog, true)
    }

    // MARK: - T09 lease-before-send

    /// An invalidated session generation must start ZERO requests.
    func testInvalidatedLeaseStartsZeroRequests() async throws {
        let server = FakeTagTables()
        server.markers = []
        let reader = makeReader(server)
        session.lease.invalidate()

        for call in [
            { try await reader.exactReceiptCount() as Int },
            { try await reader.importMarkers().count },
            { try await reader.catalogueRows().count },
            { try await reader.linkRows().count }
        ] as [() async throws -> Int] {
            do {
                _ = try await call()
                XCTFail("expected lease failure")
            } catch {
                // Refused before any send.
            }
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: - Exact count proof (T20 count-missing)

    func testExactCountRequiresProvableHeader() async throws {
        let server = FakeTagTables()
        server.markers = []
        let reader = makeReader(server)

        // Normal exact header.
        let exact = try await reader.exactReceiptCount()
        XCTAssertEqual(exact, 0)

        // Missing header → typed failure, never "0".
        server.countHeaderMode = .missing
        await assertCountFails(reader, .countUnavailable)

        // Estimated (non-numeric total) → typed failure.
        server.countHeaderMode = .estimated
        await assertCountFails(reader, .countUnavailable)
    }

    private func assertCountFails(
        _ reader: SupabaseAccountTagsReader,
        _ expected: AccountTagFetchError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await reader.exactReceiptCount()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testContentRangeParsingIsStrict() throws {
        XCTAssertEqual(try SupabaseAccountTagsReader.exactTotal(fromContentRange: "0-0/123"), 123)
        XCTAssertEqual(try SupabaseAccountTagsReader.exactTotal(fromContentRange: "*/0"), 0)
        XCTAssertThrowsError(
            try SupabaseAccountTagsReader.exactTotal(fromContentRange: "0-0/*")
        ) { error in
            XCTAssertEqual(error as? AccountTagFetchError, .countUnavailable)
        }
        XCTAssertThrowsError(
            try SupabaseAccountTagsReader.exactTotal(fromContentRange: nil)
        )
        XCTAssertThrowsError(
            try SupabaseAccountTagsReader.exactTotal(fromContentRange: "no-slash")
        )
    }

    // MARK: - T20 bounds: budget overflow is typed incomplete

    func testPagingBudgetOverflowIsTypedIncompleteNotTruncated() async throws {
        let owner = realm.userID
        let server = FakeTagTables()
        server.catalogue = (0..<10).map { index in
            [
                "user_id": owner.uuidString.lowercased(),
                "label": String(format: "#t%02d", index),
                "in_import_catalog": false
            ]
        }
        // Budget of 2 pages with 10 rows at pageSize 1 → incomplete, not 2.
        let reader = makeReader(server, pageSize: 1, maxPagesPerTable: 2)
        do {
            let rows = try await reader.catalogueRows()
            XCTFail("expected budget failure, got \(rows.count) rows")
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, .budgetExceeded)
        }
    }

    func testMarkerValidationRejectsBadHashesVersionsAndOrder() async throws {
        let owner = realm.userID
        func marker(
            _ source: String,
            hash: String = String(repeating: "b", count: 64),
            version: Int = 1
        ) -> [String: Any] {
            ["user_id": owner.uuidString.lowercased(), "source_sha256": source, "payload_hash": hash, "version": version]
        }
        let good = String(repeating: "a", count: 64)
        let higher = String(repeating: "a", count: 63) + "b"

        let valid = FakeTagTables()
        valid.markers = [marker(good), marker(higher)]
        let reader = makeReader(valid)
        let markers = try await reader.importMarkers()
        XCTAssertEqual(markers.count, 2)

        // Uppercase hex violates the 64-lowerhex contract.
        let upper = FakeTagTables()
        upper.markers = [marker(String(repeating: "A", count: 64))]
        await assertMarkersFail(upper)

        // version must be exactly 1 (0036 CHECK).
        let badVersion = FakeTagTables()
        badVersion.markers = [marker(good, version: 2)]
        await assertMarkersFail(badVersion)

        // Non-advancing keyset order.
        let disorder = FakeTagTables()
        disorder.markers = [marker(higher), marker(good)]
        await assertMarkersFail(disorder)
    }

    private func assertMarkersFail(
        _ server: FakeTagTables,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reader = makeReader(server)
        do {
            _ = try await reader.importMarkers()
            XCTFail("expected marker validation failure", file: file, line: line)
        } catch let error as AccountTagFetchError {
            XCTAssertEqual(error, .invalidRows, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Fixture helpers

    /// Deterministic sortable memo UUIDs (`aaaaaaaa-0000-0000-0000-%012d`).
    static func memoUUID(index: Int) -> UUID {
        guard let uuid = UUID(
            uuidString: String(format: "AAAAAAAA-0000-0000-0000-%012d", index)
        ) else {
            preconditionFailure("deterministic fixture UUID")
        }
        return uuid
    }

    static func sortedCatalogue(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.sorted { lhs, rhs in
            byteLessThan(
                Data(((lhs["label"] as? String) ?? "").utf8),
                Data(((rhs["label"] as? String) ?? "").utf8)
            )
        }
    }

    static func sortedLinks(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.sorted { lhs, rhs in
            let a = Data(((lhs["memo_id"] as? String) ?? "").utf8)
            let b = Data(((rhs["memo_id"] as? String) ?? "").utf8)
            if a != b { return byteLessThan(a, b) }
            return byteLessThan(
                Data(((lhs["label"] as? String) ?? "").utf8),
                Data(((rhs["label"] as? String) ?? "").utf8)
            )
        }
    }

    static func decodedPairs(_ request: URLRequest) -> [(String, String)] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.percentEncodedQuery else { return [] }
        return raw.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecodeOnce(String(parts[0]))
            let value = parts.count > 1 ? percentDecodeOnce(String(parts[1])) : ""
            return (key, value)
        }
    }

    static func query(of request: URLRequest) -> String {
        request.url.map {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        } ?? ""
    }

    /// Scalar-level unescape for nested filter literals (`\\` → `\`,
    /// `\"` → `"`). Grapheme-based `replacingOccurrences` would fail to find
    /// an escape sequence whose escaped char is followed by a combining mark
    /// (they fuse into one `Character`) — exactly the shape this regression
    /// suite pins.
    static func unescapeFilterLiteral(_ literal: String) -> String {
        var out = ""
        let scalars = Array(literal.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\",
               index + 1 < scalars.count,
               scalars[index + 1] == "\\" || scalars[index + 1] == "\"" {
                out.unicodeScalars.append(scalars[index + 1])
                index += 2
            } else {
                out.unicodeScalars.append(scalars[index])
                index += 1
            }
        }
        return out
    }

    /// One-pass percent decode where literal '+' stays '+' (no form decoding).
    static func percentDecodeOnce(_ value: String) -> String {
        let chars = Array(value)
        var bytes: [UInt8] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "%",
               index + 2 < chars.count,
               let high = hexValue(chars[index + 1]),
               let low = hexValue(chars[index + 2]) {
                bytes.append(UInt8(high * 16 + low))
                index += 3
            } else {
                bytes.append(contentsOf: String(chars[index]).utf8)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ character: Character) -> Int? {
        switch character {
        case "0"..."9": return Int(String(character))
        case "a"..."f": return Int(String(character), radix: 16)
        case "A"..."F": return Int(String(character), radix: 16)
        default: return nil
        }
    }
}

// MARK: - Synthetic in-memory tag server

/// Serves the three 0036 tables with real keyset/limit semantics and records
/// every real `URLRequest` the reader produced.
private final class FakeTagTables: HTTPTransport, @unchecked Sendable {
    enum CountHeaderMode {
        case exact
        case missing
        case estimated
    }

    private let lock = NSLock()
    private var _catalogue: [[String: Any]] = []
    private var _links: [[String: Any]] = []
    private var _markers: [[String: Any]] = []
    private var _requests: [URLRequest] = []
    private var callCounts: [String: Int] = [:]
    var countHeaderMode: CountHeaderMode = .exact
    /// Serve one MORE row than the requested limit (server-side bug shape).
    var overfill = false
    /// Buggy server that ignores keyset cursors (non-advancing page shape).
    var ignoreCursor = false
    /// Reader page size hint for the fixtures that need a smaller page.
    var forcePageSize: Int?

    var catalogue: [[String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return _catalogue }
        set { lock.lock(); defer { lock.unlock() }; _catalogue = newValue }
    }

    var links: [[String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return _links }
        set { lock.lock(); defer { lock.unlock() }; _links = newValue }
    }

    var markers: [[String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return _markers }
        set { lock.lock(); defer { lock.unlock() }; _markers = newValue }
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    func calls(table: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return callCounts[table] ?? 0
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw MemoSyncError.invalidResponse }
        lock.lock()
        _requests.append(request)
        let table = url.lastPathComponent
        callCounts[table, default: 0] += 1
        lock.unlock()

        // The 0036 tables are authenticated-only (SELECT grant + own-row
        // RLS): an unauthenticated request is a 401, not data. This makes the
        // count-probe bearer regression real.
        if request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") != true {
            let unauthorized = HTTPURLResponse(
                url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(), unauthorized)
        }

        let pairs = SupabaseAccountTagsReaderTests.decodedPairs(request)
        let query = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) })
        let limit = Int(query["limit"] ?? "") ?? 500

        if request.value(forHTTPHeaderField: "Prefer") == "count=exact" {
            let total = markers.count
            let header: String?
            switch countHeaderMode {
            case .exact: header = "0-0/\(total)"
            case .missing: header = nil
            case .estimated: header = "0-0/*"
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: header.map { ["Content-Range": $0] }
            )!
            return (Data("[]".utf8), response)
        }

        let rows: [[String: Any]]
        switch table {
        case "user_tags":
            rows = filter(catalogue, byLabelCursor: ignoreCursor ? nil : query["label"])
        case "memo_tag_links":
            rows = filteredLinks(links, query: query)
        case "memo_tag_imports":
            rows = filteredMarkers(markers, query: query)
        default:
            throw MemoSyncError.invalidResponse
        }
        let served = overfill
            ? Array(rows.prefix(limit + 1))
            : Array(rows.prefix(limit))
        let body = try JSONSerialization.data(withJSONObject: served)
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }

    private func filter(
        _ rows: [[String: Any]],
        byLabelCursor cursor: String?
    ) -> [[String: Any]] {
        guard let cursor, cursor.hasPrefix("gt.") else { return rows }
        let raw = String(cursor.dropFirst(3))
        return rows.filter { row in
            byteLessThan(Data(raw.utf8), Data(((row["label"] as? String) ?? "").utf8))
        }
    }

    private func filteredLinks(
        _ rows: [[String: Any]],
        query: [String: String]
    ) -> [[String: Any]] {
        guard !ignoreCursor, let or = query["or"] else { return rows }
        // Parse `(memo_id.gt.<m>,and(memo_id.eq.<m>,label.gt."<esc>"))`.
        let memoPrefix = "memo_id.gt."
        guard let memoStart = or.range(of: memoPrefix) else { return rows }
        let afterMemo = or[memoStart.upperBound...]
        guard let comma = afterMemo.firstIndex(of: ",") else { return rows }
        let memo = String(afterMemo[..<comma])
        let labelPrefix = "label.gt.\""
        guard let labelStart = or.range(of: labelPrefix) else { return rows }
        let literal = String(or[labelStart.upperBound...].dropLast(3))
        let label = SupabaseAccountTagsReaderTests.unescapeFilterLiteral(literal)
        return rows.filter { row in
            let rowMemo = (row["memo_id"] as? String) ?? ""
            let rowLabel = (row["label"] as? String) ?? ""
            if rowMemo != memo {
                return byteLessThan(Data(memo.utf8), Data(rowMemo.utf8))
            }
            return byteLessThan(Data(label.utf8), Data(rowLabel.utf8))
        }
    }

    private func filteredMarkers(
        _ rows: [[String: Any]],
        query: [String: String]
    ) -> [[String: Any]] {
        guard !ignoreCursor,
              let cursor = query["source_sha256"],
              cursor.hasPrefix("gt.") else { return rows }
        let raw = String(cursor.dropFirst(3))
        return rows.filter { row in
            byteLessThan(Data(raw.utf8), Data(((row["source_sha256"] as? String) ?? "").utf8))
        }
    }
}
