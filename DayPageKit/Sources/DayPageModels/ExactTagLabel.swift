// ExactTagLabel.swift — #884 exact account tag labels (native reading batch).
//
// An imported tag label keeps its ORIGINAL text exactly as supplied: leading
// '#', case, commas, slashes, spaces and every Unicode scalar. There is no
// trimming, normalization, case folding, comma/splitting on '/' and no
// invented parent labels. Two Swift `String` values that are canonical
// equivalents (e.g. "é" U+00E9 vs "e" + U+0301) are DIFFERENT labels here —
// equality, hashing and ordering are defined over the exact UTF-8 bytes.
//
// Validation mirrors `0036_account_tag_imports.sql`:
//   - the label starts with '#',
//   - total length is 2...1024 UTF-8 bytes,
//   - no ASCII control (U+0000...U+001F) and no U+007F anywhere.
//
// The stable UI identity is the lowercase hex of those bytes (never the
// `String` value itself) so SwiftUI `ForEach`/selection identifiers cannot
// collapse canonically-equivalent spellings.

import Foundation

public struct ExactTagLabel: Sendable {
    /// The original label text, byte-preserving.
    public let text: String

    /// Exact UTF-8 bytes of `text`. The canonical identity of the label.
    public let utf8: Data

    /// Stable, non-`String` UI identity: lowercase hex of `utf8`.
    public let identity: String

    /// Total UTF-8 byte length bounds (including the leading '#').
    public static let minimumUTF8Bytes = 2
    public static let maximumUTF8Bytes = 1024

    /// Validates and wraps `raw` exactly as given. Returns nil when the value
    /// is not a legal label — no repair, trimming or normalization attempt.
    public init?(_ raw: String) {
        let bytes = Data(raw.utf8)
        guard bytes.count >= Self.minimumUTF8Bytes,
              bytes.count <= Self.maximumUTF8Bytes,
              raw.utf8.first == UInt8(ascii: "#") else {
            return nil
        }
        for byte in bytes {
            // ASCII controls (0x00...0x1F) and DEL (0x7F) are rejected. Every
            // other byte — including continuation bytes of non-ASCII scalars —
            // is preserved verbatim.
            if byte <= 0x1F || byte == 0x7F {
                return nil
            }
        }
        self.text = raw
        self.utf8 = bytes
        self.identity = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates `bytes` (used by cache decoders that already hold raw bytes).
    public init?(utf8 bytes: Data) {
        guard let string = String(data: bytes, encoding: .utf8) else { return nil }
        self.init(string)
    }
}

// MARK: - UTF-8 byte identity

extension ExactTagLabel: Equatable {
    /// Byte equality — canonical-equivalent Swift strings are NOT equal here.
    public static func == (lhs: ExactTagLabel, rhs: ExactTagLabel) -> Bool {
        lhs.utf8 == rhs.utf8
    }
}

extension ExactTagLabel: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(utf8)
    }
}

extension ExactTagLabel: Comparable {
    /// Total order over the exact UTF-8 bytes (lexicographic). Matches the
    /// `COLLATE "C"` byte ordering the account-tag tables use for `label`.
    public static func < (lhs: ExactTagLabel, rhs: ExactTagLabel) -> Bool {
        byteLessThan(lhs.utf8, rhs.utf8)
    }
}

extension ExactTagLabel: Codable {
    /// The cache stores the ORIGINAL string; decoding re-validates byte-exact
    /// and rejects anything the writer could not have produced.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let label = ExactTagLabel(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid exact tag label"
            )
        }
        self = label
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// MARK: - Byte comparators (shared with cache validation)

/// Lexicographic comparison of two byte sequences (shortest-prefix first).
/// Public so cache/reader validation and tests share ONE ordering definition.
public func byteLessThan(_ lhs: Data, _ rhs: Data) -> Bool {
    var a = lhs.makeIterator()
    var b = rhs.makeIterator()
    while true {
        switch (a.next(), b.next()) {
        case (nil, nil):
            return false
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (x?, y?):
            if x != y { return x < y }
        }
    }
}
