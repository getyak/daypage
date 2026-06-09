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
        location: Memo.Location? = nil,
        secondsOffset: Double = 0
    ) -> Memo {
        Memo(
            id: UUID(),
            type: .text,
            created: Date(timeIntervalSinceReferenceDate: 800_000_000 + secondsOffset),
            location: location,
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

    @Test func frontmatter_explicitWeatherArg_overridesMemoWeather() {
        let memo = makeMemo(body: "test", weather: "晴 24°C")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(), weather: "阴 18°C"
        )
        #expect(content.contains("weather: \"阴 18°C\""))
        #expect(!content.contains("晴 24°C"))
    }

    @Test func frontmatter_weatherWithNewline_collapsesToSingleSpace() {
        let memo = makeMemo(body: "test", weather: "晴\n24°C")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        // The newline must be collapsed to a space, not emitted as a raw newline
        #expect(content.contains("weather: \"晴 24°C\""))
        let weatherLines = content.components(separatedBy: "\n").filter { $0.hasPrefix("weather:") }
        #expect(weatherLines.count == 1)
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

    // MARK: - Required design cases

    // (1) Frontmatter contains date / export_source / memo_count
    @Test func frontmatter_containsRequiredKeys() {
        let m1 = makeMemo(body: "a", secondsOffset: 0)
        let m2 = makeMemo(body: "b", secondsOffset: 10)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate(year: 2026, month: 6, day: 1)
        )
        #expect(content.contains("date: 2026-06-01"))
        #expect(content.contains("export_source: DayPage"))
        #expect(content.contains("memo_count: 2"))
    }

    // H1 heading uses long friendly date; YAML date: field keeps ISO form
    @Test func h1Heading_usesLongDate_yamlDateKeepsISO() {
        // June 8 2026 is a Monday
        let date = makeDate(year: 2026, month: 6, day: 8)
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(memos: [memo], date: date)

        // H1 must contain a long-format date (EEEE, MMMM d, yyyy)
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy"
        df.locale = Locale.current
        df.timeZone = AppSettings.currentTimeZone()
        let expected = df.string(from: date)
        #expect(content.contains("# DayPage — \(expected)"))

        // YAML date: must still be ISO yyyy-MM-dd
        #expect(content.contains("date: 2026-06-08"))
        // H1 must NOT contain the raw ISO date
        #expect(!content.contains("# DayPage — 2026-06-08"))
    }

    // (2) Multiline mood produces a single-line, valid `mood:` value with no raw newline
    @Test func multilineMood_producesOneLineFrontmatterValue() {
        let memo = makeMemo(body: "test", mood: "happy\nthen sad")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        // There must be exactly one line containing "mood:"
        let moodLines = content
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("mood:") }
        #expect(moodLines.count == 1)
        // That line must not contain a raw newline in the value (it's a single line by definition,
        // but confirm the value itself doesn't embed \n after unescaping)
        let moodLine = moodLines[0]
        // The raw newline in the original mood must have become a space, not \n
        #expect(!moodLine.contains("\n"))
        #expect(moodLine.contains("mood:"))
        // The value should still carry both parts joined by a space
        #expect(content.contains("mood: \"happy then sad\""))
    }

    // (3) entity_mentions are de-duplicated and sorted
    @Test func entityMentions_dedupedAndSorted() {
        let m1 = makeMemo(body: "a", entityMentions: ["Zara", "Alice", "Zara"])
        let m2 = makeMemo(body: "b", entityMentions: ["Alice", "Bob"])
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        // Extract entity_mentions block
        let aliceRange = content.range(of: "\"Alice\"")
        let bobRange   = content.range(of: "\"Bob\"")
        let zaraRange  = content.range(of: "\"Zara\"")
        #expect(aliceRange != nil)
        #expect(bobRange != nil)
        #expect(zaraRange != nil)
        // Sorted: Alice < Bob < Zara
        if let a = aliceRange, let b = bobRange, let z = zaraRange {
            #expect(a.lowerBound < b.lowerBound)
            #expect(b.lowerBound < z.lowerBound)
        }
        // De-duplicated: "Zara" appears exactly once in entity_mentions block
        let entitySection = content.components(separatedBy: "entity_mentions:").last ?? ""
        let zaraCount = entitySection.components(separatedBy: "\"Zara\"").count - 1
        #expect(zaraCount == 1)
    }

    // (4) Empty entities emit `entity_mentions: []`
    @Test func emptyEntities_emitEmptyArray() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("entity_mentions: []"))
    }

    // (5) Attachment kinds map to the correct wikilink form
    @Test func attachmentKinds_mapToCorrectWikilinkForm() {
        let photoAtt  = Memo.Attachment(file: "raw/assets/photo.jpg", kind: "photo")
        let audioAtt  = Memo.Attachment(file: "raw/assets/voice.m4a", kind: "audio",
                                        transcript: "hello world")
        let otherAtt  = Memo.Attachment(file: "raw/assets/doc.pdf",  kind: "document")
        let memo = Memo(
            id: UUID(),
            type: .mixed,
            created: Date(timeIntervalSinceReferenceDate: 800_000_000),
            attachments: [photoAtt, audioAtt, otherAtt],
            body: "with attachments"
        )
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        // Photo → ![[...]]
        #expect(content.contains("![[vault/raw/assets/photo.jpg]]"))
        // Audio → ![[...]] with transcript appended
        #expect(content.contains("![[vault/raw/assets/voice.m4a]]"))
        #expect(content.contains("*(transcript: hello world)*"))
        // Other → [[...]] (no !)
        #expect(content.contains("[[vault/raw/assets/doc.pdf]]"))
        #expect(!content.contains("![[vault/raw/assets/doc.pdf]]"))
    }

    // (6) Summary line is prefixed with `> AI · `
    @Test func summaryLine_isPrefixedWithBlockquoteAndAI() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(), summary: "Productive day."
        )
        #expect(content.contains("> AI · Productive day."))
    }

    // MARK: - locations frontmatter

    private func makeMemoWithLocation(
        body: String,
        locationName: String?,
        secondsOffset: Double = 0
    ) -> Memo {
        let loc = locationName.map { Memo.Location(name: $0) }
        return Memo(
            id: UUID(),
            type: .text,
            created: Date(timeIntervalSinceReferenceDate: 800_000_000 + secondsOffset),
            location: loc,
            body: body
        )
    }

    @Test func locations_deduped_whenTwoMemosShareSameLocation() {
        let m1 = makeMemoWithLocation(body: "a", locationName: "Tokyo", secondsOffset: 0)
        let m2 = makeMemoWithLocation(body: "b", locationName: "Tokyo", secondsOffset: 10)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        // "Tokyo" must appear exactly once in the locations block
        let locationSection = content.components(separatedBy: "locations:").last ?? ""
        let tokyoCount = locationSection.components(separatedBy: "\"Tokyo\"").count - 1
        #expect(tokyoCount == 1)
        #expect(!content.contains("locations: []"))
    }

    @Test func locations_sorted_whenMultipleDistinctLocations() {
        let m1 = makeMemoWithLocation(body: "a", locationName: "Zurich", secondsOffset: 0)
        let m2 = makeMemoWithLocation(body: "b", locationName: "Amsterdam", secondsOffset: 10)
        let m3 = makeMemoWithLocation(body: "c", locationName: "Berlin", secondsOffset: 20)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2, m3], date: makeDate()
        )
        let aRange = content.range(of: "\"Amsterdam\"")!
        let bRange = content.range(of: "\"Berlin\"")!
        let zRange = content.range(of: "\"Zurich\"")!
        #expect(aRange.lowerBound < bRange.lowerBound)
        #expect(bRange.lowerBound < zRange.lowerBound)
    }

    @Test func locations_yamlSpecialChars_areEscaped() {
        let m = makeMemoWithLocation(body: "a", locationName: "O'ahu \"Hawaii\"")
        let content = MarkdownExportService.buildExportContent(
            memos: [m], date: makeDate()
        )
        #expect(content.contains("\"O'ahu \\\"Hawaii\\\"\""))
    }

    @Test func locations_emptyArray_whenNoGeotaggedMemos() {
        let m1 = makeMemo(body: "no location")
        let m2 = makeMemoWithLocation(body: "explicit nil", locationName: nil)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        #expect(content.contains("locations: []"))
    }

    // MARK: - 4. writeExportFile produces a branded filename

    @Test func writeExportFile_producesURLWithBrandedFilename() throws {
        let date = makeDate(year: 2026, month: 6, day: 2)
        let dateString = MarkdownExportService.exportDateString(for: date)
        let content = MarkdownExportService.buildExportContent(
            memos: [makeMemo(body: "test")], date: date
        )
        let url = try MarkdownExportService.writeExportFile(content: content, dateString: dateString)
        #expect(url.lastPathComponent == "DayPage \(dateString).md")
    }

    // MARK: - 5. purgeStaleExports removes old files, keeps fresh ones

    @Test func purgeStaleExports_removesOldFile_keepsNewFile() throws {
        let fm = FileManager.default
        let dir = MarkdownExportService.exportDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let staleURL = dir.appendingPathComponent("DayPage 2026-01-01.md")
        let freshURL = dir.appendingPathComponent("DayPage 2026-06-01.md")

        try "stale content".write(to: staleURL, atomically: true, encoding: .utf8)
        try "fresh content".write(to: freshURL, atomically: true, encoding: .utf8)

        // Backdate the stale file to 48 hours ago
        let now = Date()
        let staleDate = now.addingTimeInterval(-48 * 3600)
        try fm.setAttributes([.modificationDate: staleDate], ofItemAtPath: staleURL.path)
        // Keep the fresh file's modification date at now (default after write)

        MarkdownExportService.purgeStaleExports(olderThan: 86_400, now: now)

        #expect(!fm.fileExists(atPath: staleURL.path), "Stale file should have been removed")
        #expect(fm.fileExists(atPath: freshURL.path), "Fresh file should still exist")

        // Cleanup
        try? fm.removeItem(at: freshURL)
    }

    // MARK: - 6. writeExportFile twice returns valid URL for current date

    @Test func writeExportFileTwice_returnsValidURL() throws {
        let date = makeDate(year: 2026, month: 6, day: 2)
        let dateString = MarkdownExportService.exportDateString(for: date)
        let content = MarkdownExportService.buildExportContent(
            memos: [makeMemo(body: "round1")], date: date
        )
        let url1 = try MarkdownExportService.writeExportFile(content: content, dateString: dateString)
        let content2 = MarkdownExportService.buildExportContent(
            memos: [makeMemo(body: "round2")], date: date
        )
        let url2 = try MarkdownExportService.writeExportFile(content: content2, dateString: dateString)
        let text = try String(contentsOf: url2, encoding: .utf8)
        #expect(text.contains("round2"))
        #expect(url1.lastPathComponent == url2.lastPathComponent)
    }

    // MARK: - Capture-stats footer

    @Test func frontmatter_containsExportWordCount_summedFromTwoMemos() {
        let m1 = makeMemo(body: "hello world", secondsOffset: 0)
        let m2 = makeMemo(body: "foo bar baz", secondsOffset: 60)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        #expect(content.contains("export_word_count: 5"))
    }

    @Test func summarySection_containsMemoCountWordCountAndTimeSpan() {
        let m1 = makeMemo(body: "hello world", secondsOffset: 0)
        let m2 = makeMemo(body: "foo bar baz", secondsOffset: 3600)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        #expect(content.contains("## Summary"))
        #expect(content.contains("> 2 memos"))
        #expect(content.contains("> 5 words"))
        let summaryRange = content.range(of: "## Summary")
        #expect(summaryRange != nil)
        if let r = summaryRange {
            let tail = String(content[r.lowerBound...])
            #expect(tail.contains(" – "))
        }
    }

    @Test func emptyMemos_producesNoSummaryFooter_andZeroWordCount() {
        let content = MarkdownExportService.buildExportContent(
            memos: [], date: makeDate()
        )
        #expect(content.contains("export_word_count: 0"))
        #expect(!content.contains("## Summary"))
    }

    // MARK: - Long date title and time_range frontmatter

    @Test func titleLine_containsWeekdayName() {
        let memo = makeMemo(body: "test", secondsOffset: 0)
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(year: 2026, month: 6, day: 1)
        )
        #expect(content.contains("# DayPage — Monday"))
    }

    @Test func titleLine_containsFullLongDate() {
        let memo = makeMemo(body: "test", secondsOffset: 0)
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(year: 2026, month: 6, day: 8)
        )
        #expect(content.contains("# DayPage — Monday, 8 June 2026"))
    }

    @Test func frontmatter_containsTimeRange_forMultipleMemos() {
        let m1 = makeMemo(body: "first", secondsOffset: 0)
        let m2 = makeMemo(body: "last", secondsOffset: 3600)
        let content = MarkdownExportService.buildExportContent(
            memos: [m1, m2], date: makeDate()
        )
        let frontmatterEnd = content.range(of: "\n---\n", range: content.range(of: "---\n")!.upperBound..<content.endIndex)
        #expect(frontmatterEnd != nil)
        if let fmEnd = frontmatterEnd {
            let frontmatter = String(content[content.startIndex..<fmEnd.upperBound])
            #expect(frontmatter.contains("time_range:"))
            #expect(frontmatter.contains(" – "))
        }
    }

    @Test func frontmatter_omitsTimeRange_forEmptyMemos() {
        let content = MarkdownExportService.buildExportContent(
            memos: [], date: makeDate()
        )
        #expect(!content.contains("time_range:"))
    }

    @Test func frontmatter_isoDateUnchanged_withLongTitle() {
        let memo = makeMemo(body: "test", secondsOffset: 0)
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate(year: 2026, month: 6, day: 8)
        )
        #expect(content.contains("date: 2026-06-08"))
    }

    // MARK: - 8. Entity tag line

    @Test func entityTagLine_appearsUnderH1_forEntityBearingMemos() {
        let memo = makeMemo(body: "test", entityMentions: ["Coffee Shop", "Anna"])
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("#coffee-shop"))
        #expect(content.contains("#anna"))
        let h1Range = content.range(of: "# DayPage —")!
        let tagRange = content.range(of: "#coffee-shop")!
        #expect(h1Range.upperBound < tagRange.lowerBound)
    }

    @Test func entityTagLine_isAbsent_whenEntitiesEmpty() {
        let memo = makeMemo(body: "test")
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        let afterH1 = content.components(separatedBy: "# DayPage —").last ?? ""
        let bodyContent = afterH1.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        #expect(!bodyContent.contains(try! #/^#\w/#))
    }

    @Test func entitySlug_replacesSpacesWithHyphens_andLowercases() {
        let memo = makeMemo(body: "test", entityMentions: ["New York City"])
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("#new-york-city"))
        #expect(!content.contains("#New York City"))
    }

    // MARK: - 9. Location coordinates

    @Test func locationLine_includesCoords_with5DecimalPrecision() {
        let loc = Memo.Location(name: "Tokyo Station", lat: 35.0123456, lng: 139.987654)
        let memo = makeMemo(body: "test", location: loc)
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("> 📍 Tokyo Station (35.01235, 139.98765)"))
    }

    @Test func locationLine_omitsCoords_whenLatLonAbsent() {
        let loc = Memo.Location(name: "Unknown Place", lat: nil, lng: nil)
        let memo = makeMemo(body: "test", location: loc)
        let content = MarkdownExportService.buildExportContent(
            memos: [memo], date: makeDate()
        )
        #expect(content.contains("> 📍 Unknown Place"))
        #expect(!content.contains("("))
    }

    // MARK: - 7. Memo bodies ordered by created ascending

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
