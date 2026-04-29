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

    // MARK: - Helpers

    private func makeMemo(body: String) -> Memo {
        Memo(id: UUID(), type: .text, created: Date(), body: body)
    }

    private func validMemoBlock() -> String {
        let memo = makeMemo(body: "test body")
        return memo.toMarkdown()
    }
}
