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

    /// Explicit fixture root: runtime fixtures live under
    /// DAYPAGE_TEST_VAULT_ROOT when provided (bounded Kit runs), otherwise a
    /// private temp directory. Never the real Vault.
    private static var fixtureRoot: URL {
        ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }

    private var vault: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vault = Self.fixtureRoot
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

    // MARK: - T16 exact metadata filter before the cap (#884)

    /// The 100 newest raw memos have NO selected tag; the 101st (older) memo
    /// carries `#target`. The metadata filter runs BEFORE the 100-result cap,
    /// so the tagged memo is found with an empty query; body hashtags never
    /// substitute for metadata; an empty eligible set matches nothing.
    func test_exactTagFilterRunsBeforeResultCap_andBodyHashtagsNeverSubstitute() throws {
        var bodyHashtagMemoID: UUID?
        for index in 0..<100 {
            let memo = Memo(
                type: .text,
                created: makeDate(year: 2026, month: 4, day: 14),
                body: index == 99 ? "body only #target but no metadata link" : "untagged \(index)"
            )
            if index == 99 { bodyHashtagMemoID = memo.id }
            try writeMemo(memo, dateString: "2026-04-14")
        }
        let tagged = Memo(
            type: .text,
            created: makeDate(year: 2026, month: 4, day: 13),
            body: "targeted older note"
        )
        try writeMemo(tagged, dateString: "2026-04-13")

        // Tag-only query with empty q: only the linked memo survives — the
        // 100 untagged newest memos never suppress it via the cap.
        let legacy = SearchService.search(
            keyword: "", root: vault, eligibleMemoIDs: [tagged.id]
        )
        XCTAssertEqual(legacy.map(\.memoID), [tagged.id])
        let indexed = SearchService.search(
            keyword: "", in: indexedDocs(), root: vault, eligibleMemoIDs: [tagged.id]
        )
        XCTAssertEqual(indexed.map(\.memoID), [tagged.id])

        // Body hashtag WITHOUT a metadata link must not match.
        XCTAssertFalse(legacy.contains { $0.memoID == bodyHashtagMemoID })

        // Metadata + text filters compose (filter order stays before the cap).
        let combined = SearchService.search(
            keyword: "target", root: vault, eligibleMemoIDs: [tagged.id]
        )
        XCTAssertEqual(combined.map(\.memoID), [tagged.id])

        // Empty eligible set matches nothing.
        XCTAssertTrue(
            SearchService.search(keyword: "", root: vault, eligibleMemoIDs: []).isEmpty
        )
        XCTAssertTrue(
            SearchService.search(
                keyword: "", in: indexedDocs(), root: vault, eligibleMemoIDs: []
            ).isEmpty
        )

        // Without a tag dimension an empty query stays an empty query.
        XCTAssertTrue(SearchService.search(keyword: "", root: vault).isEmpty)

        // Text hits on a NON-member body never substitute for metadata: only
        // the linked memo is eligible even when other bodies match the words.
        XCTAssertTrue(
            SearchService.search(
                keyword: "body only", root: vault, eligibleMemoIDs: [tagged.id]
            ).isEmpty
        )
    }

    // MARK: - T16 exact metadata filter before the cap (#884)

    /// Review item 8: the 100-result cap binds INSIDE the day loop — a single
    /// day with 105 matches returns exactly 100 (both overloads), a 90+30 day
    /// boundary returns 100, and metadata qualifying after 100 unrelated
    /// memos is still found (filter before cap).
    func test_capStopsAtHundredInsideDayLoop_andFilterStaysBeforeCap() throws {
        // 105 eligible matches in ONE day → exactly 100, file order kept.
        var ids: [UUID] = []
        for index in 0..<105 {
            let memo = Memo(
                type: .text,
                created: makeDate(year: 2026, month: 7, day: 1),
                body: "single-day cap \(index)"
            )
            ids.append(memo.id)
            try writeMemo(memo, dateString: "2026-07-01")
        }
        let eligible = Set(ids)
        let legacy = SearchService.search(keyword: "single-day cap", root: vault)
        XCTAssertEqual(legacy.count, 100)
        XCTAssertEqual(legacy.map(\.memoID), Array(ids.prefix(100)))
        let legacyTagged = SearchService.search(keyword: "", root: vault, eligibleMemoIDs: eligible)
        XCTAssertEqual(legacyTagged.map(\.memoID), Array(ids.prefix(100)))
        let indexed = SearchService.search(keyword: "single-day cap", in: indexedDocs(), root: vault)
        XCTAssertEqual(indexed.count, 100)
        let indexedTagged = SearchService.search(
            keyword: "", in: indexedDocs(), root: vault, eligibleMemoIDs: eligible
        )
        XCTAssertEqual(indexedTagged.map(\.memoID), Array(ids.prefix(100)))

        // 90 + 30 across a day boundary → 100 total, newest day first.
        for index in 0..<90 {
            try writeMemo(
                Memo(type: .text, created: makeDate(year: 2026, month: 7, day: 10), body: "boundary newer \(index)"),
                dateString: "2026-07-10")
        }
        for index in 0..<30 {
            try writeMemo(
                Memo(type: .text, created: makeDate(year: 2026, month: 7, day: 9), body: "boundary older \(index)"),
                dateString: "2026-07-09")
        }
        let boundary = SearchService.search(keyword: "boundary", root: vault)
        XCTAssertEqual(boundary.count, 100)
        XCTAssertEqual(boundary.filter { $0.dateString == "2026-07-10" }.count, 90)
        XCTAssertEqual(boundary.filter { $0.dateString == "2026-07-09" }.count, 10)
        let boundaryIndexed = SearchService.search(keyword: "boundary", in: indexedDocs(), root: vault)
        XCTAssertEqual(boundaryIndexed.count, 100)

        // Metadata qualifying AFTER 100 unrelated memos in one day is still
        // found (filter runs before the cap), and stays bounded to its own
        // membership.
        let tagged = Memo(
            type: .text,
            created: makeDate(year: 2026, month: 7, day: 20),
            body: "the one tagged note"
        )
        try writeMemo(tagged, dateString: "2026-07-20")
        for index in 0..<104 {
            try writeMemo(
                Memo(type: .text, created: makeDate(year: 2026, month: 7, day: 20), body: "untagged bulk \(index)"),
                dateString: "2026-07-20")
        }
        let onlyTagged = SearchService.search(keyword: "", root: vault, eligibleMemoIDs: [tagged.id])
        XCTAssertEqual(onlyTagged.map(\.memoID), [tagged.id])
        let onlyTaggedIndexed = SearchService.search(
            keyword: "", in: indexedDocs(), root: vault, eligibleMemoIDs: [tagged.id]
        )
        XCTAssertEqual(onlyTaggedIndexed.map(\.memoID), [tagged.id])
    }

    /// With an active tag filter, date-string rows (no memo identity) never
    /// bypass the metadata filter.
    func test_dateRowsDoNotBypassActiveTagFilter() throws {
        let memo = Memo(
            type: .text,
            created: makeDate(year: 2026, month: 1, day: 20),
            body: "一月的笔记"
        )
        try writeMemo(memo, dateString: "2026-01-20")

        // Sanity: without a tag filter the date string can match.
        let dateHit = SearchService.search(keyword: "2026-01", root: vault)
        XCTAssertEqual(dateHit.first?.matchKind, .date)

        // With a tag filter the date row is suppressed; the memo is not a
        // member either, so the result is exactly zero.
        let withTag = SearchService.search(
            keyword: "2026-01", root: vault, eligibleMemoIDs: [memo.id]
        )
        XCTAssertTrue(withTag.allSatisfy { $0.matchKind != .date })
        XCTAssertTrue(withTag.isEmpty)

        let withTagIndexed = SearchService.search(
            keyword: "2026-01", in: indexedDocs(), root: vault, eligibleMemoIDs: [memo.id]
        )
        XCTAssertTrue(withTagIndexed.allSatisfy { $0.matchKind != .date })

        // Member memo + date keyword: only the memo-body path, never a date
        // row, and only for the exact member.
        let memberBody = SearchService.search(
            keyword: "笔记", root: vault, eligibleMemoIDs: [memo.id]
        )
        XCTAssertEqual(memberBody.map(\.memoID), [memo.id])
    }

    // MARK: - Generated media-only placeholder presentation (#884 follow-up)

    /// Mirrors `scripts/import_flomo.py`'s generated link body for one photo
    /// attachment: exactly one `[Photo attachment: NAME](raw/assets/flomo/<hex>.png)`
    /// line, emitted only for an originally empty body.
    private func generatedPlaceholderMemo(
        created: Date, hexChar: Character, filename: String
    ) -> Memo {
        let file = "raw/assets/flomo/\(String(repeating: String(hexChar), count: 64)).png"
        return Memo(
            type: .photo,
            created: created,
            attachments: [Memo.Attachment(file: file, kind: "photo")],
            body: "[Photo attachment: \(filename)](\(file))"
        )
    }

    /// A keyword hit on the internal generated path stays eligible (matching
    /// semantics are untouched) but the output snippet NEVER shows the
    /// generated path — file path and indexed path agree exactly. Ordinary
    /// prose keeps its snippet, and the index stores a presentation body only
    /// for an actually changed presentation.
    func test_generatedMediaOnlyPlaceholder_hidesGeneratedPathInSnippets_bothPaths() throws {
        let placeholder = generatedPlaceholderMemo(
            created: makeDate(year: 2026, month: 7, day: 1),
            hexChar: "a", filename: "相册照片 (1).png")
        try writeMemo(placeholder, dateString: "2026-07-01")
        let prose = Memo(
            type: .text,
            created: makeDate(year: 2026, month: 7, day: 2),
            body: "普通正文 [真实链接](https://example.com/x)")
        try writeMemo(prose, dateString: "2026-07-02")

        for keyword in ["raw/assets/flomo", "Photo attachment", "相册照片"] {
            let legacy = SearchService.search(keyword: keyword, root: vault)
            XCTAssertEqual(legacy.map(\.memoID), [placeholder.id],
                           "\(keyword) must stay eligible against the raw body")
            XCTAssertEqual(legacy.first?.snippet, "",
                           "generated path must never appear in the snippet")
            let indexed = SearchService.search(keyword: keyword, in: indexedDocs(), root: vault)
            XCTAssertEqual(indexed.map(Hit.init), legacy.map(Hit.init),
                           "file + indexed paths must agree on hidden-path snippets")
        }

        // Filter-only output hides the generated path too (existing empty-body
        // fallback: location name, else the day string).
        var filters = SearchFilters.empty
        filters.types = [.photo, .text]
        let legacyAll = SearchService.search(keyword: "", filters: filters, root: vault)
        XCTAssertEqual(legacyAll.map(\.dateString), ["2026-07-02", "2026-07-01"])
        XCTAssertEqual(legacyAll.first { $0.memoID == placeholder.id }?.snippet, "2026-07-01")
        XCTAssertTrue(legacyAll.allSatisfy { !$0.snippet.contains("raw/assets") })
        XCTAssertEqual(
            SearchService.search(keyword: "", filters: filters, in: indexedDocs(), root: vault).map(Hit.init),
            legacyAll.map(Hit.init))

        // Ordinary prose is preserved verbatim in both directions.
        let legacyProse = SearchService.search(keyword: "普通正文", root: vault)
        XCTAssertEqual(legacyProse.map(\.memoID), [prose.id])
        XCTAssertTrue(legacyProse.first?.snippet.contains("普通正文") == true)
        XCTAssertEqual(
            SearchService.search(keyword: "普通正文", in: indexedDocs(), root: vault).map(Hit.init),
            legacyProse.map(Hit.init))

        // Builder rule: only a CHANGED presentation is stored; nil falls back.
        let docs = indexedDocs().flatMap(\.memos)
        XCTAssertEqual(docs.first { $0.id == placeholder.id }?.presentationBody, "")
        XCTAssertNil(docs.first { $0.id == prose.id }?.presentationBody)
    }

    /// Exact tag membership, result order and the 100-result cap are untouched
    /// by hidden placeholder presentation.
    func test_generatedPlaceholder_tagFilterOrderAndCap_retained() throws {
        let placeholder = generatedPlaceholderMemo(
            created: makeDate(year: 2026, month: 8, day: 1),
            hexChar: "b", filename: "old.png")
        try writeMemo(placeholder, dateString: "2026-08-01")
        let prose = Memo(
            type: .text,
            created: makeDate(year: 2026, month: 8, day: 2),
            body: "更近的正文")
        try writeMemo(prose, dateString: "2026-08-02")

        // Exact membership semantics: empty set matches nothing, the single
        // member memo matches with an empty query.
        XCTAssertTrue(
            SearchService.search(keyword: "", root: vault, eligibleMemoIDs: []).isEmpty)
        let tagged = SearchService.search(
            keyword: "", root: vault, eligibleMemoIDs: [placeholder.id])
        XCTAssertEqual(tagged.map(\.memoID), [placeholder.id])
        XCTAssertEqual(tagged.first?.snippet, "2026-08-01")
        XCTAssertEqual(
            SearchService.search(
                keyword: "", in: indexedDocs(), root: vault,
                eligibleMemoIDs: [placeholder.id]).map(Hit.init),
            tagged.map(Hit.init))

        // Order retained: newest day first on both paths.
        let both = SearchService.search(
            keyword: "", root: vault, eligibleMemoIDs: [placeholder.id, prose.id])
        XCTAssertEqual(both.map(\.memoID), [prose.id, placeholder.id])

        // Cap retained: 102 generated-placeholder memos in one day still stop
        // at exactly 100 results, with hidden paths on both paths.
        for index in 0 ..< 102 {
            let hexDigit = Array("0123456789abcdef")[index % 16]
            try writeMemo(
                generatedPlaceholderMemo(
                    created: makeDate(year: 2026, month: 8, day: 3),
                    hexChar: hexDigit, filename: "cap \(index).png"),
                dateString: "2026-08-03")
        }
        var capFilters = SearchFilters.empty
        capFilters.types = [.photo]
        let capped = SearchService.search(keyword: "", filters: capFilters, root: vault)
        XCTAssertEqual(capped.count, 100)
        XCTAssertEqual(capped.first?.dateString, "2026-08-03")
        XCTAssertTrue(capped.allSatisfy { !$0.snippet.contains("raw/assets") })
        XCTAssertEqual(
            SearchService.search(
                keyword: "", filters: capFilters, in: indexedDocs(), root: vault).map(Hit.init),
            capped.map(Hit.init))
    }

    /// ACTUAL v2 pull path fixture (#884 follow-up review): the real
    /// `SyncRemoteChange.makeMemo` maps `attachment.file` through
    /// `AttachmentTransferStore.localPath`, whose deterministic download path
    /// is `raw/assets/sync/<contentSHA256>-<sanitized originalFilename>`,
    /// while the body keeps the original flomo placeholder link. The real
    /// helper must hide exactly that generated display body — nothing else —
    /// with raw keyword matching, order and eligibility unchanged. Synthetic
    /// descriptors only; the vault override is this test's isolated fixture
    /// root and is restored afterwards. No real Vault, Keychain or network.
    func test_v2PullMakeMemo_deterministicSyncPath_hidesOnlyGeneratedDisplayBody() throws {
        let previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
        defer { VaultInitializer.testOverrideURL = previousOverride }

        let sha = String(repeating: "ab", count: 32)
        let name = "相册照片 (1).png"
        let originalTarget = "raw/assets/flomo/\(sha).png"
        let body = "[Photo attachment: \(name)](\(originalTarget))"
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: sha,
            sizeBytes: 4096,
            mimeType: "image/png",
            objectKey: "\(UUID().uuidString)/\(UUID().uuidString)/\(sha).png",
            originalFilename: name
        )
        XCTAssertTrue(AttachmentManifest.isStructurallyValid([descriptor]))
        let manifestHash = AttachmentManifest.hash([descriptor])
        let change = SyncRemoteChange(
            id: UUID(),
            type: "photo",
            body: body,
            createdAt: makeDate(year: 2026, month: 9, day: 1),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: "fixture-device",
            source: "supabase",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 1,
            attachmentManifestHash: manifestHash,
            attachments: [descriptor]
        )

        // Actual production mapping: deterministic sync path + preserved body.
        let memo = change.makeMemo()
        let expectedPath = "raw/assets/sync/\(sha)-\(name)"
        XCTAssertEqual(memo.attachments.map(\.file), [expectedPath])
        XCTAssertEqual(memo.body, body, "makeMemo must preserve the original body")
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo), "")

        // Control memo: ordinary prose is never suppressed.
        let prose = Memo(
            type: .text,
            created: makeDate(year: 2026, month: 9, day: 2),
            body: "普通正文 [真实链接](https://example.com/x)")
        try writeMemo(memo, dateString: "2026-09-01")
        try writeMemo(prose, dateString: "2026-09-02")
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: prose), prose.body)

        // Raw keyword hits stay eligible on both paths; only the snippet hides
        // the generated display body.
        for keyword in ["raw/assets", "Photo attachment", "相册照片"] {
            let legacy = SearchService.search(keyword: keyword, root: vault)
            XCTAssertEqual(legacy.map(\.memoID), [memo.id], "\(keyword) must stay eligible")
            XCTAssertEqual(legacy.first?.snippet, "", "generated display body must be hidden")
            XCTAssertEqual(
                SearchService.search(keyword: keyword, in: indexedDocs(), root: vault).map(Hit.init),
                legacy.map(Hit.init))
        }

        // Ordinary prose snippet preserved; filter-only order newest-first
        // with the placeholder memo falling back to its date, never the path.
        let proseHit = SearchService.search(keyword: "普通正文", root: vault)
        XCTAssertEqual(proseHit.map(\.memoID), [prose.id])
        XCTAssertTrue(proseHit.first?.snippet.contains("普通正文") == true)
        var filters = SearchFilters.empty
        filters.types = [.photo, .text]
        let all = SearchService.search(keyword: "", filters: filters, root: vault)
        XCTAssertEqual(all.map(\.memoID), [prose.id, memo.id], "newest-first order retained")
        XCTAssertEqual(all.first { $0.memoID == memo.id }?.snippet, "2026-09-01")
        XCTAssertTrue(all.allSatisfy { !$0.snippet.contains("raw/assets") })

        // Eligibility semantics unchanged: exact membership still gates.
        XCTAssertTrue(
            SearchService.search(keyword: "raw/assets", root: vault, eligibleMemoIDs: [prose.id]).isEmpty)
        XCTAssertEqual(
            SearchService.search(keyword: "raw/assets", root: vault, eligibleMemoIDs: [memo.id]).map(\.memoID),
            [memo.id])
    }

    /// A v2 pull whose sync path deviates from the exact correspondence (wrong
    /// name suffix) keeps the body fully — only the exact generated set hides.
    func test_v2PullMakeMemo_nonCorrespondingSyncPath_preservesBody() throws {
        let previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
        defer { VaultInitializer.testOverrideURL = previousOverride }

        let sha = String(repeating: "cd", count: 32)
        let name = "原始名称.png"
        let body = "[Photo attachment: \(name)](raw/assets/flomo/\(sha).png)"
        // Production sanitizes the descriptor filename; a descriptor name that
        // is NOT the line's basename makes the correspondence uncertain.
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: sha,
            sizeBytes: 2048,
            mimeType: "image/png",
            objectKey: "\(UUID().uuidString)/\(UUID().uuidString)/\(sha).png",
            originalFilename: "other name.png"
        )
        XCTAssertTrue(AttachmentManifest.isStructurallyValid([descriptor]))
        let change = SyncRemoteChange(
            id: UUID(),
            type: "photo",
            body: body,
            createdAt: makeDate(year: 2026, month: 9, day: 3),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: "fixture-device",
            source: "supabase",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 1,
            attachmentManifestHash: AttachmentManifest.hash([descriptor]),
            attachments: [descriptor]
        )
        let memo = change.makeMemo()
        XCTAssertEqual(memo.attachments.map(\.file),
                       ["raw/assets/sync/\(sha)-other name.png"])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo), body,
                       "non-corresponding sync path must preserve the body")
    }
}
