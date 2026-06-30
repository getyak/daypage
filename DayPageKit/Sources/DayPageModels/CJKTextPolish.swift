import Foundation

// MARK: - CJKTextPolish

/// Pure render-layer string polish for CJK/Latin mixed text.
/// Does NOT modify persisted vault content — apply only at display time.
public enum CJKTextPolish {

    // MARK: - Public API

    /// Returns a typographically polished copy of `raw`.
    /// Rules applied (in order):
    /// 1. Collapse doubled punctuation: Chinese-then-ASCII → Chinese form
    /// 2. Insert U+200A (hair space) between adjacent CJK and Latin characters
    public static func polish(_ raw: String) -> String {
        var s = collapsePunctuation(raw)
        s = insertHairSpaces(s)
        return s
    }

    // MARK: - Rule 1: Punctuation collapse

    /// Chinese-then-ASCII punctuation pairs → Chinese form.
    /// Supported: period, comma, exclamation, question mark.
    private static let punctuationPairs: [(String, String)] = [
        ("。.", "。"),
        (".。", "。"),
        ("，,", "，"),
        (",，", "，"),
        ("！!", "！"),
        ("!！", "！"),
        ("？?", "？"),
        ("?？", "？"),
    ]

    private static func collapsePunctuation(_ s: String) -> String {
        var result = s
        for (pair, replacement) in punctuationPairs {
            result = result.replacingOccurrences(of: pair, with: replacement)
        }
        return result
    }

    // MARK: - Rule 2: Hair-space insertion

    private static let hairSpace: Character = "\u{200A}"
    private static let fullWidthSpace: Character = "\u{3000}"

    /// Returns true if the scalar is in a CJK block.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs (main)
             0x3400...0x4DBF,   // CJK Extension A
             0x20000...0x2A6DF, // CJK Extension B
             0x2A700...0x2CEAF, // CJK Extensions C–F
             0x2CEB0...0x2EBEF, // CJK Extension G
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x3000...0x303F,   // CJK Symbols and Punctuation
             0xFF00...0xFFEF,   // Halfwidth and Fullwidth Forms
             0x3040...0x30FF,   // Hiragana + Katakana
             0x31F0...0x31FF,   // Katakana Phonetic Extensions
             0xAC00...0xD7AF:   // Hangul Syllables
            return true
        default:
            return false
        }
    }

    /// Returns true if the scalar is a Latin letter or ASCII digit (not punctuation).
    private static func isLatinAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A,  // A–Z
             0x0061...0x007A,  // a–z
             0x0030...0x0039,  // 0–9
             0x00C0...0x024F:  // Latin Extended
            return true
        default:
            return false
        }
    }

    private static func insertHairSpaces(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1 else { return s }

        var result: [Character] = []
        result.reserveCapacity(chars.count + chars.count / 4)

        for (i, ch) in chars.enumerated() {
            result.append(ch)
            guard i + 1 < chars.count else { break }

            let next = chars[i + 1]

            // Never insert adjacent to full-width space
            if ch == fullWidthSpace || next == fullWidthSpace { continue }

            guard
                let lScalar = ch.unicodeScalars.first,
                let rScalar = next.unicodeScalars.first
            else { continue }

            let lCJK = isCJK(lScalar)
            let rCJK = isCJK(rScalar)
            let lLatin = isLatinAlphanumeric(lScalar)
            let rLatin = isLatinAlphanumeric(rScalar)

            // Insert hair space only between CJK ↔ Latin (not punctuation)
            if (lCJK && rLatin) || (lLatin && rCJK) {
                result.append(hairSpace)
            }
        }

        return String(result)
    }
}
