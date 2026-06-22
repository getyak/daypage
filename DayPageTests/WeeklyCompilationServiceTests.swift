// WeeklyCompilationServiceTests.swift — Round 7 (R7-FEATURE: 周回顾)
//
// Pure-function tests for ``WeeklyCompilationService``:
//   * ISO week key math at Monday/Sunday boundaries
//   * Metadata aggregation that ignores missing daily pages
//   * LLM response parsing (happy path + malformed JSON)
//   * Cache round-trip via `loadCached`
//
// LLM network paths are intentionally not exercised — they would require
// a live network and the production DeepSeek key. The static parser is
// the value at risk; the transport already has its own tests.

import Testing
import Foundation
@testable import DayPage

@MainActor
@Suite(.serialized)
struct WeeklyCompilationServiceTests {

    // MARK: - Fixture helpers

    private func makeDate(_ string: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.date(from: string)!
    }

    /// Stand up a private temp vault rooted at a fresh directory and
    /// point `VaultInitializer.testOverrideURL` at it. Caller cleans up.
    private func seedVault(with dailyPages: [(date: String, body: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("weekly-tests-\(UUID().uuidString)", isDirectory: true)
        let dailyDir = root.appendingPathComponent("wiki/daily", isDirectory: true)
        let weeklyDir = root.appendingPathComponent("wiki/weekly", isDirectory: true)
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: weeklyDir, withIntermediateDirectories: true)
        for page in dailyPages {
            let url = dailyDir.appendingPathComponent("\(page.date).md")
            try Data(page.body.utf8).write(to: url, options: .atomic)
        }
        VaultInitializer.testOverrideURL = root
        return root
    }

    private func teardownVault(_ root: URL) {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func dailyPageStub(date: String, mood: String, summary: String,
                               entities: [String], locations: [String]) -> String {
        let entitiesList = entities.map { "  - \($0)" }.joined(separator: "\n")
        let locationsList = locations.map { "  - \($0)" }.joined(separator: "\n")
        return """
        ---
        type: daily_page
        date: \(date)
        mood: \(mood)
        summary: \(summary)
        entities:
        \(entitiesList)
        locations:
        \(locationsList)
        ---

        # \(date)

        body text
        """
    }

    // MARK: - Tests

    @Test
    func isoWeekKeyForMondayAndSunday() {
        // 2026-06-22 is a Monday, 2026-06-28 is a Sunday. ISO week 26 of 2026.
        let monday = makeDate("2026-06-22")
        let sunday = makeDate("2026-06-28")
        #expect(WeeklyCompilationService.isoWeekKey(for: monday) == "2026-W26")
        #expect(WeeklyCompilationService.isoWeekKey(for: sunday) == "2026-W26")

        // A different week — sanity check the formatter handles single-digit
        // weeks with zero-padding.
        let earlyJan = makeDate("2026-01-05")  // ISO week 2 of 2026
        let earlyJanWeek = WeeklyCompilationService.isoWeekKey(for: earlyJan)
        #expect(earlyJanWeek.hasPrefix("2026-W"))
        #expect(earlyJanWeek.count == 8)  // "YYYY-Www" — 4+1+1+2 = 8
    }

    @Test
    func collectsAvailableDaysAndIgnoresMissing() throws {
        // Seed 5 of 7 days for the week containing 2026-06-22 (Mon-Fri).
        let pages: [(date: String, body: String)] = [
            ("2026-06-22", dailyPageStub(date: "2026-06-22", mood: "calm",
                                          summary: "Quiet Monday",
                                          entities: ["work"], locations: ["home"])),
            ("2026-06-23", dailyPageStub(date: "2026-06-23", mood: "focused",
                                          summary: "Code review day",
                                          entities: ["work", "code"], locations: ["office"])),
            ("2026-06-24", dailyPageStub(date: "2026-06-24", mood: "tired",
                                          summary: "Long meetings",
                                          entities: ["work"], locations: ["office"])),
            ("2026-06-25", dailyPageStub(date: "2026-06-25", mood: "energetic",
                                          summary: "Gym + lunch with friend",
                                          entities: ["fitness", "friend"],
                                          locations: ["gym", "cafe"])),
            ("2026-06-26", dailyPageStub(date: "2026-06-26", mood: "content",
                                          summary: "Wrapping up the week",
                                          entities: ["work"], locations: ["home"])),
            // 2026-06-27 (Sat) and 2026-06-28 (Sun) deliberately missing.
        ]
        let root = try seedVault(with: pages)
        defer { teardownVault(root) }

        let metadata = try WeeklyCompilationService.shared.collectWeekMetadata(
            for: makeDate("2026-06-24"))
        #expect(metadata.isoWeek == "2026-W26")
        #expect(metadata.days.count == 5)
        #expect(metadata.days.first?.date == "2026-06-22")
        #expect(metadata.days.first?.mood == "calm")
        #expect(metadata.days[3].entities == ["fitness", "friend"])
        #expect(metadata.days[3].locations == ["gym", "cafe"])
        #expect(metadata.weekStart == "2026-06-22")
    }

    @Test
    func parsesValidLLMResponse() throws {
        let raw = """
        ```json
        {
          "keywords": ["工作", "健身", "朋友"],
          "moodNotes": "从周一的疲惫逐步恢复，周末状态明显好转。",
          "placeNotes": "主要在家办公和咖啡馆。",
          "highlights": [
            "完成了一个重要的代码评审",
            "和老友吃了顿放松的午餐",
            "重新开始规律健身"
          ]
        }
        ```
        """
        let compiledAt = Date(timeIntervalSince1970: 1_750_000_000)
        let output = try WeeklyCompilationService.parse(
            llmResponse: raw,
            isoWeek: "2026-W26",
            weekStart: "2026-06-22",
            weekEnd: "2026-06-28",
            compiledAt: compiledAt
        )
        #expect(output.isoWeek == "2026-W26")
        #expect(output.dateRange == "2026-06-22 to 2026-06-28")
        #expect(output.keywords == ["工作", "健身", "朋友"])
        #expect(output.moodNotes.contains("周一"))
        #expect(output.placeNotes.contains("咖啡馆"))
        #expect(output.highlights.count == 3)
        #expect(output.compiledAt == compiledAt)
    }

    @Test
    func parseFailsOnMalformedJSON() {
        let raw = """
        ```json
        { keywords: not-json-here }
        ```
        """
        do {
            _ = try WeeklyCompilationService.parse(
                llmResponse: raw,
                isoWeek: "2026-W26",
                weekStart: "2026-06-22",
                weekEnd: "2026-06-28",
                compiledAt: Date()
            )
            Issue.record("expected parseFailed but parse succeeded")
        } catch let err as WeeklyCompilationError {
            switch err {
            case .parseFailed: break  // expected
            default:
                Issue.record("expected .parseFailed, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func parseFailsOnEmptyResponseFields() {
        let raw = """
        ```json
        { "keywords": [], "moodNotes": "", "placeNotes": "", "highlights": [] }
        ```
        """
        do {
            _ = try WeeklyCompilationService.parse(
                llmResponse: raw,
                isoWeek: "2026-W26",
                weekStart: "2026-06-22",
                weekEnd: "2026-06-28",
                compiledAt: Date()
            )
            Issue.record("expected parseFailed for all-empty payload")
        } catch let err as WeeklyCompilationError {
            switch err {
            case .parseFailed: break
            default: Issue.record("expected .parseFailed, got \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func loadCachedReadsExistingFile() throws {
        let root = try seedVault(with: [])
        defer { teardownVault(root) }

        // Synthesise a cached weekly recap file under wiki/weekly/.
        let output = WeeklyRecapOutput(
            isoWeek: "2026-W26",
            dateRange: "2026-06-22 to 2026-06-28",
            compiledAt: Date(timeIntervalSince1970: 1_750_000_000),
            keywords: ["工作", "健身", "朋友"],
            moodNotes: "从周一的疲惫逐步恢复。",
            placeNotes: "主要在家办公。",
            highlights: ["完成评审", "重启健身"]
        )
        let body = WeeklyCompilationService.renderMarkdown(output: output)
        let weeklyURL = root.appendingPathComponent("wiki/weekly/2026-W26.md")
        try Data(body.utf8).write(to: weeklyURL, options: .atomic)

        let loaded = WeeklyCompilationService.shared
            .loadCached(for: makeDate("2026-06-24"))
        #expect(loaded != nil)
        #expect(loaded?.isoWeek == "2026-W26")
        #expect(loaded?.keywords == ["工作", "健身", "朋友"])
        #expect(loaded?.highlights.count == 2)
        #expect(loaded?.moodNotes.contains("周一") == true)
    }

    @Test
    func loadCachedReturnsNilWhenAbsent() throws {
        let root = try seedVault(with: [])
        defer { teardownVault(root) }
        let loaded = WeeklyCompilationService.shared
            .loadCached(for: makeDate("2026-06-24"))
        #expect(loaded == nil)
    }

    @Test
    func extractListHandlesBlockAndInlineForms() {
        let block = """
        ---
        type: daily_page
        entities:
          - work
          - code
        ---
        """
        #expect(WeeklyCompilationService.extractList("entities", from: block)
                == ["work", "code"])

        let inline = """
        ---
        type: daily_page
        entities: [work, code, fitness]
        ---
        """
        #expect(WeeklyCompilationService.extractList("entities", from: inline)
                == ["work", "code", "fitness"])

        let missing = """
        ---
        type: daily_page
        ---
        """
        #expect(WeeklyCompilationService.extractList("entities", from: missing) == [])
    }
}
