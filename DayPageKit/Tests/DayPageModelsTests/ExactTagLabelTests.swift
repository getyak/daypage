// ExactTagLabelTests.swift — #884 T01/T02 exact-byte label acceptance.
//
// Synthetic fixtures only. No real labels, vaults, network or credentials.

import XCTest
@testable import DayPageModels

final class ExactTagLabelTests: XCTestCase {

    // MARK: - T01 exact bytes

    /// ["#é"(precomposed), "#é"(decomposed), "#Case", "#case", "#a", "#a/b",
    /// "#a,b", "#a+b", "#a b", "#a%_"] keep TEN distinct identities; the two
    /// visually-identical "#é" spellings never merge; " #bad" and "#" are
    /// rejected.
    func testExactBytesIdentityAndValidation() throws {
        let precomposed = ExactTagLabel("#\u{E9}")
        let decomposed = ExactTagLabel("#e\u{301}")
        let labels = [
            try XCTUnwrap(precomposed),
            try XCTUnwrap(decomposed),
            try XCTUnwrap(ExactTagLabel("#Case")),
            try XCTUnwrap(ExactTagLabel("#case")),
            try XCTUnwrap(ExactTagLabel("#a")),
            try XCTUnwrap(ExactTagLabel("#a/b")),
            try XCTUnwrap(ExactTagLabel("#a,b")),
            try XCTUnwrap(ExactTagLabel("#a+b")),
            try XCTUnwrap(ExactTagLabel("#a b")),
            try XCTUnwrap(ExactTagLabel("#a%_"))
        ]

        // Ten inputs → ten distinct byte identities.
        XCTAssertEqual(Set(labels.map(\.identity)).count, 10)

        // Fixture identity vectors: exact UTF-8 hex, not String identity.
        XCTAssertEqual(try XCTUnwrap(precomposed).identity, "23c3a9")
        XCTAssertEqual(try XCTUnwrap(decomposed).identity, "2365cc81")
        XCTAssertNotEqual(try XCTUnwrap(precomposed), try XCTUnwrap(decomposed))

        // Swift canonical equivalence still holds for the raw strings — which
        // is EXACTLY why the label type must not merge them.
        XCTAssertEqual(try XCTUnwrap(precomposed).text, try XCTUnwrap(decomposed).text)
        XCTAssertEqual(Set(labels.map(\.identity)).count, Set(labels).count)

        // Rejected: leading space and lone "#".
        XCTAssertNil(ExactTagLabel(" #bad"))
        XCTAssertNil(ExactTagLabel("#"))
    }

    /// "#a/b" is one exact label: it never matches "#a" and "#a,b" is never
    /// split on the comma.
    func testSlashAndCommaLabelsAreNeverSplitOrMatchedAsParents() throws {
        let parent = try XCTUnwrap(ExactTagLabel("#a"))
        let slash = try XCTUnwrap(ExactTagLabel("#a/b"))
        let comma = try XCTUnwrap(ExactTagLabel("#a,b"))

        XCTAssertNotEqual(parent, slash)
        XCTAssertNotEqual(parent, comma)
        XCTAssertNotEqual(slash, comma)

        // Exact-membership semantics used by projection views: an exact label
        // lookup only ever matches the identical bytes.
        let linked = [slash, comma]
        XCTAssertEqual(linked.filter { $0 == parent }, [])
        XCTAssertEqual(linked.filter { $0 == slash }, [slash])
        XCTAssertEqual(linked.filter { $0 == comma }, [comma])
    }

    /// Ordering is total over UTF-8 bytes and consistent with the tables'
    /// `COLLATE "C"` byte ordering (case-sensitive: "#Case" < "#case").
    func testOrderingIsUTF8ByteOrder() throws {
        let labels = try ["#Case", "#a", "#a b", "#a/b", "#case"].map {
            try XCTUnwrap(ExactTagLabel($0))
        }
        XCTAssertEqual(labels.sorted(), labels)
        let caseLabel = try XCTUnwrap(ExactTagLabel("#Case"))
        let aLabel = try XCTUnwrap(ExactTagLabel("#a"))
        let slashLabel = try XCTUnwrap(ExactTagLabel("#a/b"))
        XCTAssertTrue(caseLabel < aLabel)
        XCTAssertTrue(aLabel < slashLabel)
    }

    // MARK: - T02 byte-length limits and control rejection

    func testUTF8ByteLengthBounds() throws {
        // "#"+1023 ASCII = 1024 bytes → valid; one more byte → invalid.
        let atLimit = try XCTUnwrap(ExactTagLabel("#" + String(repeating: "a", count: 1023)))
        XCTAssertEqual(atLimit.utf8.count, 1024)
        XCTAssertNil(ExactTagLabel("#" + String(repeating: "a", count: 1024)))

        // Emoji count by UTF-8 bytes (4 each), not characters.
        XCTAssertNotNil(ExactTagLabel("#\u{1F389}"))
        let quarter = try XCTUnwrap(ExactTagLabel("#" + String(repeating: "\u{1F389}", count: 255)))
        XCTAssertEqual(quarter.utf8.count, 1 + 255 * 4)
        XCTAssertNil(ExactTagLabel("#" + String(repeating: "\u{1F389}", count: 256)))
        XCTAssertNil(ExactTagLabel("#" + String(repeating: "a", count: 1022) + "\u{1F389}"))
    }

    func testEveryASCIIDelAndControlByteIsRejected() {
        for scalar in UInt32(0x00)...UInt32(0x1F) {
            let raw = "#a" + String(UnicodeScalar(scalar)!)
            XCTAssertNil(ExactTagLabel(raw), "U+\(String(scalar, radix: 16)) must be rejected")
        }
        XCTAssertNil(ExactTagLabel("#a\u{7F}"))
        XCTAssertNil(ExactTagLabel("\u{7F}#a"))
    }

    /// Spaces, U+200B and non-ASCII keep their exact bytes: no trim, no
    /// casefold, no normalization — and the cache round-trip preserves the
    /// same UTF-8 bytes.
    func testWhitespaceZeroWidthAndNonASCIIStayByteExact() throws {
        let fixtures = [
            "#a b",
            "#a\u{200B}b",
            "#标签/子",
            "#a\u{E9}b",
            "#a e\u{301}b",
            "#\u{1F389}emoji",
            "#a,b;c",
            "#a+b",
            "#a%_"
        ]
        for raw in fixtures {
            let label = try XCTUnwrap(ExactTagLabel(raw), "fixture \(raw.unicodeScalars.map { String(format: "%04X", $0.value) })")
            XCTAssertEqual(label.text, raw)
            XCTAssertEqual(Data(raw.utf8), label.utf8)

            // JSON cache round trip (single-value string form) is byte-exact.
            let encoded = try JSONEncoder().encode(label)
            let decoded = try JSONDecoder().decode(ExactTagLabel.self, from: encoded)
            XCTAssertEqual(decoded, label)
            XCTAssertEqual(decoded.utf8, label.utf8)
            XCTAssertEqual(decoded.identity, label.identity)
        }

        // Trimming/normalizing inputs are NOT repaired — leading/trailing
        // spaces outside the label shape stay preserved byte-exact (no trim):
        // " #a" is invalid only because it does not start with '#'.
        XCTAssertNil(ExactTagLabel(" #a"))
        XCTAssertEqual(ExactTagLabel("#a ")?.text, "#a ")
        XCTAssertEqual(ExactTagLabel("#a ")?.utf8, Data("#a ".utf8))
        XCTAssertEqual(ExactTagLabel("#A")?.text, "#A")
        XCTAssertNotEqual(ExactTagLabel("#A"), ExactTagLabel("#a"))
    }

    func testDecodingRejectsInvalidLabelsInsteadOfRepairing() throws {
        let quoted = Data("\" #bad\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExactTagLabel.self, from: quoted))
        let lone = Data("\"#\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ExactTagLabel.self, from: lone))
    }
}
