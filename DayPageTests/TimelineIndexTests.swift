import XCTest
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Unit tests for TimelineIndex — the in-memory timeline metadata cache from
/// issue #345. Verifies:
///  - rebuild produces the same result as the underlying full scan
///  - incremental update/remove keeps the index consistent with a full rebuild
///  - external additions and edits are detected from per-file metadata
///  - empty / single-day / no-summary edge cases
///
/// TimelineIndex is a @MainActor singleton, so tests run on the main actor and
/// use the `*ForTesting` hooks to make rebuild deterministic (no waiting on a
/// background Task).
@MainActor
final class TimelineIndexTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("TimelineIndexTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tempDir.appendingPathComponent("wiki/daily"), withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
        TimelineIndex.shared.resetForTesting()
    }

    override func tearDownWithError() throws {
        TimelineIndex.shared.resetForTesting()
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - rebuild correctness

    func testRebuild_matchesFullScan() throws {
        writeDay("2026-05-01", memoCount: 2)
        writeDay("2026-05-03", memoCount: 1)
        writeDay("2026-05-02", memoCount: 5)

        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let indexed = TimelineIndex.shared.entries()
        let scanned = TimelineService.scanAllEntries()

        XCTAssertEqual(indexed, scanned,
                       "Index entries must equal a full scan after rebuild")
    }

    func testEntries_newestFirst() throws {
        writeDay("2026-05-01", memoCount: 1)
        writeDay("2026-05-10", memoCount: 1)
        writeDay("2026-05-05", memoCount: 1)

        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let dates = TimelineIndex.shared.entries().map { $0.dateString }
        XCTAssertEqual(dates, ["2026-05-10", "2026-05-05", "2026-05-01"],
                       "Entries must be sorted newest-first")
    }

    func testEntries_carriesMemoCountAndSummary() throws {
        writeDay("2026-05-01", memoCount: 3)
        writeDailySummary("2026-05-01", summary: "今天写了代码")

        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let entry = try XCTUnwrap(TimelineIndex.shared.entries().first)
        XCTAssertEqual(entry.memoCount, 3)
        XCTAssertEqual(entry.summary, "今天写了代码")
        XCTAssertEqual(entry.previewLines.count, 3)
        XCTAssertEqual(entry.previewLines.first, "memo 2 for 2026-05-01")
    }

    func testEntries_noSummaryWhenUncompiled() throws {
        writeDay("2026-05-01", memoCount: 1)
        // no daily file written
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let entry = try XCTUnwrap(TimelineIndex.shared.entries().first)
        XCTAssertNil(entry.summary, "summary must be nil when the day is not compiled")
    }

    // MARK: - cold path (entries before first build)

    func testEntries_coldPath_returnsImmediatelyThenPublishesSnapshot() async throws {
        writeDay("2026-05-01", memoCount: 2)
        let update = expectation(description: "background index rebuild completes")
        let token = NotificationCenter.default.addObserver(
            forName: .timelineIndexDidUpdate, object: nil, queue: .main
        ) { _ in update.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        // Do NOT call rebuild — exercise the not-yet-built cold path. The read
        // must not synchronously parse the Vault on the MainActor.
        let entries = TimelineIndex.shared.entries()
        XCTAssertTrue(entries.isEmpty, "Cold-path read returns the last snapshot without blocking")
        XCTAssertFalse(TimelineIndex.shared.isReady)

        await TimelineIndex.shared.waitUntilIdleForTesting()
        await fulfillment(of: [update], timeout: 1)
        XCTAssertTrue(TimelineIndex.shared.isReady)
        XCTAssertEqual(TimelineIndex.shared.entries().first?.memoCount, 2)
    }

    // MARK: - incremental update consistency

    func testIncrementalAppend_matchesRebuild() async throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()

        // Simulate a new day's write going through RawStorage's notification.
        writeDay("2026-05-02", memoCount: 4)
        await waitForIndexUpdate {
            postDidWrite(forDateString: "2026-05-02")
        }

        let afterIncremental = TimelineIndex.shared.entries()
        // Independent full rebuild as the source of truth.
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let afterFullRebuild = TimelineIndex.shared.entries()

        XCTAssertEqual(afterIncremental, afterFullRebuild,
                       "Incremental append must match a full rebuild")
        XCTAssertEqual(afterIncremental.count, 2)
    }

    func testIncrementalUpdate_changesMemoCount() async throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().first?.memoCount, 1)

        // Rewrite the same day with more memos (like adding a memo).
        writeDay("2026-05-01", memoCount: 6)
        await waitForIndexUpdate {
            postDidWrite(forDateString: "2026-05-01")
        }

        XCTAssertEqual(TimelineIndex.shared.entries().first?.memoCount, 6,
                       "Incremental update must reflect the new memo count")
    }

    func testIncrementalRemove_dropsEmptyDay() async throws {
        writeDay("2026-05-01", memoCount: 1)
        writeDay("2026-05-02", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().count, 2)

        // Delete the day file entirely (like deleting the last memo).
        try fm.removeItem(at: rawURL("2026-05-01"))
        await waitForIndexUpdate {
            postDidWrite(forDateString: "2026-05-01")
        }

        let remaining = TimelineIndex.shared.entries()
        XCTAssertEqual(remaining.count, 1, "Removed day must drop out of the index")
        XCTAssertEqual(remaining.first?.dateString, "2026-05-02")
    }

    // MARK: - external modification detection

    func testExternalWrite_isDetectedOnForegroundRefresh() async throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().count, 1)

        // Simulate iCloud/Obsidian adding a file without RawStorage's write
        // notification. Foreground validation must discover and rebuild it.
        writeDay("2026-05-02", memoCount: 1)
        await waitForIndexUpdate {
            TimelineIndex.shared.refreshIfExternallyModified()
        }
        XCTAssertEqual(TimelineIndex.shared.entries().count, 2,
                       "Foreground rebuild must include an externally added day")
    }

    func testExternalEditOfExistingFile_isDetectedWithoutDirectoryMtimeChange() async throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()

        // Editing an existing child does not reliably change raw/'s directory
        // mtime. The file signature changes because both size and file mtime
        // are tracked, so this must still refresh from one memo to four.
        writeDay("2026-05-01", memoCount: 4)
        await waitForIndexUpdate {
            TimelineIndex.shared.refreshIfExternallyModified()
        }

        XCTAssertEqual(TimelineIndex.shared.entries().first?.memoCount, 4)
    }

    // MARK: - empty vault

    func testEntries_emptyVault_returnsEmpty() throws {
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertTrue(TimelineIndex.shared.entries().isEmpty,
                      "Empty vault must yield no entries")
    }

    // MARK: - Canonical timeline date presentation (native19 residual repair)
    //
    // Settled semantics under test: the owning `yyyy-MM-dd` file key is
    // Gregorian civil identity; `TimelineService.group` classifies strictly by
    // that key with one explicit per-call zone snapshot + injectable
    // firstWeekday, fails closed on malformed keys, excludes the exact current
    // canonical day, and orders pinned/month sections newest-first by
    // canonical key. Cached `TimelineDayEntry.date` values are scan artifacts
    // and must never leak into classification or labels.

    /// Warm Shanghai-scanned cache (deliberately stale `date` midnights) must
    /// classify identically under +14 / LA / Shanghai reference snapshots,
    /// with exact identities/counts/summary preserved and raw bytes untouched.
    func testGroup_warmShanghaiCache_stableUnderKiritimatiLosAngelesShanghaiSnapshots() throws {
        // Scrambled input order; one entry carries a completely bogus date.
        let keys = [
            "2026-09-18", "2024-02-29", "2026-10-03", "2011-12-30", "2026-10-04",
            "2026-08-01", "2026-09-25", "2025-12-31", "2026-10-02", "2026-08-31",
            "2026-09-30",
        ]
        func warmEntries(scannedIn: String?) -> [TimelineDayEntry] {
            keys.enumerated().map { index, key in
                makeEntry(
                    key,
                    memos: index + 1,
                    summary: "summary-\(key)",
                    date: scannedIn.map { scannedMidnight(key, zoneIdentifier: $0) }
                        ?? Date(timeIntervalSince1970: 0)
                )
            }
        }

        // Real raw files so byte-level non-mutation is observable.
        writeDay("2026-10-03", memoCount: 2)
        writeDay("2025-12-31", memoCount: 1)
        writeDailySummary("2025-12-31", summary: "年终")
        let rawBefore = rawBytesSnapshot()
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let indexBefore = TimelineIndex.shared.entries()
        XCTAssertEqual(Set(rawBefore.keys), Set(["2026-10-03.md", "2025-12-31.md"]))
        XCTAssertTrue(rawBefore.values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(indexBefore.map(\.dateString)), Set(["2026-10-03", "2025-12-31"]))
        XCTAssertEqual(indexBefore.first { $0.dateString == "2026-10-03" }?.memoCount, 2)
        XCTAssertEqual(indexBefore.first { $0.dateString == "2025-12-31" }?.memoCount, 1)
        XCTAssertEqual(indexBefore.first { $0.dateString == "2025-12-31" }?.summary, "年终")

        // Reference instant 2026-10-03 11:00Z:
        //   Shanghai / LA  → civil today 2026-10-03
        //   Kiritimati     → civil today 2026-10-04
        // Week starts Monday (firstWeekday 2) for determinism.
        let expectedShanghai = [
            "thisWeekOthers:[2026-10-04,2026-10-02,2026-09-30]",
            "lastWeek:[2026-09-25]",
            "weekBeforeLast:[2026-09-18]",
            "month:[2026-08-31,2026-08-01]",
            "month:[2025-12-31]",
            "month:[2024-02-29]",
            "month:[2011-12-30]",
        ]
        let expectedKiritimati = [
            "thisWeekOthers:[2026-10-03,2026-10-02,2026-09-30]",
            "lastWeek:[2026-09-25]",
            "weekBeforeLast:[2026-09-18]",
            "month:[2026-08-31,2026-08-01]",
            "month:[2025-12-31]",
            "month:[2024-02-29]",
            "month:[2011-12-30]",
        ]

        for scannedIn in ["Asia/Shanghai", "America/Los_Angeles", "Pacific/Kiritimati", nil] as [String?] {
            let warm = warmEntries(scannedIn: scannedIn)
            for (zoneID, expected) in [
                ("Asia/Shanghai", expectedShanghai),
                ("America/Los_Angeles", expectedShanghai),
                ("Pacific/Kiritimati", expectedKiritimati),
            ] {
                let sections = TimelineService.group(
                    entries: warm,
                    referenceDate: fixedReferenceInstant,
                    timeZone: zone(zoneID),
                    firstWeekday: 2
                )
                XCTAssertEqual(layoutSignature(sections), expected,
                               "stale-date variant \(scannedIn ?? "epoch") grouped under \(zoneID)")
                assertEntriesPreserved(sections, against: warm)
            }
        }

        // Grouping is pure presentation: nothing on disk or in the warm index
        // may change because a zone snapshot was applied.
        XCTAssertEqual(rawBytesSnapshot(), rawBefore, "raw bytes must be unchanged")
        XCTAssertEqual(TimelineIndex.shared.entries(), indexBefore,
                       "warm index identities/counts/summary must be unchanged")

        // Existing public call shape (default zone + default firstWeekday) stays valid.
        let defaultSections = TimelineService.group(
            entries: warmEntries(scannedIn: "Asia/Shanghai"),
            referenceDate: fixedReferenceInstant
        )
        let inputKeys = Set(keys)
        for section in defaultSections {
            for day in section.days { XCTAssertTrue(inputKeys.contains(day.dateString)) }
        }
    }

    /// The exact current canonical day is excluded per zone snapshot: at
    /// 2026-10-03 11:00Z Kiritimati is already Oct 4 while Shanghai/LA are
    /// still Oct 3 — the excluded day must follow the snapshot, never the
    /// cached entry dates.
    func testGroup_canonicalTodayBoundary_oct4VersusOct3_followsZoneSnapshot() throws {
        let warm = [
            makeEntry("2026-10-04", date: scannedMidnight("2026-10-04", zoneIdentifier: "Asia/Shanghai")),
            makeEntry("2026-10-03", date: scannedMidnight("2026-10-03", zoneIdentifier: "Asia/Shanghai")),
        ]

        func visibleKeys(_ zoneID: String) -> [String] {
            let sections = TimelineService.group(
                entries: warm,
                referenceDate: fixedReferenceInstant,
                timeZone: zone(zoneID),
                firstWeekday: 2
            )
            return sections.flatMap { $0.days.map { $0.dateString } }
        }

        XCTAssertEqual(visibleKeys("Pacific/Kiritimati"), ["2026-10-03"],
                       "+14 snapshot: Oct 4 is today and must be excluded")
        XCTAssertEqual(visibleKeys("Asia/Shanghai"), ["2026-10-04"],
                       "Shanghai snapshot: Oct 3 is today and must be excluded")
        XCTAssertEqual(visibleKeys("America/Los_Angeles"), ["2026-10-04"],
                       "LA snapshot: Oct 3 is today and must be excluded")
    }

    /// firstWeekday is injectable and moves the week-band boundary exactly as
    /// the reference calendar says (Monday-start vs Sunday-start weeks).
    func testGroup_firstWeekdayInjection_movesWeekBandBoundary() throws {
        let warm = [
            makeEntry("2026-10-04", date: scannedMidnight("2026-10-04", zoneIdentifier: "Asia/Shanghai")),
            makeEntry("2026-10-03", date: scannedMidnight("2026-10-03", zoneIdentifier: "Asia/Shanghai")),
            makeEntry("2026-10-02", date: scannedMidnight("2026-10-02", zoneIdentifier: "Asia/Shanghai")),
            makeEntry("2026-09-30", date: scannedMidnight("2026-09-30", zoneIdentifier: "Asia/Shanghai")),
            makeEntry("2026-09-28", date: scannedMidnight("2026-09-28", zoneIdentifier: "Asia/Shanghai")),
        ]
        // Shanghai snapshot at 2026-10-04 02:00Z → civil today 2026-10-04.
        let reference = utc(2026, 10, 4, 2)

        let mondayStart = TimelineService.group(
            entries: warm, referenceDate: reference,
            timeZone: zone("Asia/Shanghai"), firstWeekday: 2
        )
        XCTAssertEqual(layoutSignature(mondayStart), [
            "thisWeekOthers:[2026-10-03,2026-10-02,2026-09-30,2026-09-28]",
        ], "Monday-start week of Sun Oct 4 begins Sep 28")

        let sundayStart = TimelineService.group(
            entries: warm, referenceDate: reference,
            timeZone: zone("Asia/Shanghai"), firstWeekday: 1
        )
        XCTAssertEqual(layoutSignature(sundayStart), [
            "lastWeek:[2026-10-03,2026-10-02,2026-09-30,2026-09-28]",
        ], "Sunday-start week of Sun Oct 4 begins Oct 4, pushing the same days to last week")
    }

    /// Pinned days surface newest-first by canonical key and leave their
    /// natural band — even when the cached dates are stale/scrambled.
    func testGroup_pinned_newestFirstByCanonicalKey_andOutOfNaturalBand() throws {
        let warm = [
            makeEntry("2026-08-31", date: Date(timeIntervalSince1970: 0)),
            makeEntry("2026-09-25", date: scannedMidnight("2026-08-01", zoneIdentifier: "Pacific/Kiritimati")),
            makeEntry("2026-10-03", date: scannedMidnight("2026-10-03", zoneIdentifier: "Asia/Shanghai")),
            makeEntry("2026-08-01", date: scannedMidnight("2026-09-25", zoneIdentifier: "America/Los_Angeles")),
        ]
        let sections = TimelineService.group(
            entries: warm,
            referenceDate: fixedReferenceInstant,
            pinnedDateStrings: ["2026-08-01", "2026-09-25"],
            timeZone: zone("Asia/Shanghai"),
            firstWeekday: 2
        )
        XCTAssertEqual(layoutSignature(sections), [
            "pinned:[2026-09-25,2026-08-01]",
            "month:[2026-08-31]",
        ], "pinned newest-first by canonical key; 2026-09-25 leaves last week; Oct 3 is today")
        XCTAssertEqual(sections.first?.kind, TimelineSectionKind.pinned, "pinned section leads")
    }

    /// Month buckets are the owning civil month (neutral payload), newest
    /// first across month/year boundaries, including leap day and the
    /// Apia-skipped civil day 2011-12-30.
    func testGroup_monthBuckets_owningCivilMonth_crossYearLeapDayApia_newestFirst() throws {
        let warm = [
            makeEntry("2024-02-29", date: Date(timeIntervalSince1970: 0)),
            makeEntry("2011-12-30", date: Date(timeIntervalSince1970: 0)),
            makeEntry("2026-01-01", date: Date(timeIntervalSince1970: 0)),
            makeEntry("2026-08-15", date: Date(timeIntervalSince1970: 0)),
            makeEntry("2025-12-31", date: Date(timeIntervalSince1970: 0)),
            makeEntry("2026-08-01", date: Date(timeIntervalSince1970: 0)),
        ]
        let sections = TimelineService.group(
            entries: warm,
            referenceDate: utc(2026, 10, 4, 2),
            timeZone: zone("Asia/Shanghai"),
            firstWeekday: 2
        )
        XCTAssertEqual(layoutSignature(sections), [
            "month:[2026-08-15,2026-08-01]",
            "month:[2026-01-01]",
            "month:[2025-12-31]",
            "month:[2024-02-29]",
            "month:[2011-12-30]",
        ])

        // Payloads are neutral civil month starts — never zone-shifted.
        let payloads: [Date] = sections.compactMap { section in
            guard case .month(let start) = section.kind else { return nil }
            return start
        }
        XCTAssertEqual(payloads, [
            utc(2026, 8, 1), utc(2026, 1, 1), utc(2025, 12, 1), utc(2024, 2, 1), utc(2011, 12, 1),
        ])

        // The month display renders exactly that owning civil month.
        let headers = payloads.map {
            TimelineDayDisplay.monthHeader(forMonthStart: $0, locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(headers, [
            "August 2026", "January 2026", "December 2025", "February 2024", "December 2011",
        ])
    }

    /// Malformed canonical keys fail closed — dropped, never guessed into a day.
    func testGroup_malformedCanonicalKeys_failClosed() throws {
        let malformed = [
            "2026-02-30", "2025-02-29", "2026-13-01", "2026-00-10", "2026-10-00",
            "2026-10-3", "2026-1-03", "2026-10", "2026-10-03T00:00:00Z", "20261003",
            " 2026-10-03", "2026-10-03 ", "", "garbage",
        ]
        var warm = malformed.map { makeEntry($0, date: Date(timeIntervalSince1970: 0)) }
        warm.append(makeEntry("2026-08-15", date: Date(timeIntervalSince1970: 0)))

        let sections = TimelineService.group(
            entries: warm,
            referenceDate: utc(2026, 10, 4, 2),
            timeZone: zone("Asia/Shanghai"),
            firstWeekday: 2
        )
        XCTAssertEqual(layoutSignature(sections), ["month:[2026-08-15]"],
                       "only the canonical key classifies; everything malformed fails closed")
    }

    /// Labels follow the strict canonical key even when the entry's cached
    /// `date` describes another day entirely (and under any zone variant).
    func testTimelineDayDisplay_labelsFollowCanonicalKey_despiteConflictingEntryDates() throws {
        let key = "2026-10-03"
        let conflicting = [
            makeEntry(key, date: scannedMidnight(key, zoneIdentifier: "Asia/Shanghai")),
            makeEntry(key, date: scannedMidnight("2026-10-01", zoneIdentifier: "America/Los_Angeles")),
            makeEntry(key, date: Date(timeIntervalSince1970: 0)),
        ]
        let expected = TimelineDayDisplay.DayLabels(weekday: "SAT", monthDay: "10.03", dayNumber: "03")
        for entry in conflicting {
            XCTAssertEqual(TimelineDayDisplay.dayLabels(forDayKey: entry.dateString), expected,
                           "labels must derive from the key, not from entry.date \(entry.date)")
        }
        XCTAssertEqual(TimelineDayDisplay.dayLabels(forDayKey: "2026-10-04"),
                       TimelineDayDisplay.DayLabels(weekday: "SUN", monthDay: "10.04", dayNumber: "04"))
        XCTAssertNil(TimelineDayDisplay.dayLabels(forDayKey: "2026-02-30"), "fail closed")
        XCTAssertNil(TimelineDayDisplay.dayLabels(forDayKey: "garbage"), "fail closed")
    }

    /// The Apia-skipped civil day 2011-12-30 still owns valid labels, and the
    /// localized month header keeps the civil month of its neutral payload
    /// (a month-first instant can never render as the previous month).
    func testTimelineDayDisplay_apiaSkippedDay_labelsAndMonthHeaderKeepsCivilMonth() throws {
        XCTAssertEqual(TimelineDayDisplay.dayLabels(forDayKey: "2011-12-30"),
                       TimelineDayDisplay.DayLabels(weekday: "FRI", monthDay: "12.30", dayNumber: "30"),
                       "2011-12-30 never existed as a local midnight in Pacific/Apia but owns its file day")

        let enUS = Locale(identifier: "en_US")
        XCTAssertEqual(TimelineDayDisplay.monthHeader(forMonthStart: utc(2026, 10, 1), locale: enUS),
                       "October 2026")
        XCTAssertEqual(TimelineDayDisplay.monthHeader(forMonthStart: utc(2025, 12, 1), locale: enUS),
                       "December 2025")
        XCTAssertEqual(TimelineDayDisplay.monthHeader(forMonthStart: utc(2011, 12, 1), locale: enUS),
                       "December 2011")

        // Locale calendar preferences must not change the owning Gregorian month/year.
        for localeID in ["en_US@calendar=islamic", "en_US@calendar=buddhist"] {
            let locale = Locale(identifier: localeID)
            XCTAssertEqual(TimelineDayDisplay.monthHeader(forMonthStart: utc(2011, 12, 1), locale: locale),
                           "December 2011", "locale \(localeID) must retain Gregorian civil identity")
            XCTAssertEqual(TimelineDayDisplay.monthHeader(forMonthStart: utc(2026, 10, 1), locale: locale),
                           "October 2026")
        }

        // Localized month names follow the locale; the civil month does not move.
        let zh = TimelineDayDisplay.monthHeader(forMonthStart: utc(2026, 10, 1),
                                                locale: Locale(identifier: "zh-Hans"))
        XCTAssertFalse(zh.isEmpty)
        XCTAssertNotEqual(zh, "October 2026")
    }

    // MARK: - Helpers

    private func rawURL(_ stem: String) -> URL {
        tempDir.appendingPathComponent("raw").appendingPathComponent("\(stem).md")
    }

    private func writeDay(_ stem: String, memoCount: Int) {
        guard let date = dateFmt.date(from: stem) else { return XCTFail("bad date \(stem)") }
        var blocks: [String] = []
        for i in 0..<memoCount {
            let memo = Memo(id: UUID(), type: .text, created: date.addingTimeInterval(Double(i)),
                            body: "memo \(i) for \(stem)")
            blocks.append(memo.toMarkdown())
        }
        let content = blocks.joined(separator: RawStorage.memoSeparator)
        try? content.write(to: rawURL(stem), atomically: true, encoding: .utf8)
    }

    private func writeDailySummary(_ stem: String, summary: String) {
        let url = tempDir.appendingPathComponent("wiki/daily").appendingPathComponent("\(stem).md")
        let content = "---\ntype: daily\nsummary: \"\(summary)\"\n---\n\n# \(stem)\n\n正文。"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Post the same notification RawStorage emits after a write, so the index's
    /// incremental-update path runs. NotificationCenter delivers main-queue
    /// block observers synchronously when posting from the main thread/actor.
    private func postDidWrite(forDateString stem: String) {
        guard let date = dateFmt.date(from: stem) else { return XCTFail("bad date \(stem)") }
        NotificationCenter.default.post(name: .rawStorageDidWrite, object: date)
    }

    private func waitForIndexUpdate(_ action: () -> Void) async {
        let update = expectation(description: "single-day index update completes")
        let token = NotificationCenter.default.addObserver(
            forName: .timelineIndexDidUpdate, object: nil, queue: .main
        ) { _ in update.fulfill() }
        action()
        await TimelineIndex.shared.waitUntilIdleForTesting()
        await fulfillment(of: [update], timeout: 1)
        NotificationCenter.default.removeObserver(token)
    }

    // MARK: - Canonical-date test helpers (deterministic zone injection —
    // no shared UserDefaults/preference mutations)

    /// 2026-10-03 11:00Z. Shanghai/LA civil day = Oct 3, Kiritimati = Oct 4.
    private var fixedReferenceInstant: Date { utc(2026, 10, 3, 11) }

    private let neutralCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return c
    }()

    private func zone(_ identifier: String) -> TimeZone {
        guard let tz = TimeZone(identifier: identifier) else {
            preconditionFailure("missing time zone \(identifier)")
        }
        return tz
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        let comps = DateComponents(year: year, month: month, day: day, hour: hour)
        guard let date = neutralCal.date(from: comps) else {
            preconditionFailure("bad test date \(year)-\(month)-\(day)")
        }
        return date
    }

    /// Zone-local midnight of a canonical key as the scanner in `zoneIdentifier`
    /// would have produced it — i.e. a deliberately stale cache artifact once
    /// grouping runs under a different zone snapshot.
    private func scannedMidnight(_ key: String, zoneIdentifier: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone(zoneIdentifier)
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            preconditionFailure("bad key \(key)")
        }
        return date
    }

    private func makeEntry(_ key: String, memos: Int = 1, summary: String? = nil,
                           date: Date) -> TimelineDayEntry {
        TimelineDayEntry(dateString: key, date: date, memoCount: memos,
                         summary: summary, excerpt: "lede", previewLines: ["line"])
    }

    /// Compact section signature: kind + exact canonical keys in rendered order.
    private func layoutSignature(_ sections: [TimelineSection]) -> [String] {
        sections.map { section in
            let kind: String
            switch section.kind {
            case .pinned: kind = "pinned"
            case .thisWeekOthers: kind = "thisWeekOthers"
            case .lastWeek: kind = "lastWeek"
            case .weekBeforeLast: kind = "weekBeforeLast"
            case .month: kind = "month"
            }
            return "\(kind):[\(section.days.map { $0.dateString }.joined(separator: ","))]"
        }
    }

    /// Grouping must preserve exact identities, counts, summaries — and the
    /// cached `date` artifacts it must never read stay byte-identical too.
    private func assertEntriesPreserved(_ sections: [TimelineSection],
                                        against input: [TimelineDayEntry],
                                        file: StaticString = #filePath, line: UInt = #line) {
        let byKey = Dictionary(uniqueKeysWithValues: input.map { ($0.dateString, $0) })
        for section in sections {
            for day in section.days {
                guard let original = byKey[day.dateString] else {
                    XCTFail("unexpected day \(day.dateString)", file: file, line: line)
                    continue
                }
                XCTAssertEqual(day.memoCount, original.memoCount, file: file, line: line)
                XCTAssertEqual(day.summary, original.summary, file: file, line: line)
                XCTAssertEqual(day.date, original.date,
                               "cached date artifact must pass through untouched", file: file, line: line)
                XCTAssertEqual(day, original, file: file, line: line)
            }
        }
    }

    /// Snapshot of every raw file's bytes — detects any file move/rewrite.
    private func rawBytesSnapshot() -> [String: Data] {
        let rawDir = tempDir.appendingPathComponent("raw")
        let names = (try? fm.contentsOfDirectory(atPath: rawDir.path)) ?? []
        var snapshot: [String: Data] = [:]
        for name in names {
            snapshot[name] = (try? Data(contentsOf: rawDir.appendingPathComponent(name)))
        }
        return snapshot
    }
}
