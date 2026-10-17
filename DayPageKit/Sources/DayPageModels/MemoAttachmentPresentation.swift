import Foundation

// MARK: - MemoAttachmentPresentation

/// Read-only presentation rules for memos whose body is ONLY the importer's
/// generated media placeholder set (`scripts/import_flomo.py` emits one
/// `[Photo attachment: NAME](FILE)` style line per attachment, in attachment
/// order, exactly when the original body was empty).
///
/// The generated body is internal plumbing — it renders as a raw asset path
/// plus the actual photo/audio/file row. This type hides that body for
/// read-only presentation ONLY, never for persistence: the memo value, editor,
/// copy actions, exports and the wire format keep `memo.body` byte-for-byte.
///
/// ## Attachment-path correspondence
/// The body keeps the ORIGINAL generated target
/// `raw/assets/flomo/<64 ASCII lowercase-hex>.<ext>`, but a downloaded v2
/// attachment may live at the production sync mapping
/// `raw/assets/sync/<same SHA>-<sanitized original name>`. The current
/// `attachment.file` therefore matches the original target byte-for-byte, or
/// exactly that sync mapping byte-for-byte — never a loose hash prefix or an
/// arbitrary suffix. Every comparison here is UTF-8 byte equality, so Swift
/// canonical Unicode equivalence can never equate two different filenames.
///
/// Everything here is deliberately exact and fail-closed. A body is treated as
/// the generated media-only placeholder set only when the WHOLE trimmed body
/// is exactly one matching placeholder line per current attachment, in order,
/// with the exact label/kind and the exact target correspondence above. Any
/// prose, code/fence content, missing/wrong/extra/duplicated/mismatched line,
/// unsafe or non-canonical path, or other uncertainty preserves the body
/// unchanged. There is NO general Markdown stripping here.
public enum MemoAttachmentPresentation {

    // MARK: Public API

    /// The read-only display body for a memo.
    ///
    /// Returns `memo.body` UNCHANGED unless the whole trimmed body is exactly
    /// the generated media-only placeholder set for ALL current attachments —
    /// only that exact case yields the empty display string. Media rows are
    /// rendered by their own views, so an empty display body never hides the
    /// attachments themselves.
    public static func displayBody(for memo: Memo) -> String {
        guard !memo.attachments.isEmpty else { return memo.body }
        let trimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return memo.body }
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count == memo.attachments.count else { return memo.body }
        for (line, attachment) in zip(lines, memo.attachments) {
            guard isGeneratedPlaceholderLine(line, for: attachment) else { return memo.body }
        }
        return ""
    }

    // MARK: Generated placeholder shape

    /// Labels used by the importer's generated link body. Any other kind (or
    /// unknown kind) can never be a generated placeholder.
    static func generatedLabel(forKind kind: String) -> String? {
        switch kind {
        case "photo": return "Photo"
        case "audio": return "Audio"
        case "file": return "File"
        default: return nil
        }
    }

    /// Importer-supported extensions per kind (`_EXT_KIND` in
    /// `scripts/import_flomo.py`): png/jpeg/jpg are photos, m4a/aac audio,
    /// mov is always a file — never a photo.
    static func generatedExtensions(forKind kind: String) -> [String]? {
        switch kind {
        case "photo": return ["png", "jpg", "jpeg"]
        case "audio": return ["m4a", "aac"]
        case "file": return ["mov"]
        default: return nil
        }
    }

    /// One parsed generated placeholder line: `[LABEL attachment: NAME](TARGET)`
    /// with `TARGET` the strict original `raw/assets/flomo/<sha>.<ext>`.
    struct GeneratedPlaceholderLine {
        /// Validated original basename (accepted bounded subset).
        let name: String
        /// Exactly 64 ASCII lowercase hex BYTES (`0x30...0x39` / `0x61...0x66`).
        let shaBytes: [UInt8]
        /// Original target bytes: `raw/assets/flomo/<sha>.<ext>`.
        let originalTargetBytes: [UInt8]
    }

    /// Parses one whole generated placeholder line at UTF-8 byte precision.
    /// `nil` for anything uncertain: wrong label prefix, empty or unbounded
    /// basename, non-canonical target, alias spellings, trailing text.
    static func parseGeneratedPlaceholderLine(
        _ line: String, label: String, kind: String
    ) -> GeneratedPlaceholderLine? {
        guard let extensions = generatedExtensions(forKind: kind) else { return nil }
        let lineBytes = [UInt8](line.utf8)
        let prefixBytes = [UInt8]("[\(label) attachment: ".utf8)
        // Closing ")" plus at least one name byte and one target byte.
        guard lineBytes.count > prefixBytes.count + 2,
              lineBytes.last == UInt8(ascii: ")"),
              [UInt8](lineBytes.prefix(prefixBytes.count)) == prefixBytes
        else { return nil }

        // The separator `](` is the LAST one in the line: the canonical target
        // after it contains no `](`, so a name may legitimately contain brackets.
        var separator = -1
        var index = lineBytes.count - 2
        while index >= prefixBytes.count {
            if lineBytes[index] == UInt8(ascii: "]"),
               lineBytes[index + 1] == UInt8(ascii: "(") {
                separator = index
                break
            }
            index -= 1
        }
        guard separator >= prefixBytes.count else { return nil }

        let nameBytes = Array(lineBytes[prefixBytes.count ..< separator])
        let targetBytes = Array(lineBytes[(separator + 2) ..< (lineBytes.count - 1)])
        guard let name = boundedOriginalFilename(nameBytes) else { return nil }
        guard let shaBytes = canonicalFlomoTarget(targetBytes, extensions: extensions) else { return nil }
        return GeneratedPlaceholderLine(
            name: name,
            shaBytes: shaBytes,
            originalTargetBytes: targetBytes
        )
    }

    /// One generated placeholder line for this exact attachment.
    ///
    /// The label and target are parsed strictly; the current `attachment.file`
    /// must then be byte-identical to the parsed original target OR to the
    /// production sync mapping of that same SHA and name
    /// (`raw/assets/sync/<sha>-<String(name.prefix(255))>` — the sanitizer's
    /// exact output on this accepted basename subset).
    static func isGeneratedPlaceholderLine(_ line: String, for attachment: Memo.Attachment) -> Bool {
        guard let label = generatedLabel(forKind: attachment.kind) else { return false }
        guard let parsed = parseGeneratedPlaceholderLine(line, label: label, kind: attachment.kind) else { return false }
        let fileBytes = [UInt8](attachment.file.utf8)
        if fileBytes == parsed.originalTargetBytes { return true }
        return fileBytes == syncMappedTargetBytes(for: parsed)
    }

    /// `raw/assets/sync/<same SHA>-<String(name.prefix(255))>` — the production
    /// deterministic download path (`AttachmentFileInspector.sanitizedFilename`
    /// is exactly `String(name.prefix(255))` on the accepted basename subset,
    /// 255 Swift Characters).
    static func syncMappedTargetBytes(for parsed: GeneratedPlaceholderLine) -> [UInt8] {
        let truncatedName = String(parsed.name.prefix(255))
        return [UInt8]("raw/assets/sync/".utf8)
            + parsed.shaBytes
            + [UInt8]("-".utf8)
            + [UInt8](truncatedName.utf8)
    }

    // MARK: Byte-level guards

    /// Exactly 64 ASCII UTF-8 hex bytes, lowercase only. Grapheme look-alikes
    /// (e.g. `a` + U+FE0F) are rejected because every BYTE must be a hex digit.
    static func isLowercaseHex64Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    /// Strict original target: `raw/assets/flomo/<64 ASCII lowercase-hex>.<ext>`
    /// with an importer-supported extension for this exact kind. The exact
    /// shape rejects traversal, absolute, remote, query-string and
    /// percent-decoded alias forms outright. Returns the SHA bytes.
    static func canonicalFlomoTarget(_ bytes: [UInt8], extensions: [String]) -> [UInt8]? {
        let prefix = [UInt8]("raw/assets/flomo/".utf8)
        guard bytes.count > prefix.count + 64 + 1,
              [UInt8](bytes.prefix(prefix.count)) == prefix
        else { return nil }
        let shaBytes = Array(bytes[prefix.count ..< prefix.count + 64])
        guard isLowercaseHex64Bytes(shaBytes),
              bytes[prefix.count + 64] == UInt8(ascii: ".")
        else { return nil }
        let extBytes = Array(bytes[(prefix.count + 64 + 1)...])
        guard extensions.contains(where: { [UInt8]($0.utf8) == extBytes }) else { return nil }
        return shaBytes
    }

    /// Bounded acceptance for the original filename the importer preserved as
    /// link text: a plain basename. Spaces, Unicode, parentheses and brackets
    /// are legitimate filename characters and must match; path separators,
    /// control characters, invalid UTF-8 and edge whitespace make the line
    /// uncertain. Returned as the exact scalar spelling of the input bytes.
    static func boundedOriginalFilename(_ nameBytes: [UInt8]) -> String? {
        guard !nameBytes.isEmpty else { return nil }
        for byte in nameBytes {
            if byte < 0x20 || byte == 0x7F || byte == 0 { return nil }
            if byte == UInt8(ascii: "/") || byte == UInt8(ascii: "\\") { return nil }
        }
        let name = String(decoding: nameBytes, as: UTF8.self)
        // Byte round-trip rejects invalid UTF-8; the trim comparison rejects
        // edge whitespace without canonical-equivalence leniency.
        guard [UInt8](name.utf8) == nameBytes else { return nil }
        guard name.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        guard [UInt8](name.trimmingCharacters(in: .whitespacesAndNewlines).utf8) == nameBytes else { return nil }
        return name
    }
}
