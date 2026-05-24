import XCTest
@testable import DayPage

/// Unit tests for TimelineIndex — the in-memory timeline metadata cache from
/// issue #345. Verifies:
///  - rebuild produces the same result as the underlying full scan
///  - incremental update/remove keeps the index consistent with a full rebuild
///  - external modification (mtime change) is detectable
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
    }

    func testEntries_noSummaryWhenUncompiled() throws {
        writeDay("2026-05-01", memoCount: 1)
        // no daily file written
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let entry = try XCTUnwrap(TimelineIndex.shared.entries().first)
        XCTAssertNil(entry.summary, "summary must be nil when the day is not compiled")
    }

    // MARK: - cold path (entries before first build)

    func testEntries_coldPath_scansSynchronously() throws {
        writeDay("2026-05-01", memoCount: 2)
        // Do NOT call rebuild — exercise the not-yet-built cold path.
        let entries = TimelineIndex.shared.entries()
        XCTAssertEqual(entries.count, 1, "Cold-path read must still return correct data")
        XCTAssertEqual(entries.first?.memoCount, 2)
    }

    // MARK: - incremental update consistency

    func testIncrementalAppend_matchesRebuild() throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()

        // Simulate a new day's write going through RawStorage's notification.
        writeDay("2026-05-02", memoCount: 4)
        postDidWrite(forDateString: "2026-05-02")

        let afterIncremental = TimelineIndex.shared.entries()
        // Independent full rebuild as the source of truth.
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        let afterFullRebuild = TimelineIndex.shared.entries()

        XCTAssertEqual(afterIncremental, afterFullRebuild,
                       "Incremental append must match a full rebuild")
        XCTAssertEqual(afterIncremental.count, 2)
    }

    func testIncrementalUpdate_changesMemoCount() throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().first?.memoCount, 1)

        // Rewrite the same day with more memos (like adding a memo).
        writeDay("2026-05-01", memoCount: 6)
        postDidWrite(forDateString: "2026-05-01")

        XCTAssertEqual(TimelineIndex.shared.entries().first?.memoCount, 6,
                       "Incremental update must reflect the new memo count")
    }

    func testIncrementalRemove_dropsEmptyDay() throws {
        writeDay("2026-05-01", memoCount: 1)
        writeDay("2026-05-02", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().count, 2)

        // Delete the day file entirely (like deleting the last memo).
        try fm.removeItem(at: rawURL("2026-05-01"))
        postDidWrite(forDateString: "2026-05-01")

        let remaining = TimelineIndex.shared.entries()
        XCTAssertEqual(remaining.count, 1, "Removed day must drop out of the index")
        XCTAssertEqual(remaining.first?.dateString, "2026-05-02")
    }

    // MARK: - external modification detection

    func testExternalWrite_isDetectableViaMtime() throws {
        writeDay("2026-05-01", memoCount: 1)
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().count, 1)

        // Simulate an external write (iCloud/Obsidian) the app never observed:
        // add a file directly + bump the raw/ directory mtime, WITHOUT posting
        // .rawStorageDidWrite. A foreground refresh would detect the mtime delta
        // and rebuild — here we assert the detection precondition and that a
        // forced rebuild then picks up the new day.
        writeDay("2026-05-02", memoCount: 1)
        bumpRawDirMtime()

        XCTAssertNotNil(currentRawDirMtime(),
                        "raw/ must have a readable mtime for external-change detection")

        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertEqual(TimelineIndex.shared.entries().count, 2,
                       "Rebuild after an external write must include the new day")
    }

    // MARK: - empty vault

    func testEntries_emptyVault_returnsEmpty() throws {
        TimelineIndex.shared.rebuildSynchronouslyForTesting()
        XCTAssertTrue(TimelineIndex.shared.entries().isEmpty,
                      "Empty vault must yield no entries")
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

    private func bumpRawDirMtime() {
        let rawDir = tempDir.appendingPathComponent("raw")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                              ofItemAtPath: rawDir.path)
    }

    private func currentRawDirMtime() -> Date? {
        let rawDir = tempDir.appendingPathComponent("raw")
        let attrs = try? fm.attributesOfItem(atPath: rawDir.path)
        return attrs?[.modificationDate] as? Date
    }
}
