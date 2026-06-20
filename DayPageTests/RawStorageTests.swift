import XCTest
@testable import DayPage

/// Unit tests for RawStorage — covering the acceptance criteria from issue #108:
/// atomicWrite must use NSFileCoordinator, produce correct output, be idempotent on
/// concurrency, and leave no temp files behind.
final class RawStorageTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("RawStorageTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - atomicWrite

    func testAtomicWrite_createsFileWithCorrectContent() throws {
        let targetURL = tempDir.appendingPathComponent("test.md")
        try RawStorage.atomicWrite(string: "hello world", to: targetURL)

        XCTAssertTrue(fm.fileExists(atPath: targetURL.path), "File must exist after atomicWrite")
        let content = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertEqual(content, "hello world")
    }

    func testAtomicWrite_overwritesExistingFile() throws {
        let url = tempDir.appendingPathComponent("overwrite.md")
        try RawStorage.atomicWrite(string: "first", to: url)
        try RawStorage.atomicWrite(string: "second", to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "second", "atomicWrite must replace entire file content")
    }

    func testAtomicWrite_createsIntermediateDirectories() throws {
        let nested = tempDir
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("nested.md")
        XCTAssertFalse(fm.fileExists(atPath: nested.deletingLastPathComponent().path))
        try RawStorage.atomicWrite(string: "nested", to: nested)
        XCTAssertTrue(fm.fileExists(atPath: nested.path), "atomicWrite must create intermediate directories")
    }

    func testAtomicWrite_leavesNoTempFiles() throws {
        let url = tempDir.appendingPathComponent("clean.md")
        try RawStorage.atomicWrite(string: "data", to: url)
        let contents = try fm.contentsOfDirectory(atPath: tempDir.path)
        let tempFiles = contents.filter { $0.hasSuffix(".tmp") || $0.hasPrefix(".") }
        XCTAssertTrue(tempFiles.isEmpty, "No temp files must remain after atomicWrite: \(tempFiles)")
    }

    func testAtomicWrite_writesUTF8Correctly() throws {
        let text = "日记 — 今天天气很好 🌤"
        let url = tempDir.appendingPathComponent("utf8.md")
        try RawStorage.atomicWrite(string: text, to: url)
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, text, "atomicWrite must preserve UTF-8 content including emoji and CJK")
    }

    // MARK: - atomicWrite(data:) — binary-safe overload

    func testAtomicWriteData_roundTripsBinaryContent() throws {
        // Non-UTF-8 byte stream — must survive write/read unchanged.
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x00])
        let url = tempDir.appendingPathComponent("photo.jpg")
        try RawStorage.atomicWrite(data: payload, to: url)
        let readBack = try Data(contentsOf: url)
        XCTAssertEqual(readBack, payload, "atomicWrite(data:) must preserve arbitrary bytes")
    }

    func testAtomicWriteData_overwritesExistingFile() throws {
        let url = tempDir.appendingPathComponent("rewrite.bin")
        try RawStorage.atomicWrite(data: Data([0x01, 0x02]), to: url)
        try RawStorage.atomicWrite(data: Data([0x03, 0x04, 0x05]), to: url)
        let readBack = try Data(contentsOf: url)
        XCTAssertEqual(readBack, Data([0x03, 0x04, 0x05]))
    }

    func testAtomicWriteData_failureLeavesNoTempFile() throws {
        // Writing into a path whose parent cannot be created (a regular file
        // sitting where a directory needs to be) must throw and must NOT
        // leave a stray `.tmp.*` file behind in the parent directory.
        // This is the regression guard for issue #20 — PhotoService used to
        // swallow replaceItemAt errors and leak temp files into raw/assets/.
        let blocker = tempDir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        let badURL = blocker.appendingPathComponent("photo.jpg") // parent is a file
        XCTAssertThrowsError(try RawStorage.atomicWrite(data: Data([0xAA]), to: badURL))

        let leftovers = try fm.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains(".tmp.") }
        XCTAssertTrue(leftovers.isEmpty, "atomicWrite must not leave tmp files on failure: \(leftovers)")
    }

    func testAtomicWriteData_createsIntermediateDirectories() throws {
        let nested = tempDir
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("nested.bin")
        try RawStorage.atomicWrite(data: Data([0x42]), to: nested)
        XCTAssertTrue(fm.fileExists(atPath: nested.path))
    }

    // MARK: - String overload still works via Data overload

    func testAtomicWrite_concurrentWrites_allSucceed() throws {
        let url = tempDir.appendingPathComponent("concurrent.md")
        let group = DispatchGroup()
        var errors: [Error] = []
        let lock = NSLock()

        for i in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                do {
                    try RawStorage.atomicWrite(string: "write \(i)", to: url)
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.wait()
        XCTAssertTrue(errors.isEmpty, "Concurrent atomicWrites must not throw: \(errors)")
        XCTAssertTrue(fm.fileExists(atPath: url.path), "File must exist after concurrent writes")
    }

    // MARK: - append + read round-trip

    func testAppend_createsMemoFileOnFirstWrite() throws {
        let memo = makeMemo(body: "first memo")
        try RawStorage.append(memo)
        let url = RawStorage.fileURL(for: memo.created)
        XCTAssertTrue(fm.fileExists(atPath: url.path), "append must create the file on first call")
    }

    func testAppend_multipleMemos_readBackAllMemos() throws {
        let date = Date()
        let bodies = ["memo one", "memo two", "memo three"]
        for body in bodies {
            var m = makeMemo(body: body)
            m.created = date
            try RawStorage.append(m)
        }
        let memos = try RawStorage.read(for: date)
        let readBodies = memos.map { $0.body }
        for body in bodies {
            XCTAssertTrue(readBodies.contains(body), "Read memos must contain '\(body)'")
        }
        XCTAssertEqual(memos.count, bodies.count, "Must read back exactly \(bodies.count) memos")
    }

    func testRead_returnsEmptyArray_whenFileAbsent() throws {
        let future = Date(timeIntervalSinceNow: 999_999)
        let memos = try RawStorage.read(for: future)
        XCTAssertTrue(memos.isEmpty, "read must return [] when no file exists for that date")
    }

    // MARK: - parse

    func testParse_ignoresEmptyBlocks() {
        let content = "\n\n---\n\n" + validMemoBlock() + "\n\n---\n\n"
        let memos = RawStorage.parse(fileContent: content)
        XCTAssertEqual(memos.count, 1, "Empty separator blocks must not produce Memo objects")
    }

    func testParse_singleBlock_returnsSingleMemo() {
        let memos = RawStorage.parse(fileContent: validMemoBlock())
        XCTAssertEqual(memos.count, 1)
    }

    func testParse_twoBlocks_returnsTwoMemos() {
        let content = validMemoBlock() + RawStorage.memoSeparator + validMemoBlock()
        let memos = RawStorage.parse(fileContent: content)
        XCTAssertEqual(memos.count, 2)
    }

    // MARK: - issue #227: memo body containing --- must round-trip

    /// A memo whose body contains a triple-dash line must serialize and parse back
    /// without being dropped. Before #227 the legacy "\n\n---\n\n" separator
    /// collided with the YAML frontmatter delimiter and silently lost the memo.
    func testParse_memoBodyContainingTripleDash_roundtrips() throws {
        let body = "before\n\n---\n\nafter"
        let memo = makeMemo(body: body)
        try RawStorage.append(memo)

        let memos = try RawStorage.read(for: memo.created)
        XCTAssertEqual(memos.count, 1, "Memo with '---' in body must not be dropped")
        XCTAssertEqual(memos.first?.body, body, "Body containing '---' must round-trip exactly")
    }

    /// Two memos written through append/read must round-trip when one of them
    /// contains a "---" line in its body.
    func testParse_multipleMemosOneWithTripleDash_allReadBack() throws {
        let date = Date()
        var m1 = makeMemo(body: "regular memo")
        m1.created = date
        var m2 = makeMemo(body: "with separator-like content\n\n---\n\nstill same memo")
        m2.created = date
        var m3 = makeMemo(body: "third memo")
        m3.created = date

        try RawStorage.append(m1)
        try RawStorage.append(m2)
        try RawStorage.append(m3)

        let memos = try RawStorage.read(for: date)
        XCTAssertEqual(memos.count, 3, "All three memos must be read back")
        let bodies = memos.map { $0.body }
        XCTAssertTrue(bodies.contains("regular memo"))
        XCTAssertTrue(bodies.contains("with separator-like content\n\n---\n\nstill same memo"))
        XCTAssertTrue(bodies.contains("third memo"))
    }

    /// A vault file written by an older app version using the legacy "\n\n---\n\n"
    /// separator must still be parseable so existing users don't lose data.
    func testParse_oldSeparator_backwardCompatible() {
        let legacyContent = validMemoBlock() + "\n\n---\n\n" + validMemoBlock()
        let memos = RawStorage.parse(fileContent: legacyContent)
        XCTAssertEqual(memos.count, 2, "Files using the legacy separator must still parse")
    }

    /// The new HTML-comment separator must split memos correctly.
    func testParse_newSeparator_correctlySplits() {
        let content = validMemoBlock() + RawStorage.memoSeparator + validMemoBlock() + RawStorage.memoSeparator + validMemoBlock()
        let memos = RawStorage.parse(fileContent: content)
        XCTAssertEqual(memos.count, 3, "New separator must split all memos")
    }

    /// The current separator must not be the legacy one — guards against accidental revert.
    func testMemoSeparator_isNotLegacyTripleDash() {
        XCTAssertNotEqual(RawStorage.memoSeparator, "\n\n---\n\n",
                          "Separator must not be the legacy bare '---' (collides with YAML frontmatter)")
        XCTAssertTrue(RawStorage.memoSeparator.contains("daypage-memo-separator"),
                      "Separator should be a unique HTML-comment marker")
    }

    // MARK: - fileURL

    func testFileURL_isUnderRawDirectory() {
        let url = RawStorage.fileURL(for: Date())
        let components = url.pathComponents
        let rawIndex = components.firstIndex(of: "raw")
        XCTAssertNotNil(rawIndex, "fileURL must include 'raw' path component")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"), "fileURL must produce a .md path")
        XCTAssertTrue(url.path.contains("/raw/"), "fileURL must be under the raw/ directory")
    }

    func testFileURL_usesInjectedVaultRoot() {
        let url = RawStorage.fileURL(for: Date())
        XCTAssertTrue(
            url.path.hasPrefix(tempDir.path),
            "fileURL must be rooted at the injected testOverrideURL"
        )
    }

    func testFileURL_hasMDExtension() {
        let url = RawStorage.fileURL(for: Date())
        XCTAssertEqual(url.pathExtension, "md", "fileURL must have .md extension")
    }

    func testFileURL_filenameMatchesDateFormat() {
        // Date is 2026-04-29 — construct a fixed date to assert the filename format
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 29
        comps.hour = 10; comps.minute = 0; comps.second = 0
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return XCTFail("Could not construct date") }
        let url = RawStorage.fileURL(for: date)
        // The filename should contain YYYY-MM-DD (timezone-dependent but always hyphenated)
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 3, "Filename must be YYYY-MM-DD: got '\(name)'")
    }

    // MARK: - issue #22: broken-block quarantine

    /// Multi-memo file with one corrupted middle block: the parseable memos
    /// must come through, AND the broken block bytes must survive in
    /// `vault/raw/.broken/` so a future rewrite does not silently destroy
    /// them. Pre-fix, the parser used compactMap and the bad block vanished
    /// without trace.
    func testParse_brokenMiddleBlock_isQuarantined_andOthersSurvive() throws {
        let date = Date()
        let dayURL = RawStorage.fileURL(for: date)
        let good1 = validMemoBlock()
        let good2 = validMemoBlock()
        let brokenBlock = "---\nthis is not a valid frontmatter\nthere is no closing dashes or id\n"
        let content = good1 + RawStorage.memoSeparator + brokenBlock + RawStorage.memoSeparator + good2

        try RawStorage.atomicWrite(string: content, to: dayURL)

        let memos = try RawStorage.read(for: date)
        XCTAssertEqual(memos.count, 2, "Two parseable memos must come through; the broken one is quarantined, not returned")

        let brokenDir = dayURL.deletingLastPathComponent().appendingPathComponent(".broken")
        let quarantined = try fm.contentsOfDirectory(atPath: brokenDir.path)
        XCTAssertEqual(quarantined.count, 1, "Exactly one quarantine file expected")

        let dayStem = dayURL.deletingPathExtension().lastPathComponent
        let qFile = quarantined.first!
        XCTAssertTrue(qFile.hasPrefix(dayStem),
            "Quarantine filename must be prefixed with the source day stem (got '\(qFile)')")
        XCTAssertTrue(qFile.hasSuffix(".md"),
            "Quarantine filename must keep .md extension (got '\(qFile)')")

        let qContent = try String(contentsOf: brokenDir.appendingPathComponent(qFile), encoding: .utf8)
        XCTAssertTrue(qContent.contains("this is not a valid frontmatter"),
            "Quarantine copy must preserve the original broken bytes verbatim")
        XCTAssertTrue(qContent.contains("daypage broken block quarantined"),
            "Quarantine copy must carry the diagnostic header")
    }

    /// Quarantine must be idempotent: parsing the same broken file twice
    /// must NOT produce two quarantine copies. The SHA-prefixed filename
    /// guarantees content-addressing.
    func testParse_brokenBlockQuarantine_isIdempotentAcrossReads() throws {
        let date = Date()
        let dayURL = RawStorage.fileURL(for: date)
        let broken = "---\nbroken broken\nno id here at all\n"
        let content = validMemoBlock() + RawStorage.memoSeparator + broken
        try RawStorage.atomicWrite(string: content, to: dayURL)

        _ = try RawStorage.read(for: date)
        _ = try RawStorage.read(for: date)
        _ = try RawStorage.read(for: date)

        let brokenDir = dayURL.deletingLastPathComponent().appendingPathComponent(".broken")
        let entries = try fm.contentsOfDirectory(atPath: brokenDir.path)
        XCTAssertEqual(entries.count, 1, "Repeated reads of the same broken block must produce exactly one quarantine file")
    }

    /// After a broken-middle-block file goes through `mutate` (which is what
    /// happens when a transcript writeback or any in-place update runs), the
    /// main day file is rewritten without the broken block — but the broken
    /// bytes still exist on disk in the quarantine area. This is the load-
    /// bearing guarantee: a corrupted block cannot be silently erased by a
    /// later mutation.
    func testMutate_afterBrokenBlock_mainFileShrinks_butQuarantineRetainsBytes() throws {
        let date = Date()
        let dayURL = RawStorage.fileURL(for: date)
        let good = validMemoBlock()
        let broken = "---\nthis block has no id\nstill no id\n"
        try RawStorage.atomicWrite(
            string: good + RawStorage.memoSeparator + broken,
            to: dayURL
        )

        try RawStorage.mutate(for: date) { existing in
            // Identity transform — simulates any in-place rewrite path
            // (transcript writeback, pin toggle, etc.).
            return existing
        }

        let rewritten = try String(contentsOf: dayURL, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("this block has no id"),
            "Main file must no longer carry the broken block (it cannot round-trip)")

        let brokenDir = dayURL.deletingLastPathComponent().appendingPathComponent(".broken")
        let entries = try fm.contentsOfDirectory(atPath: brokenDir.path)
        XCTAssertGreaterThanOrEqual(entries.count, 1,
            "Broken bytes must survive in quarantine even after main-file rewrite")
        let qContent = try String(contentsOf: brokenDir.appendingPathComponent(entries.first!), encoding: .utf8)
        XCTAssertTrue(qContent.contains("this block has no id"))
    }

    /// Single-memo file whose entire content is unparseable (e.g. fully
    /// truncated to half a YAML block) must produce `[]` AND quarantine the
    /// raw bytes — never silently return `[]` and drop the disk content on
    /// the next write.
    func testParse_whollyUnparseableFile_isQuarantined() throws {
        let date = Date()
        let dayURL = RawStorage.fileURL(for: date)
        let garbage = "this is not yaml\nno --- markers anywhere\nnothing parseable"
        try RawStorage.atomicWrite(string: garbage, to: dayURL)

        let memos = try RawStorage.read(for: date)
        XCTAssertEqual(memos, [], "Wholly unparseable file must yield no memos")

        let brokenDir = dayURL.deletingLastPathComponent().appendingPathComponent(".broken")
        let entries = try fm.contentsOfDirectory(atPath: brokenDir.path)
        XCTAssertEqual(entries.count, 1, "The unparseable file's bytes must be quarantined")
        let qContent = try String(contentsOf: brokenDir.appendingPathComponent(entries.first!), encoding: .utf8)
        XCTAssertTrue(qContent.contains("this is not yaml"))
    }

    // MARK: - Helpers

    private func makeMemo(body: String) -> Memo {
        Memo(id: UUID(), type: .text, created: Date(), body: body)
    }

    private func validMemoBlock() -> String {
        let memo = makeMemo(body: "test body")
        return memo.toMarkdown()
    }
}
