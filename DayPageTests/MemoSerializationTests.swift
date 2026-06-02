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
