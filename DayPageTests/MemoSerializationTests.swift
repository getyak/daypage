import Testing
import Foundation
@testable import DayPage

@Suite("MemoSerializationTests")
struct MemoSerializationTests {

    private func assertRoundTrip(_ memo: Memo, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let parsed = Memo.fromMarkdown(memo.toMarkdown()) else {
            Issue.record("fromMarkdown returned nil", sourceLocation: sourceLocation)
            return
        }
        #expect(parsed == memo, sourceLocation: sourceLocation)
    }

    // Fixed date with fractional seconds so parse round-trips exactly.
    private var fixedDate: Date {
        ISO8601DateFormatter.memo.date(from: "2026-06-02T10:00:00.123Z")!
    }

    // MARK: - Cases

    @Test func minimal_textMemo() {
        let memo = Memo(id: UUID(), type: .text, created: fixedDate, body: "Hello world")
        assertRoundTrip(memo)
    }

    @Test func specialChars_inMoodWeatherLocationTranscript() {
        let memo = Memo(
            id: UUID(),
            type: .voice,
            created: fixedDate,
            location: Memo.Location(name: "Café \"Le Monde\" \\ Paris", lat: 48.8566, lng: 2.3522),
            weather: "Sunny ☀️ \"warm\"",
            mood: "happy\\excited \"joy\"",
            attachments: [
                Memo.Attachment(
                    file: "audio.m4a",
                    kind: "audio",
                    duration: 12.5,
                    transcript: "He said \"hello\" and \\ goodbye",
                    transcriptionStatus: .done
                )
            ],
            body: "A normal body"
        )
        assertRoundTrip(memo)
    }

    @Test func nonEmpty_entityMentions_and_photoAttachment() {
        let memo = Memo(
            id: UUID(),
            type: .photo,
            created: fixedDate,
            attachments: [
                Memo.Attachment(file: "img_001.jpg", kind: "photo"),
                Memo.Attachment(
                    file: "voice.m4a",
                    kind: "audio",
                    duration: 30.0,
                    transcript: "transcript text",
                    transcriptionStatus: .done
                )
            ],
            entityMentions: ["Alice", "Project Phoenix", "Tokyo"],
            body: "Met Alice today."
        )
        assertRoundTrip(memo)
    }

    @Test func pinnedAt_roundTrips() {
        let pinDate = ISO8601DateFormatter.memo.date(from: "2026-06-01T08:30:00.000Z")!
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            pinnedAt: pinDate,
            body: "Pinned memo"
        )
        assertRoundTrip(memo)
    }

    @Test func body_startingWithTripleDash_and_blankLine() {
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            body: "---\nThis starts with a separator\n\nAnd has a blank line"
        )
        assertRoundTrip(memo)
    }

    // MARK: - Horizontal rule / "---" body tests

    @Test func body_withHorizontalRuleAndSurroundingText_roundTrips() {
        // A body whose content contains the exact sequence "\n\n---\n\n" must
        // survive a full toMarkdown -> fromMarkdown round-trip unchanged.
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            body: "before\n\n---\n\nafter"
        )
        assertRoundTrip(memo)
    }

    @Test func body_firstLineIsTripleDash_roundTrips() {
        // A body whose very first content line is "---" must not be consumed as
        // a front-matter delimiter or silently dropped.
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            body: "---\nThis starts with a horizontal rule"
        )
        assertRoundTrip(memo)
    }

    @Test func body_solelyTripleDash_roundTrips() {
        // Edge case: the entire body is a single "---" line.
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            body: "---"
        )
        assertRoundTrip(memo)
    }

    // MARK: - Newline-in-front-matter tests (data-loss regression)

    @Test func transcript_with_embedded_newlines_roundTrips() {
        let multiLineTranscript = "Line one.\nLine two.\n\nPara two"
        let memo = Memo(
            id: UUID(),
            type: .voice,
            created: fixedDate,
            attachments: [
                Memo.Attachment(
                    file: "voice.m4a",
                    kind: "audio",
                    duration: 8.0,
                    transcript: multiLineTranscript,
                    transcriptionStatus: .done
                )
            ],
            body: "Voice memo"
        )
        assertRoundTrip(memo)

        // The serialized front-matter must contain exactly one "transcript:" line —
        // no raw newline may appear inside the quoted YAML scalar.
        let md = memo.toMarkdown()
        let transcriptLineCount = md.components(separatedBy: "\n").filter { $0.contains("transcript:") }.count
        #expect(transcriptLineCount == 1)
    }

    @Test func mood_with_embedded_newline_roundTrips() {
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            mood: "happy\nexcited",
            body: "Mood test"
        )
        assertRoundTrip(memo)
    }

    @Test func locationName_with_embedded_newline_roundTrips() {
        let memo = Memo(
            id: UUID(),
            type: .location,
            created: fixedDate,
            location: Memo.Location(name: "Coffee\nShop", lat: 35.6762, lng: 139.6503),
            body: "Location test"
        )
        assertRoundTrip(memo)
    }

    @Test func entityMention_with_embedded_newline_roundTrips() {
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            entityMentions: ["Alice\nBob", "Project\nPhoenix"],
            body: "Entity test"
        )
        assertRoundTrip(memo)
    }

    @Test func newlineAndTab_inTranscriptAndMood_roundTrip() {
        let memo = Memo(
            id: UUID(),
            type: .voice,
            created: fixedDate,
            mood: "happy\nexcited",
            attachments: [
                Memo.Attachment(
                    file: "audio.m4a",
                    kind: "audio",
                    duration: 5.0,
                    transcript: "line one\nline two\ttabbed",
                    transcriptionStatus: .done
                )
            ],
            body: "Body text"
        )
        assertRoundTrip(memo)
        // Literal backslash-n in source must NOT become a newline on round-trip.
        let literalBackslashN = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            mood: "has \\n literal",
            body: "ok"
        )
        assertRoundTrip(literalBackslashN)
    }

    @Test func explicit_empty_entityMentions_and_attachments() {
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: fixedDate,
            attachments: [],
            entityMentions: [],
            body: "Empty collections"
        )
        assertRoundTrip(memo)
        // Verify the serialized form uses the explicit [] notation.
        let md = memo.toMarkdown()
        #expect(md.contains("entity_mentions: []"))
        #expect(md.contains("attachments: []"))
    }
}
