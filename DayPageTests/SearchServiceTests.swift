import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

extension DayPageSerialSwiftTests {
// #827 flake root cause: these tests used to mutate the process-global
// `VaultInitializer.testOverrideURL`, and Swift Testing runs OTHER suites in
// parallel — `.serialized` only covers this file, so a foreign suite could
// repoint the vault mid-test and empty out the results. Every search/rebuild
// now pins its private temp vault via the explicit `root:` seam instead, so
// the global is never touched. `.serialized` stays only for the nested parity
// suite, whose `SearchIndex.shared` singleton state is still process-global.
@Suite("SearchService", .serialized)
struct SearchServiceTests {

    // MARK: - Setup helpers

    fileprivate static func makeTempVault() throws -> URL {
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

    fileprivate static func writeMemo(_ memo: Memo, dateString: String, to vaultURL: URL) throws {
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

    fileprivate static func makeDate(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Test cases

    @Test func emptyKeywordNoFiltersReturnsEmpty() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14), body: "hello world")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)

        let results = SearchService.search(keyword: "", filters: .empty, root: tmp)
        #expect(results.isEmpty)
    }

    @Test func caseInsensitiveBodyMatch_snippetEllipsis() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Short body — no truncation expected
        let shortMemo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14),
                             body: "Hello World today")
        try Self.writeMemo(shortMemo, dateString: "2026-04-14", to: tmp)

        // Long body — should get trailing ellipsis
        let longBody = String(repeating: "x", count: 60) + "KEYWORD" + String(repeating: "y", count: 100)
        let longMemo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 3, day: 1),
                            body: longBody)
        try Self.writeMemo(longMemo, dateString: "2026-03-01", to: tmp)

        let results = SearchService.search(keyword: "world", root: tmp)
        #expect(results.contains { $0.snippet.lowercased().contains("world") })

        let longResults = SearchService.search(keyword: "keyword", root: tmp)
        let longSnippet = longResults.first { $0.snippet.lowercased().contains("keyword") }?.snippet
        #expect(longSnippet != nil)
        // Should have leading ellipsis (match is 60 chars in, beyond the 30-char window back from start)
        #expect(longSnippet?.hasPrefix("…") == true)
        // Should have trailing ellipsis (60 chars after keyword exceeds 90-char look-ahead)
        #expect(longSnippet?.hasSuffix("…") == true)
    }

    @Test func cjkBodyMatch_nonCrashing() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cjkBody = "今天天气很好，我去了一家咖啡馆，喝了一杯拿铁，感觉很不错。"
        let memo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14), body: cjkBody)
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)

        // Should not crash and should return a result
        let results = SearchService.search(keyword: "咖啡馆", root: tmp)
        #expect(!results.isEmpty)
        let snippet = results.first?.snippet ?? ""
        #expect(!snippet.isEmpty)
        // Snippet must be valid UTF-8 (no broken multibyte sequences)
        #expect(snippet.utf8.count > 0)
    }

    @Test func dateRangeFilter_boundaryInclusion() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (ds, d) in [("2026-04-14", Self.makeDate(year: 2026, month: 4, day: 14)),
                        ("2026-04-15", Self.makeDate(year: 2026, month: 4, day: 15)),
                        ("2026-04-16", Self.makeDate(year: 2026, month: 4, day: 16))] {
            let memo = Memo(type: .text, created: d, body: "entry")
            try Self.writeMemo(memo, dateString: ds, to: tmp)
        }

        var filters = SearchFilters.empty
        filters.startDate = Self.makeDate(year: 2026, month: 4, day: 14)
        filters.endDate   = Self.makeDate(year: 2026, month: 4, day: 15)

        let results = SearchService.search(keyword: "entry", filters: filters, root: tmp)
        let dates = Set(results.map { $0.dateString })
        #expect(dates.contains("2026-04-14"))   // boundary — included
        #expect(dates.contains("2026-04-15"))   // boundary — included
        #expect(!dates.contains("2026-04-16"))  // outside — excluded
    }

    @Test func typesFilter_restrictsMemoType() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let textMemo  = Memo(id: UUID(), type: .text,  created: d, body: "shared keyword")
        let voiceMemo = Memo(id: UUID(), type: .voice, created: d, body: "shared keyword")
        try Self.writeMemo(textMemo,  dateString: "2026-04-14", to: tmp)
        try Self.writeMemo(voiceMemo, dateString: "2026-04-14", to: tmp)

        var filters = SearchFilters.empty
        filters.types = [.voice]

        let results = SearchService.search(keyword: "shared keyword", filters: filters, root: tmp)
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
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let loc = Memo.Location(name: "Shibuya Coffee", lat: 35.659, lng: 139.700)
        let memoWithLoc = Memo(id: UUID(), type: .text, created: d, location: loc, body: "had a great time")
        let memoNoLoc   = Memo(id: UUID(), type: .text, created: d, body: "had a great time")
        try Self.writeMemo(memoWithLoc, dateString: "2026-04-14", to: tmp)
        try Self.writeMemo(memoNoLoc,   dateString: "2026-04-14", to: tmp)

        var filters = SearchFilters.empty
        filters.locationQuery = "shibuya"

        let results = SearchService.search(keyword: "had", filters: filters, root: tmp)
        // Only the memo with matching location should appear
        #expect(results.count == 1)
        #expect(results.first?.snippet.lowercased().contains("had") == true)
    }

    @Test func transcriptMatch_hitsWhenBodyMissesButTranscriptContainsKeyword() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let att = Memo.Attachment(file: "voice.m4a", kind: "audio",
                                  transcript: "the meeting was productive")
        let memo = Memo(id: UUID(), type: .voice, created: d,
                        attachments: [att], body: "no relevant text here")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)

        let results = SearchService.search(keyword: "productive", root: tmp)
        #expect(!results.isEmpty)
        let r = results.first!
        #expect(r.matchKind == .memoBody)
        #expect(r.snippet.lowercased().contains("productive"))
    }

    @Test func diacriticInsensitive_cafeMatchesCafe() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14),
                        body: "I visited a lovely café in the morning")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)

        let results = SearchService.search(keyword: "cafe", root: tmp)
        #expect(!results.isEmpty)
        // Snippet must preserve the original accented character
        let snippet = results.first?.snippet ?? ""
        #expect(snippet.contains("café"))
    }

    @Test func diacriticInsensitive_zurichMatchesZurich() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loc = Memo.Location(name: "Zürich", lat: 47.376, lng: 8.541)
        let memo = Memo(id: UUID(), type: .location, created: Self.makeDate(year: 2026, month: 4, day: 14),
                        location: loc, body: "arrived in the city")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)

        let results = SearchService.search(keyword: "zurich", root: tmp)
        #expect(!results.isEmpty)
        let locationResult = results.first { $0.matchKind == .location }
        #expect(locationResult != nil)
        #expect(locationResult?.snippet == "Zürich")
    }

    @Test func diacriticInsensitive_saoPauloMatchesSaoPaulo() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memo = Memo(type: .text, created: Self.makeDate(year: 2026, month: 4, day: 14),
                        body: "flying into São Paulo tomorrow")
        try Self.writeMemo(memo, dateString: "2026-04-14", to: tmp)

        let results = SearchService.search(keyword: "sao paulo", root: tmp)
        #expect(!results.isEmpty)
        let snippet = results.first?.snippet ?? ""
        #expect(snippet.contains("São Paulo"))
    }

    @Test func resultsOrderedNewestFirst() throws {
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (ds, d) in [("2026-01-01", Self.makeDate(year: 2026, month: 1, day: 1)),
                        ("2026-03-01", Self.makeDate(year: 2026, month: 3, day: 1)),
                        ("2026-04-14", Self.makeDate(year: 2026, month: 4, day: 14))] {
            let memo = Memo(type: .text, created: d, body: "searchable content")
            try Self.writeMemo(memo, dateString: ds, to: tmp)
        }

        let results = SearchService.search(keyword: "searchable content", root: tmp)
        let dates = results.compactMap { $0.matchKind == .memoBody ? $0.dateString : nil }
        #expect(dates == dates.sorted(by: >), "Results must be ordered newest-first")
    }

    // MARK: - Memo identity (#search navigation: matched memo must stay addressable)

    @Test @MainActor func owningRawDayUsesStorageTimezoneInsteadOfDeviceMidnight() async throws {
        let defaults = UserDefaults.standard
        let key = StorageSettings.preferredTimeZoneKey
        let previous = defaults.object(forKey: key)
        defaults.set("Asia/Shanghai", forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let dayString = "2026-04-14"
        let deviceFormatter = DateFormatter()
        deviceFormatter.calendar = Calendar(identifier: .gregorian)
        deviceFormatter.locale = Locale(identifier: "en_US_POSIX")
        deviceFormatter.dateFormat = "yyyy-MM-dd"
        deviceFormatter.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let oldDeviceMidnight = try #require(deviceFormatter.date(from: dayString))
        #expect(RawStorage.fileURL(for: oldDeviceMidnight).lastPathComponent == "2026-04-13.md",
                "negative control: device midnight selects the previous stored day")

        let owningDay = try #require(RawStorage.date(forDayString: dayString))
        #expect(RawStorage.fileURL(for: owningDay).lastPathComponent == dayString + ".md")
        let tmp = try Self.makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let memo = Memo(type: .text, created: owningDay, body: "owning day timezone regression")
        try Self.writeMemo(memo, dateString: dayString, to: tmp)
        let rawURL = tmp.appendingPathComponent("raw/" + dayString + ".md")
        let before = try Data(contentsOf: rawURL)
        let resolved = try await MemoRecordStore.shared.memo(id: memo.id, day: owningDay, vaultRoot: tmp)
        #expect(resolved.id == memo.id && resolved.body == memo.body)
        #expect(try Data(contentsOf: rawURL) == before, "routing reads the exact owning file without mutation")
    }

    @Test @MainActor func owningRawDayRejectsInvalidDatesAndRoundtripsAcrossZones() throws {
        let defaults = UserDefaults.standard
        let key = StorageSettings.preferredTimeZoneKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        for zone in ["Asia/Shanghai", "Pacific/Kiritimati", "America/Los_Angeles"] {
            defaults.set(zone, forKey: key)
            for dayString in ["2024-02-29", "2026-03-08", "2026-11-01"] {
                let day = try #require(RawStorage.date(forDayString: dayString))
                #expect(RawStorage.fileURL(for: day).lastPathComponent == dayString + ".md")
            }
            for invalid in ["2026-02-30", "2026-13-01", "2026-4-14", "../2026-04-14", "2026-04-14.md"] {
                #expect(RawStorage.date(forDayString: invalid) == nil)
            }
        }
    }

    /// Two same-day memos with byte-identical bodies produce identical snippets,
    /// so the snippet cannot identify WHICH memo matched. Both paths must still
    /// return two hits carrying the two distinct, canonical `Memo.id` values —
    /// legacy after a real Markdown roundtrip (toMarkdown → RawStorage.parse),
    /// and the indexed path over the in-memory documents.
    @Test @MainActor func duplicateSameDayIdenticalBodiesKeepDistinctMemoIDs_roundtripAndIndexed() throws {
        let tmp = try Self.makeTempVault()
        defer {
            SearchIndex.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tmp)
        }
        let d = Self.makeDate(year: 2026, month: 4, day: 14)
        let twinA = Memo(id: UUID(), type: .text, created: d, body: "twin espresso note")
        let twinB = Memo(id: UUID(), type: .text, created: d, body: "twin espresso note")
        try Self.writeMemo(twinA, dateString: "2026-04-14", to: tmp)
        try Self.writeMemo(twinB, dateString: "2026-04-14", to: tmp)

        // Legacy path: results parse back from real Markdown on disk.
        let legacy = SearchService.search(keyword: "twin espresso", root: tmp)
        #expect(legacy.count == 2, "identical same-day bodies must stay two distinct hits")
        let legacyA = try #require(legacy.first)
        let legacyB = try #require(legacy.last)
        #expect(legacyA.snippet == legacyB.snippet, "fixture: identical bodies yield identical snippets")
        #expect(legacyA.memoID != legacyB.memoID, "identical snippets must not collapse memo identity")
        #expect(Set(legacy.compactMap(\.memoID)) == Set([twinA.id, twinB.id]),
                "Markdown roundtrip must retain both canonical memo IDs")

        // Indexed path: same distinct identities over the in-memory snapshot.
        SearchIndex.shared.rebuildSynchronouslyForTesting(root: tmp)
        let docs = try #require(SearchIndex.shared.documentsIfBuilt())
        let indexed = SearchService.search(keyword: "twin espresso", in: docs, root: tmp)
        #expect(indexed.count == 2, "indexed path must also keep two distinct hits")
        let indexedA = try #require(indexed.first)
        let indexedB = try #require(indexed.last)
        #expect(indexedA.memoID != indexedB.memoID, "indexed hits must keep distinct memo identities")
        #expect(Set(indexed.compactMap(\.memoID)) == Set([twinA.id, twinB.id]),
                "indexed path must carry the same canonical memo IDs")
    }

    /// Date-only hits describe a day, not a memo — their `memoID` must be nil.
    /// Every actual-memo hit (body, attachment transcript, location, filters-only)
    /// must carry the canonical `Memo.id`, on compiled and raw-only days alike,
    /// with legacy and indexed paths agreeing on all of it.
    @Test @MainActor func dateMatchHasNilMemoID_memoHitsCarryCanonicalIDs_legacyIndexedParity() throws {
        let tmp = try Self.makeTempVault()
        defer {
            SearchIndex.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tmp)
        }
        // 2026-02-05 is compiled (wiki/daily present); the other days stay raw-only.
        try "# compiled daily page".write(
            to: tmp.appendingPathComponent("wiki/daily/2026-02-05.md"),
            atomically: true, encoding: .utf8)

        let bodyMemo = Memo(id: UUID(), type: .text,
                            created: Self.makeDate(year: 2026, month: 2, day: 5),
                            body: "morning espresso run")
        let voiceMemo = Memo(id: UUID(), type: .voice,
                             created: Self.makeDate(year: 2026, month: 3, day: 2),
                             attachments: [Memo.Attachment(
                                file: "raw/assets/v.m4a", kind: "audio", duration: 3,
                                transcript: "the harvest report was long",
                                transcriptionStatus: .done)],
                             body: "")
        let locMemo = Memo(id: UUID(), type: .text,
                           created: Self.makeDate(year: 2026, month: 4, day: 14),
                           location: Memo.Location(name: "Osaka Castle", lat: 34.687, lng: 135.526),
                           body: "sightseeing day")
        let dateOnlyMemo = Memo(id: UUID(), type: .text,
                                created: Self.makeDate(year: 2026, month: 1, day: 20),
                                body: "plain winter note")
        try Self.writeMemo(bodyMemo,      dateString: "2026-02-05", to: tmp)
        try Self.writeMemo(voiceMemo,     dateString: "2026-03-02", to: tmp)
        try Self.writeMemo(locMemo,       dateString: "2026-04-14", to: tmp)
        try Self.writeMemo(dateOnlyMemo,  dateString: "2026-01-20", to: tmp)

        SearchIndex.shared.rebuildSynchronouslyForTesting(root: tmp)
        let docs = try #require(SearchIndex.shared.documentsIfBuilt())

        func bothPaths(_ keyword: String, _ filters: SearchFilters = .empty)
            -> (legacy: [SearchResult], indexed: [SearchResult]) {
            (SearchService.search(keyword: keyword, filters: filters, root: tmp),
             SearchService.search(keyword: keyword, filters: filters, in: docs, root: tmp))
        }
        func expectParity(_ label: String, _ r: (legacy: [SearchResult], indexed: [SearchResult])) {
            #expect(r.indexed.map(\.dateString) == r.legacy.map(\.dateString), "\(label): dateString parity")
            #expect(r.indexed.map(\.snippet) == r.legacy.map(\.snippet), "\(label): snippet parity")
            #expect(r.indexed.map(\.matchKind) == r.legacy.map(\.matchKind), "\(label): matchKind parity")
            #expect(r.indexed.map(\.memoID) == r.legacy.map(\.memoID), "\(label): memoID parity")
        }

        // 1. Date-only match ("2026-01" matches just the day string) → nil memoID.
        let date = bothPaths("2026-01")
        #expect(date.legacy.count == 1, "date keyword must hit exactly one day")
        let dateHit = try #require(date.legacy.first)
        #expect(dateHit.matchKind == .date)
        #expect(dateHit.memoID == nil, "date-only match must not claim a memo identity")
        expectParity("date-only", date)

        // 2. Body hit on a compiled day keeps the canonical memo ID.
        let body = bothPaths("espresso")
        #expect(body.legacy.count == 1)
        let bodyHit = try #require(body.legacy.first)
        #expect(bodyHit.memoID == bodyMemo.id, "body hit must carry the canonical memo ID")
        #expect(bodyHit.isDailyPageCompiled, "compiled day must not drop memo identity")
        expectParity("body", body)

        // 3. Attachment-transcript-only hit (body is empty).
        let transcript = bothPaths("harvest")
        #expect(transcript.legacy.count == 1)
        let transcriptHit = try #require(transcript.legacy.first)
        #expect(transcriptHit.memoID == voiceMemo.id, "transcript hit must carry the canonical memo ID")
        expectParity("transcript", transcript)

        // 4. Location hit.
        let location = bothPaths("osaka")
        #expect(location.legacy.count == 1)
        let locationHit = try #require(location.legacy.first)
        #expect(locationHit.matchKind == .location)
        #expect(locationHit.memoID == locMemo.id, "location hit must carry the canonical memo ID")
        expectParity("location", location)

        // 5. Filters-only mode (empty keyword) still carries memo identity.
        var onlyVoice = SearchFilters.empty
        onlyVoice.types = [.voice]
        let filtered = bothPaths("", onlyVoice)
        #expect(filtered.legacy.count == 1)
        let filteredHit = try #require(filtered.legacy.first)
        #expect(filteredHit.memoID == voiceMemo.id, "filters-only hit must carry the canonical memo ID")
        expectParity("filters-only", filtered)
    }
}
}

// MARK: - SearchIndex parity (#827)

/// The indexed fast path must return byte-identical results to the legacy
/// disk-scanning path — the index is a cache, never a semantic fork. Every
/// test here runs BOTH paths over the same seeded vault and diffs them.
extension SearchServiceTests {
@Suite("SearchIndex parity")
@MainActor
struct SearchIndexParityTests {

    /// Comparable projection of a SearchResult (id is a fresh UUID per hit,
    /// so equality must be field-wise).
    private struct Hit: Equatable {
        let dateString: String
        let snippet: String
        let matchKind: SearchResult.MatchKind
        let memoType: Memo.MemoType?
        init(_ r: SearchResult) {
            dateString = r.dateString; snippet = r.snippet
            matchKind = r.matchKind; memoType = r.memoType
        }
    }

    private func seedMixedVault() throws -> URL {
        let tmp = try SearchServiceTests.makeTempVault()
        // Body match + diacritics
        try SearchServiceTests.writeMemo(
            Memo(type: .text, created: SearchServiceTests.makeDate(year: 2026, month: 4, day: 14),
                 body: "coffee at São Paulo, long afternoon"),
            dateString: "2026-04-14", to: tmp)
        // Voice memo whose match lives ONLY in the transcript
        try SearchServiceTests.writeMemo(
            Memo(type: .voice, created: SearchServiceTests.makeDate(year: 2026, month: 3, day: 2),
                 attachments: [Memo.Attachment(
                    file: "raw/assets/v.m4a", kind: "audio", duration: 4,
                    transcript: "meeting about the coffee roaster",
                    transcriptionStatus: .done)],
                 body: ""),
            dateString: "2026-03-02", to: tmp)
        // Location-only match
        try SearchServiceTests.writeMemo(
            Memo(type: .text, created: SearchServiceTests.makeDate(year: 2026, month: 2, day: 1),
                 location: Memo.Location(name: "Coffee Lab Chiang Mai", lat: 18.78, lng: 98.99),
                 body: "unrelated body text"),
            dateString: "2026-02-01", to: tmp)
        // Date-string match target
        try SearchServiceTests.writeMemo(
            Memo(type: .text, created: SearchServiceTests.makeDate(year: 2026, month: 1, day: 20),
                 body: "plain january note"),
            dateString: "2026-01-20", to: tmp)
        return tmp
    }

    @Test func indexedResultsMatchLegacyAcrossMatchKinds() throws {
        let tmp = try seedMixedVault()
        defer {
            SearchIndex.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tmp)
        }
        SearchIndex.shared.rebuildSynchronouslyForTesting(root: tmp)
        let docs = try #require(SearchIndex.shared.documentsIfBuilt())

        // Keywords covering: body, transcript, location, date, diacritic
        // folding, and a zero-hit query.
        for keyword in ["coffee", "roaster", "chiang mai", "2026-01", "sao paulo", "nothing-matches"] {
            let legacy = SearchService.search(keyword: keyword, root: tmp).map(Hit.init)
            let indexed = SearchService.search(keyword: keyword, in: docs, root: tmp).map(Hit.init)
            #expect(indexed == legacy, "fast path diverged from legacy for '\(keyword)'")
        }
    }

    @Test func indexedResultsMatchLegacyUnderFilters() throws {
        let tmp = try seedMixedVault()
        defer {
            SearchIndex.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tmp)
        }
        SearchIndex.shared.rebuildSynchronouslyForTesting(root: tmp)
        let docs = try #require(SearchIndex.shared.documentsIfBuilt())

        var typeFilter = SearchFilters.empty
        typeFilter.types = [.voice]
        var rangeFilter = SearchFilters.empty
        rangeFilter.startDate = SearchServiceTests.makeDate(year: 2026, month: 3, day: 1)
        var locFilter = SearchFilters.empty
        locFilter.locationQuery = "chiang"

        for (keyword, filters) in [("coffee", typeFilter), ("coffee", rangeFilter),
                                   ("", typeFilter), ("", locFilter)] {
            let legacy = SearchService.search(keyword: keyword, filters: filters, root: tmp).map(Hit.init)
            let indexed = SearchService.search(keyword: keyword, filters: filters, in: docs, root: tmp).map(Hit.init)
            #expect(indexed == legacy, "fast path diverged for '\(keyword)' + filters")
        }
    }

    @Test func documentsAreNilBeforeFirstBuild() throws {
        SearchIndex.shared.resetForTesting()
        #expect(SearchIndex.shared.documentsIfBuilt() == nil,
                "cold index reports nil until the asynchronous snapshot is ready")
    }

    @Test func rebuildPicksUpNewDay() throws {
        let tmp = try seedMixedVault()
        defer {
            SearchIndex.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tmp)
        }
        SearchIndex.shared.rebuildSynchronouslyForTesting(root: tmp)
        let before = SearchService.search(
            keyword: "freshly-added", in: SearchIndex.shared.documentsIfBuilt() ?? [], root: tmp)
        #expect(before.isEmpty)

        try SearchServiceTests.writeMemo(
            Memo(type: .text, created: SearchServiceTests.makeDate(year: 2026, month: 5, day: 5),
                 body: "freshly-added memo body"),
            dateString: "2026-05-05", to: tmp)
        SearchIndex.shared.rebuildSynchronouslyForTesting(root: tmp)

        let after = SearchService.search(
            keyword: "freshly-added", in: SearchIndex.shared.documentsIfBuilt() ?? [], root: tmp)
        #expect(after.count == 1)
        #expect(after.first?.dateString == "2026-05-05")
    }
}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias SearchServiceTests = DayPageSerialSwiftTests.SearchServiceTests
