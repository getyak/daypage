import Testing
import Foundation
import DayPageModels
import DayPageServices
@testable import DayPage

// MARK: - DailyPageParserEvidenceTests
//
// Issue #4 · 证据链 verification.
//
// Goal:
//   Every insight paragraph in a compiled daily.md must be traceable back
//   to the raw memos that fed it. CompilationService emits `[^m:<uuid>]`
//   footnote markers at the end of each narrative paragraph, and
//   DailyPageParser must (a) collect them per section and (b) strip them
//   from the visible body so the reader never sees the raw marker syntax.
//
// These tests exercise the parser directly (no LLM round-trip, no I/O),
// so they run in <10ms and belong in CI's fast unit tier.

@Suite("DailyPageParser · Issue #4 evidence markers")
struct DailyPageParserEvidenceTests {

    /// Baseline: a section with two memo markers surfaces both UUIDs
    /// (deduped + insertion-ordered) and hides the markers from body prose.
    @Test func morningSectionExtractsBothCitedMemos() {
        let m1 = UUID()
        let m2 = UUID()
        let md = """
        ---
        type: daily
        date: 2026-07-03
        source: sample
        ---

        # 2026-07-03

        ## MORNING
        雨天从咖啡店开始。[^m:\(m1.uuidString)][^m:\(m2.uuidString)]

        ## AFTERNOON
        午间冒出新工作流念头。[^m:\(m1.uuidString)]
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")

        let morning = model.sections.first { $0.title == "MORNING" }
        #expect(morning != nil)
        #expect(morning?.evidenceMemoIDs == [m1, m2])
        #expect(morning?.body.contains("雨天从咖啡店开始") == true)
        #expect(morning?.body.contains("[^m:") == false)

        let afternoon = model.sections.first { $0.title == "AFTERNOON" }
        #expect(afternoon?.evidenceMemoIDs == [m1])
    }

    /// Legacy daily.md written before Issue #4 (no markers anywhere) must
    /// still parse cleanly with `evidenceMemoIDs == []`. Graceful
    /// degradation is a hard requirement — we do not want to hide old
    /// dailies just because they lack the new markers.
    @Test func legacyDailyDegradesToEmptyEvidence() {
        let md = """
        ---
        type: daily
        date: 2025-01-15
        ---

        # 2025-01-15

        ## MORNING
        晨间散步，风有点凉。

        ## AFTERNOON
        约稿完成第一版。
        """

        let model = DailyPageParser.parse(content: md, dateString: "2025-01-15")

        for section in model.sections {
            #expect(section.evidenceMemoIDs.isEmpty)
            #expect(!section.body.isEmpty)
        }
    }

    /// A single memo repeated across markers in the same paragraph must be
    /// deduped — the "引用 N 条" chip counts *distinct* memos, not marker
    /// instances.
    @Test func duplicateMarkersAreDeduped() {
        let m1 = UUID()
        let md = """
        ---
        type: daily
        date: 2026-07-03
        ---

        # 2026-07-03

        ## EVENING
        今晚重读了三次那条备忘。[^m:\(m1.uuidString)][^m:\(m1.uuidString)][^m:\(m1.uuidString)]
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")
        let evening = model.sections.first { $0.title == "EVENING" }
        #expect(evening?.evidenceMemoIDs == [m1])
    }

    /// A malformed marker (non-UUID payload) must be silently dropped
    /// rather than crashing or surfacing a fake chip that jumps nowhere.
    @Test func malformedMarkersAreDropped() {
        let good = UUID()
        let md = """
        ---
        type: daily
        date: 2026-07-03
        ---

        # 2026-07-03

        ## MORNING
        混合了合法与非法 marker 的段落。[^m:\(good.uuidString)][^m:not-a-uuid]
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")
        let morning = model.sections.first { $0.title == "MORNING" }
        #expect(morning?.evidenceMemoIDs == [good])
        #expect(morning?.body.contains("[^m:") == false)
    }
}
