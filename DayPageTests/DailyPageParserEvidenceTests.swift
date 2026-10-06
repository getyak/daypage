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

extension DayPageSerialSwiftTests {
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

    /// Every *complete* single-line reserved marker is hidden from the reader —
    /// including invalid and empty payloads — but only well-formed UUID
    /// payloads are collected. Stripping stays bounded: the surrounding
    /// unicode prose survives exactly and persisted rawContent is untouched.
    @Test func invalidAndEmptyMarkersAreHiddenButNotCollected() {
        let md = """
        ---
        type: daily
        date: 2026-07-03
        ---

        # 2026-07-03

        ## MORNING
        早安。[^m:not-a-uuid][^m:] 今天[^m:zzz-111]继续。
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")
        let morning = model.sections.first { $0.title == "MORNING" }

        #expect(morning?.body == "早安。 今天继续。")
        #expect(morning?.body.contains("[^m:") == false)
        #expect(morning?.evidenceMemoIDs.isEmpty == true)
        #expect(model.rawContent == md)
    }

    /// Valid and invalid markers interleaved: only well-formed UUIDs are
    /// collected, in first-insertion order and deduped, while every complete
    /// marker (valid, invalid, empty) is stripped from the visible body.
    @Test func validAndInvalidMarkersCollectOnlyDedupedUUIDsInOrder() {
        let v1 = UUID()
        let v2 = UUID()
        let md = """
        ---
        type: daily
        date: 2026-07-03
        ---

        # 2026-07-03

        ## MORNING
        甲[^m:\(v1.uuidString)][^m:not-a-uuid]乙[^m:\(v2.uuidString)][^m:\(v1.uuidString)]丙[^m:]
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")
        let morning = model.sections.first { $0.title == "MORNING" }

        #expect(morning?.evidenceMemoIDs == [v1, v2])
        #expect(morning?.body == "甲乙丙")
        #expect(morning?.body.contains("[^m:") == false)
    }

    /// Ordinary footnotes, non-memo footnotes, and adjacent bracketed prose
    /// are marker-adjacent but must survive verbatim; wikilink normalization
    /// still runs over the cleaned body.
    @Test func ordinaryFootnotesAndBracketProseSurviveMarkerStripping() {
        let memo = UUID()
        let md = """
        ---
        type: daily
        date: 2026-07-03
        ---

        # 2026-07-03

        ## MORNING
        术语[^term]、编号[^1]、近似[^m2:123] 都是普通脚注；旁注 [备注 [嵌套]] 不动。见 [[wiki-page]]。结论[^m:\(memo.uuidString)] 完。
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")
        let morning = model.sections.first { $0.title == "MORNING" }
        let body = morning?.body ?? ""

        #expect(body.contains("[^term]"))
        #expect(body.contains("[^1]"))
        #expect(body.contains("[^m2:123]"), "non-memo footnotes must never be consumed")
        #expect(body.contains("[备注 [嵌套]]"), "adjacent bracketed prose must never be consumed")
        #expect(body.contains("wiki page"), "normalizeWikilinks must keep running over the cleaned body")
        #expect(body.contains("[[wiki-page]]") == false)
        #expect(body.contains("[^m:") == false)
        #expect(morning?.evidenceMemoIDs == [memo])
    }

    /// Marker matching is bounded: an unterminated `[^m:` opener must never
    /// swallow following lines up to a later `]`, and bracketed content inside
    /// a marker-looking token keeps the adjacent prose intact.
    @Test func markersNeverSwallowAcrossLinesOrAdjacentBrackets() {
        let memo = UUID()
        let md = """
        ---
        type: daily
        date: 2026-07-03
        ---

        # 2026-07-03

        ## MORNING
        第一行末尾[^m:
        第二行正文不动。
        第三行[^m:未闭合 [附录] 保留。
        第四行[^m:\(memo.uuidString)]收集。
        """

        let model = DailyPageParser.parse(content: md, dateString: "2026-07-03")
        let morning = model.sections.first { $0.title == "MORNING" }
        let body = morning?.body ?? ""

        #expect(body.contains("第一行末尾[^m:\n第二行正文不动。"), "no match may reach across a newline")
        #expect(body.contains("第三行[^m:未闭合 [附录] 保留。"), "bracketed payload content must not eat adjacent prose")
        #expect(body.contains("第四行收集。"))
        #expect(body.contains("[^m:\(memo.uuidString)]") == false)
        #expect(morning?.evidenceMemoIDs == [memo])
    }

}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias DailyPageParserEvidenceTests = DayPageSerialSwiftTests.DailyPageParserEvidenceTests
