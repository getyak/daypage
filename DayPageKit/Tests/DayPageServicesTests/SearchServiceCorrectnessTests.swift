import XCTest
import DayPageModels
import DayPageStorage
@testable import DayPageServices

/// Flomo-native refinement — 搜索正确性审计的宿主机回归测试。
///
/// 覆盖 2026-10 审计确认的语义（与 UI 文案一致，不夸大）：
/// - 关键词命中范围：memo 正文、语音附件转写、地点名、日期字符串。
/// - 编译后的日记页正文**不在**搜索范围内，但命中日仍带「已编译」标记。
/// - 类型 / 日期范围 / 地点过滤语义与 100 条上限。
/// - 语音附件转写在 legacy 磁盘路径与 SearchIndex 快路径上都可命中
///   （不新增 MatchKind、不改 schema）。
///
/// 全部使用私有临时 vault + 显式 `root:` 测试缝；不触碰全局 vault，
/// 不调用任何真实 LLM/后端。
final class SearchServiceCorrectnessTests: XCTestCase {

    private var vault: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchServiceCorrectness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("wiki/daily"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let vault { try? FileManager.default.removeItem(at: vault) }
        vault = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func writeMemo(_ memo: Memo, dateString: String) throws {
        let fileURL = vault.appendingPathComponent("raw/\(dateString).md")
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let block = memo.toMarkdown()
        let combined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? block
            : existing + RawStorage.memoSeparator + block
        try combined.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writeDailyPage(dateString: String, body: String) throws {
        let content = "---\nsummary: daily\n---\n\n\(body)\n"
        try content.write(
            to: vault.appendingPathComponent("wiki/daily/\(dateString).md"),
            atomically: true, encoding: .utf8)
    }

    /// Builds index documents from the seeded vault using the same scanner
    /// the production index uses (no global SearchIndex.shared state).
    private func indexedDocs() -> [SearchIndex.DayDocument] {
        let fm = FileManager.default
        let rawDir = vault.appendingPathComponent("raw")
        let files = (try? fm.contentsOfDirectory(atPath: rawDir.path)) ?? []
        return files
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted(by: >)
            .compactMap { stem in
                SearchIndex.scanDocument(
                    dateString: stem,
                    fileURL: rawDir.appendingPathComponent("\(stem).md"))
            }
    }

    /// Field-wise comparison projection (`SearchResult.id` is a fresh UUID).
    private struct Hit: Equatable {
        let dateString: String
        let snippet: String
        let matchKind: SearchResult.MatchKind
        let memoType: Memo.MemoType?
        let memoID: UUID?
        let isDailyPageCompiled: Bool
        init(_ r: SearchResult) {
            dateString = r.dateString; snippet = r.snippet
            matchKind = r.matchKind; memoType = r.memoType
            memoID = r.memoID; isDailyPageCompiled = r.isDailyPageCompiled
        }
    }

    // MARK: - Voice attachment transcripts

    func test_voiceAttachmentTranscript_matchesWhenBodyMisses() throws {
        try writeMemo(
            Memo(type: .voice,
                 created: makeDate(year: 2026, month: 3, day: 2),
                 attachments: [Memo.Attachment(
                    file: "raw/assets/v.m4a", kind: "audio", duration: 12,
                    transcript: "讨论了咖啡烘焙机的进货渠道",
                    transcriptionStatus: .done)],
                 body: ""),
            dateString: "2026-03-02")

        let legacy = SearchService.search(keyword: "烘焙机", root: vault)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.matchKind, .memoBody)
        XCTAssertEqual(legacy.first?.snippet.contains("烘焙机"), true)

        let indexed = SearchService.search(keyword: "烘焙机", in: indexedDocs(), root: vault)
        XCTAssertEqual(indexed.map(Hit.init), legacy.map(Hit.init),
                       "indexed fast path must match the legacy transcript path")
        XCTAssertEqual(indexed.first?.memoID, legacy.first?.memoID,
                       "transcript hits must carry the canonical memo ID on both paths")
    }

    // MARK: - Compiled daily pages

    func test_compiledDailyPageBody_isNotSearched_butDayIsFlagged() throws {
        try writeMemo(
            Memo(type: .text, created: makeDate(year: 2026, month: 4, day: 14),
                 body: "普通的一天"),
            dateString: "2026-04-14")
        try writeDailyPage(dateString: "2026-04-14", body: "编译页里独有的词：晨间仪式")

        // The compiled page's own body is NOT a search source (audited limit).
        XCTAssertTrue(SearchService.search(keyword: "晨间仪式", root: vault).isEmpty)
        XCTAssertTrue(SearchService.search(keyword: "晨间仪式", in: indexedDocs(), root: vault).isEmpty)

        // But a raw hit on that day reports the compiled badge on both paths.
        let legacy = SearchService.search(keyword: "普通", root: vault)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.isDailyPageCompiled, true)
        let indexed = SearchService.search(keyword: "普通", in: indexedDocs(), root: vault)
        XCTAssertEqual(indexed.first?.isDailyPageCompiled, true)
    }

    // MARK: - Date / type / location semantics

    func test_dateMatch_hasNilMemoID_andTypeFilterSuppressesIt() throws {
        try writeMemo(
            Memo(type: .text, created: makeDate(year: 2026, month: 1, day: 20),
                 body: "一月的笔记"),
            dateString: "2026-01-20")

        let dateHit = SearchService.search(keyword: "2026-01", root: vault)
        XCTAssertEqual(dateHit.count, 1)
        XCTAssertEqual(dateHit.first?.matchKind, .date)
        XCTAssertNil(dateHit.first?.memoID)

        var filters = SearchFilters.empty
        filters.types = [.text]
        XCTAssertTrue(SearchService.search(keyword: "2026-01", filters: filters, root: vault).isEmpty,
                      "date matches only exist without a type filter (record-source semantics)")

        // Parity on the indexed path.
        XCTAssertEqual(
            SearchService.search(keyword: "2026-01", in: indexedDocs(), root: vault).map(Hit.init),
            dateHit.map(Hit.init))
    }

    func test_locationFilter_plusKeyword_requiresBoth() throws {
        try writeMemo(
            Memo(type: .text, created: makeDate(year: 2026, month: 2, day: 1),
                 location: Memo.Location(name: "清迈咖啡实验室", lat: 18.78, lng: 98.99),
                 body: "无关的正文"),
            dateString: "2026-02-01")

        var filters = SearchFilters.empty
        filters.locationQuery = "清迈"

        // Keyword hit in body + location filter passes.
        let both = SearchService.search(keyword: "正文", filters: filters, root: vault)
        XCTAssertEqual(both.count, 1)
        // Keyword miss on the body must NOT match just because the place matches.
        XCTAssertTrue(SearchService.search(keyword: "不存在", filters: filters, root: vault).isEmpty)
        // Keyword in the location name itself is a location-kind hit.
        let locHit = SearchService.search(keyword: "清迈", filters: filters, root: vault)
        XCTAssertEqual(locHit.first?.matchKind, .location)

        XCTAssertEqual(
            SearchService.search(keyword: "正文", filters: filters, in: indexedDocs(), root: vault).map(Hit.init),
            both.map(Hit.init))
    }

    func test_filtersOnlyMode_listsAllPassingMemos() throws {
        try writeMemo(
            Memo(type: .photo, created: makeDate(year: 2026, month: 5, day: 1), body: "照片"),
            dateString: "2026-05-01")
        try writeMemo(
            Memo(type: .text, created: makeDate(year: 2026, month: 5, day: 2), body: "文字"),
            dateString: "2026-05-02")

        var filters = SearchFilters.empty
        filters.types = [.photo]
        let legacy = SearchService.search(keyword: "", filters: filters, root: vault)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.memoType, .photo)
        XCTAssertEqual(
            SearchService.search(keyword: "", filters: filters, in: indexedDocs(), root: vault).map(Hit.init),
            legacy.map(Hit.init))
    }

    // MARK: - Cap + ordering

    func test_resultCapIsHundred_newestFirst() throws {
        for day in 1...30 {
            for index in 0..<4 {
                try writeMemo(
                    Memo(type: .text, created: makeDate(year: 2026, month: 6, day: day),
                         body: "cap filler \(index)"),
                    dateString: String(format: "2026-06-%02d", day))
            }
        }
        let legacy = SearchService.search(keyword: "cap filler", root: vault)
        XCTAssertEqual(legacy.count, 100, "cap semantics: 100 hits max, newest first")
        XCTAssertEqual(legacy.first?.dateString, "2026-06-30")
        let indexed = SearchService.search(keyword: "cap filler", in: indexedDocs(), root: vault)
        XCTAssertEqual(indexed.count, 100)
        XCTAssertEqual(Array(indexed.map(\.dateString).prefix(3)), Array(legacy.map(\.dateString).prefix(3)))
    }

    func test_resultsAreNewestFirst() throws {
        for (ds, d) in [("2026-04-14", makeDate(year: 2026, month: 4, day: 14)),
                        ("2026-04-15", makeDate(year: 2026, month: 4, day: 15)),
                        ("2026-04-16", makeDate(year: 2026, month: 4, day: 16))] {
            try writeMemo(Memo(type: .text, created: d, body: "排序测试"), dateString: ds)
        }
        let results = SearchService.search(keyword: "排序测试", root: vault)
        XCTAssertEqual(results.map(\.dateString), ["2026-04-16", "2026-04-15", "2026-04-14"])
    }
}
