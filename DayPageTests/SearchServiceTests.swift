import Testing
import Foundation
@testable import DayPage

@Suite("SearchService")
struct SearchServiceTests {

    // MARK: - Setup helpers

    private static func makeTempVault() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("wiki/daily", isDirectory: true),
            withIntermediateDirectories: true)
        return tmp
    }

    private static func writeMemo(_ memo: Memo, dateString: String, to vaultURL: URL) throws {
        let fileURL = vaultURL.appendingPathComponent("raw/\(dateString).md")
        let existing: String
        if FileManager.default.fileExists(atPath: fileURL.path) {
            existing = try String(contentsOf: fileURL, encoding: .utf8)
        } else {
            existing = ""
        }
        let block = memo.toMarkdown()
        let combined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? block
            : existing + RawStorage.memoSeparator + block
        try combined.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Test cases

    @Test func emptyKeywordNoFiltersReturnsEmpty() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        let memo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14), body: "hello world")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)
        VaultInitializer.testOverrideURL = tmp

        let results = SearchService.search(keyword: "", filters: .empty)
        #expect(results.isEmpty)
    }

    @Test func caseInsensitiveBodyMatch_snippetEllipsis() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        // Short body — no truncation expected
        let shortMemo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14),
                             body: "Hello World today")
        try Self.writeMemo(shortMemo, dateString: "2026-04-14", to: tmp)

        // Long body — should get trailing ellipsis
        let longBody = String(repeating: "x", count: 60) + "KEYWORD" + String(repeating: "y", count: 100)
        let longMemo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 3, day: 1),
                            body: longBody)
        try Self.writeMemo(longMemo, dateString: "2026-03-01", to: tmp)
        VaultInitializer.testOverrideURL = tmp

        let results = SearchService.search(keyword: "world")
        #expect(results.contains { $0.snippet.lowercased().contains("world") })

        let longResults = SearchService.search(keyword: "keyword")
        let longSnippet = longResults.first { $0.snippet.lowercased().contains("keyword") }?.snippet
        #expect(longSnippet != nil)
        // Should have leading ellipsis (match is 60 chars in, beyond the 30-char window back from start)
        #expect(longSnippet?.hasPrefix("…") == true)
        // Should have trailing ellipsis (60 chars after keyword exceeds 90-char look-ahead)
        #expect(longSnippet?.hasSuffix("…") == true)
    }

    @Test func cjkBodyMatch_nonCrashing() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        let cjkBody = "今天天气很好，我去了一家咖啡馆，喝了一杯拿铁，感觉很不错。"
        let memo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14), body: cjkBody)
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)
        VaultInitializer.testOverrideURL = tmp

        // Should not crash and should return a result
        let results = SearchService.search(keyword: "咖啡馆")
        #expect(!results.isEmpty)
        let snippet = results.first?.snippet ?? ""
        #expect(!snippet.isEmpty)
        // Snippet must be valid UTF-8 (no broken multibyte sequences)
        #expect(snippet.utf8.count > 0)
    }

    @Test func dateRangeFilter_boundaryInclusion() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        for (ds, d) in [("2026-04-14", Self.makeDate(year: 2026, month: 4, day: 14)),
                        ("2026-04-15", Self.makeDate(year: 2026, month: 4, day: 15)),
                        ("2026-04-16", Self.makeDate(year: 2026, month: 4, day: 16))] {
            let memo = Memo(type: .text, created: d, body: "entry")
            try Self.writeMemo(memo, dateString: ds, to: tmp)
        }
        VaultInitializer.testOverrideURL = tmp

        var filters = SearchFilters.empty
        filters.startDate = Self.makeDate(year: 2026, month: 4, day: 14)
        filters.endDate   = Self.makeDate(year: 2026, month: 4, day: 15)

        let results = SearchService.search(keyword: "entry", filters: filters)
        let dates = Set(results.map { $0.dateString })
        #expect(dates.contains("2026-04-14"))   // boundary — included
        #expect(dates.contains("2026-04-15"))   // boundary — included
        #expect(!dates.contains("2026-04-16"))  // outside — excluded
    }

    @Test func typesFilter_restrictsMemoType() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let textMemo  = Memo(id: UUID(), type: .text,  created: d, body: "shared keyword")
        let voiceMemo = Memo(id: UUID(), type: .voice, created: d, body: "shared keyword")
        try Self.writeMemo(textMemo,  dateString: "2026-04-14", to: tmp)
        try Self.writeMemo(voiceMemo, dateString: "2026-04-14", to: tmp)
        VaultInitializer.testOverrideURL = tmp

        var filters = SearchFilters.empty
        filters.types = [.voice]

        let results = SearchService.search(keyword: "shared keyword", filters: filters)
        // Only voice memos should be returned
        for r in results {
            if r.matchKind != .date {
                #expect(r.memoType == .voice)
            }
        }
        // Date-string match branch suppressed when types filter is active
        #expect(!results.contains { $0.matchKind == .date })
    }

    @Test func locationQueryFilter_matchesMemoLocation() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let loc = Memo.Location(name: "Shibuya Coffee", lat: 35.659, lng: 139.700)
        let memoWithLoc = Memo(id: UUID(), type: .text, created: d, location: loc, body: "had a great time")
        let memoNoLoc   = Memo(id: UUID(), type: .text, created: d, body: "had a great time")
        try Self.writeMemo(memoWithLoc, dateString: "2026-04-14", to: tmp)
        try Self.writeMemo(memoNoLoc,   dateString: "2026-04-14", to: tmp)
        VaultInitializer.testOverrideURL = tmp

        var filters = SearchFilters.empty
        filters.locationQuery = "shibuya"

        let results = SearchService.search(keyword: "had", filters: filters)
        // Only the memo with matching location should appear
        #expect(results.count == 1)
        #expect(results.first?.snippet.lowercased().contains("had") == true)
    }

    @Test func transcriptMatch_hitsWhenBodyMissesButTranscriptContainsKeyword() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let att = Memo.Attachment(file: "voice.m4a", kind: "audio",
                                  transcript: "the meeting was productive")
        let memo = Memo(id: UUID(), type: .voice, created: d,
                        attachments: [att], body: "no relevant text here")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)
        VaultInitializer.testOverrideURL = tmp

        let results = SearchService.search(keyword: "productive")
        #expect(!results.isEmpty)
        let r = results.first!
        #expect(r.matchKind == .memoBody)
        #expect(r.snippet.lowercased().contains("productive"))
    }

    @Test func resultsOrderedNewestFirst() throws {
        let tmp = try Self.makeTempVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        for (ds, d) in [("2026-01-01", Self.makeDate(year: 2026, month: 1, day: 1)),
                        ("2026-03-01", Self.makeDate(year: 2026, month: 3, day: 1)),
                        ("2026-04-14", Self.makeDate(year: 2026, month: 4, day: 14))] {
            let memo = Memo(type: .text, created: d, body: "searchable content")
            try Self.writeMemo(memo, dateString: ds, to: tmp)
        }
        VaultInitializer.testOverrideURL = tmp

        let results = SearchService.search(keyword: "searchable content")
        let dates = results.compactMap { $0.matchKind == .memoBody ? $0.dateString : nil }
        #expect(dates == dates.sorted(by: >), "Results must be ordered newest-first")
    }
}
