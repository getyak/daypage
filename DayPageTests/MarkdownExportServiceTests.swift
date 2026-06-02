import Testing
@testable import DayPage

@Suite("MarkdownExportService")
struct MarkdownExportServiceTests {

    // MARK: - Helpers

    private func makeDate(year: Int = 2026, month: Int = 6, day: Int = 1) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = 10; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func makeMemo(
        body: String,
        mood: String? = nil,
        weather: String? = nil,
        entityMentions: [String] = [],
        secondsOffset: Double = 0
    ) -> Memo {
        Memo(
            id: UUID(),
            type: .text,
            created: Date(timeIntervalSinceReferenceDate: 800_000_000 + secondsOffset),
            weather: weather,
            mood: mood,
            entityMentions: entityMentions,
            body: body
        )
    }

    // MARK: - 1. Mood with embedded double-quote is escaped

    @Test func moodWithEmbeddedQuote_isEscapedInFrontmatter() {
        let memo = makeMemo(body: "test", mood: "feels like \"home\"")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        // Must contain the escaped form, not a raw unescaped quote
        #expect(content.contains("mood: \"feels like \\\"home\\\"\""))
    }

    @Test func entityWithEmbeddedQuote_isEscapedInFrontmatter() {
        let memo = makeMemo(body: "test", entityMentions: ["say \"hello\""])
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("\"say \\\"hello\\\"\""))
    }

    // MARK: - 2. Weather field appears when a memo carries weather

    @Test func frontmatter_containsWeatherLine_whenMemoHasWeather() {
        let memo = makeMemo(body: "test", weather: "晴 25°C")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("weather: \"晴 25°C\""))
    }

    @Test func frontmatter_omitsWeatherLine_whenNoMemoHasWeather() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(!content.contains("weather:"))
    }

    @Test func frontmatter_usesFirstNonEmptyWeather_fromMemos() {
        let m1 = makeMemo(body: "no weather", secondsOffset: 0)
        let m2 = makeMemo(body: "has weather", weather: "cloudy", secondsOffset: 10)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        #expect(content.contains("weather: \"cloudy\""))
    }

    // MARK: - 3. Summary blockquote

    @Test func summaryBlockquote_appearsUnderH1_whenSummarySupplied() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(), summary: "A great day."
        )
        // Blockquote line must follow the H1 heading
        let h1Range = content.range(of: "# DayPage —")
        let blockquoteRange = content.range(of: "> AI · A great day.")
        #expect(h1Range != nil)
        #expect(blockquoteRange != nil)
        if let h1 = h1Range, let bq = blockquoteRange {
            #expect(h1.lowerBound < bq.lowerBound)
        }
    }

    @Test func summaryBlockquote_isAbsent_whenSummaryIsNil() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(), summary: nil
        )
        #expect(!content.contains("> AI ·"))
    }

    @Test func summaryBlockquote_isAbsent_whenSummaryIsEmpty() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(), summary: ""
        )
        #expect(!content.contains("> AI ·"))
    }

    // MARK: - 4. Memo bodies ordered by created ascending

    @Test func memoBodies_orderedByCreatedAscending() {
        let m1 = makeMemo(body: "first", secondsOffset: 0)
        let m2 = makeMemo(body: "second", secondsOffset: 60)
        let m3 = makeMemo(body: "third", secondsOffset: 120)
        // Pass in reverse order — output must still be ascending
        let content = MarkdownExportService.buildExportContent(
            memos: [m3, m1, m2], date: makeDate()
        )
        let firstPos = content.range(of: "first")!.lowerBound
        let secondPos = content.range(of: "second")!.lowerBound
        let thirdPos = content.range(of: "third")!.lowerBound
        #expect(firstPos < secondPos)
        #expect(secondPos < thirdPos)
    }
}
