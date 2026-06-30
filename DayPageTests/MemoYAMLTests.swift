import Testing
import Foundation
import DayPageModels
import DayPageServices
@testable import DayPage

/// Focused round-trip tests for `Memo.yamlQuote` / `Memo.unquote` —
/// guards against the "literal `\n` collapses into a newline" class of bugs
/// that the chained `replacingOccurrences` implementation was prone to.
@Suite("MemoYAMLTests")
struct MemoYAMLTests {

    // MARK: - Direct quote/unquote round-trips

    @Test func plain_ascii_roundTrips() {
        let input = "hello world"
        let quoted = Memo.yamlQuote(input)
        #expect(quoted == "\"hello world\"")
        #expect(Memo.yamlUnquote(quoted) == input)
    }

    @Test func embedded_double_quote_roundTrips() {
        // User input contains a literal "
        let input = "she said \"hi\""
        let quoted = Memo.yamlQuote(input)
        // Quoted form must contain \" (backslash + quote), not a bare quote
        #expect(quoted.contains("\\\""))
        // Every `"` inside the inner body MUST be backslash-prefixed — no bare
        // double quote may appear or YAML would mis-parse the scalar.
        let inner = String(quoted.dropFirst().dropLast())
        var i = inner.startIndex
        while let next = inner[i...].firstIndex(of: "\"") {
            // The character immediately before must be a backslash.
            #expect(next > inner.startIndex && inner[inner.index(before: next)] == "\\",
                    "bare \" found at offset \(inner.distance(from: inner.startIndex, to: next))")
            i = inner.index(after: next)
        }
        #expect(Memo.yamlUnquote(quoted) == input)
    }

    @Test func literal_backslash_n_roundTrips() {
        // User typed two characters: backslash + n. Must NOT decode to a newline.
        let input = "before\\nafter"
        let quoted = Memo.yamlQuote(input)
        // Quoted: each \ becomes \\, so we expect \\n (four chars: \\ + n)
        #expect(quoted == "\"before\\\\nafter\"")
        #expect(Memo.yamlUnquote(quoted) == input)
        // Explicit: result has no real newline
        #expect(!Memo.yamlUnquote(quoted).contains("\n"))
    }

    @Test func actual_newline_roundTrips_through_yaml_single_line() {
        let input = "line one\nline two"
        let quoted = Memo.yamlQuote(input)
        // Front-matter must stay on one line — no raw \n inside the scalar.
        #expect(!quoted.contains("\n"))
        #expect(quoted == "\"line one\\nline two\"")
        #expect(Memo.yamlUnquote(quoted) == input)
    }

    @Test func doubled_backslash_roundTrips() {
        // User typed \\ — two backslashes.
        let input = "C:\\\\path"
        let quoted = Memo.yamlQuote(input)
        // Each \ → \\, so 2 backslashes → 4 backslashes inside the quoted form.
        #expect(quoted == "\"C:\\\\\\\\path\"")
        #expect(Memo.yamlUnquote(quoted) == input)
    }

    @Test func emoji_with_quote_and_backslash_n_roundTrips() {
        // Mixed: Chinese + emoji + literal " + literal \n
        let input = "今天 ☕️ 写了 \"hello\\nworld\""
        let quoted = Memo.yamlQuote(input)
        #expect(!quoted.contains("\n"))
        #expect(Memo.yamlUnquote(quoted) == input)
    }

    @Test func chinese_emoji_quote_combo_roundTrips() {
        let cases = [
            "纯中文测试",
            "中文 + emoji 🌸 + 引号 \" 测试",
            "tab\there\tinside",
            "carriage\rreturn",
            "mix\n\t\"\\all",
            "",                                 // empty string
            "\"",                               // single quote char
            "\\",                               // single backslash
            "\\\"",                             // backslash + quote
            "💀🍣🦊",                            // emoji-only
        ]
        for input in cases {
            let quoted = Memo.yamlQuote(input)
            // No raw newline / CR / tab leaks into the scalar.
            #expect(!quoted.contains("\n"), "leaked newline for: \(input.debugDescription)")
            #expect(!quoted.contains("\r"), "leaked CR for: \(input.debugDescription)")
            #expect(!quoted.contains("\t"), "leaked tab for: \(input.debugDescription)")
            #expect(Memo.yamlUnquote(quoted) == input, "round-trip failed for: \(input.debugDescription)")
        }
    }

    // MARK: - End-to-end Memo round-trip carrying the tricky strings

    private var fixedDate: Date {
        ISO8601DateFormatter.memo.date(from: "2026-06-22T10:00:00.123Z")!
    }

    @Test func full_memo_roundTrip_with_quote_and_literal_backslash_n() {
        // Carry the tricky strings through full toMarkdown / fromMarkdown.
        let memo = Memo(
            id: UUID(),
            type: .voice,
            created: fixedDate,
            location: Memo.Location(name: "Café \"Le Monde\" \\n Paris", lat: 0, lng: 0),
            weather: "Sunny \"warm\" \\n line",
            attachments: [
                Memo.Attachment(
                    file: "audio.m4a",
                    kind: "audio",
                    duration: 5.0,
                    transcript: "he said \"hi\" and typed \\n literally",
                    transcriptionStatus: .done
                )
            ],
            mood: "happy\\\"weird\"",
            entityMentions: ["Alice \"the\\nGreat\""],
            body: "ok"
        )
        guard let parsed = Memo.fromMarkdown(memo.toMarkdown()) else {
            Issue.record("fromMarkdown returned nil")
            return
        }
        #expect(parsed == memo)
    }
}
