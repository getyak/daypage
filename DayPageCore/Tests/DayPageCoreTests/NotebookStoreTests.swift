import XCTest
@testable import DayPageCore

final class NotebookStoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daypage-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func fixture(_ body: String, id: UUID = UUID()) -> Memo {
        Memo(id: id, created: ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z")!, body: body)
    }
    func write(_ text: String) throws -> URL {
        let file = root.appendingPathComponent("raw/2026-10-30.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testReadDoesNotRewriteLegacyFileOrAttachmentMetadata() async throws {
        var one = fixture("旧笔记\n\n---\n\n正文里的横线")
        one.attachments = [.init(file: "photo.jpg", kind: "photo")]
        let two = fixture("Another note")
        let original = one.toMarkdown() + "\n\n<!-- daypage-memo-separator -->\n\n" + two.toMarkdown()
        let file = try write(original)
        let entries = try await NotebookStore(root: root).entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first(where: { $0.memo.id == one.id })?.memo.attachments, one.attachments)
        XCTAssertEqual(try String(contentsOf: file), original)
    }

    func testLegacySeparatorAndHorizontalRuleRemainReadable() async throws {
        let one = fixture("One"), two = fixture("Two")
        _ = try write(one.toMarkdown() + "\n\n---\n\n" + two.toMarkdown())
        let entries = try await NotebookStore(root: root).entries()
        XCTAssertEqual(Set(entries.map(\.memo.id)), [one.id, two.id])
    }

    func testConcurrentAppendsPreserveEveryMemo() async throws {
        let store = NotebookStore(root: root)
        let notes = (0..<24).map { fixture("Note \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for memo in notes { group.addTask { try await store.append(memo) } }
            try await group.waitForAll()
        }
        let saved = try await store.entries()
        XCTAssertEqual(Set(saved.map(\.memo.id)), Set(notes.map(\.id)))
    }
    func testTwoStoresWritingTheSameVaultPreserveEveryMemo() async throws {
        let stores = [NotebookStore(root: root), NotebookStore(root: root)]
        let notes = (0..<80).map { fixture("Concurrent note \($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index,memo) in notes.enumerated() { group.addTask { try await stores[index % 2].append(memo) } }
            try await group.waitForAll()
        }
        let saved = try await stores[0].entries()
        XCTAssertEqual(Set(saved.map(\.memo.id)), Set(notes.map(\.id)))
    }

    func testEditPreservesUnknownYAMLAndUntargetedRecordBytes() async throws {
        let one = fixture("Before"), two = fixture("Untouched\n\nextra")
        let original = one.toMarkdown().replacingOccurrences(of: "type: text", with: "type: text\nfuture_field: retain-me")
        let file = try write(original + "\n\n<!-- daypage-memo-separator -->\n\n" + two.toMarkdown())
        let store = NotebookStore(root: root)
        let before = try await store.entries()
        let entry = try XCTUnwrap(before.first { $0.memo.id == one.id })
        try await store.update(entry, body: "After")
        let bytes = try String(contentsOf: file)
        XCTAssertTrue(bytes.contains("future_field: retain-me"))
        XCTAssertTrue(bytes.hasSuffix(two.toMarkdown()))
        let saved = try await store.entries()
        XCTAssertEqual(saved.first(where: { $0.memo.id == one.id })?.memo.body, "After")
    }

    func testDuplicateIDEditIsRejectedWithoutChangingFile() async throws {
        let one = fixture("Duplicate")
        let original = one.toMarkdown() + "\n\n<!-- daypage-memo-separator -->\n\n" + one.toMarkdown()
        let file = try write(original)
        do {
            try await NotebookStore(root: root).update(.init(memo: one, day: "2026-10-30"), body: "Changed")
            XCTFail("Duplicate IDs must not be rewritten")
        } catch { }
        XCTAssertEqual(try String(contentsOf: file), original)
    }

    func testStaleEditIsRejectedWithoutLosingExternalChanges() async throws {
        let memo = fixture("Before")
        let file = try write(memo.toMarkdown())
        let store = NotebookStore(root: root)
        let before = try await store.entries()
        let original = try XCTUnwrap(before.first)
        let external = memo.toMarkdown().replacingOccurrences(of: "Before", with: "External edit")
        try external.write(to: file, atomically: true, encoding: .utf8)
        do { try await store.update(original, body: "Stale replacement"); XCTFail("Expected conflict") } catch { }
        XCTAssertEqual(try String(contentsOf: file), external)
    }

    func testMalformedRecordBytesSurviveAppend() async throws {
        let original = "unrecognized metadata and original content"
        let file = try write(original)
        do { try await NotebookStore(root: root).append(fixture("New")) } catch { }
        XCTAssertTrue(try String(contentsOf: file).contains(original))
    }

    func testTraversalCannotWriteOutsideVault() async throws {
        let malicious = NotebookEntry(memo: fixture("X"), day: "../escape")
        do { try await NotebookStore(root: root).update(malicious, body: "Y"); XCTFail("Invalid path") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.md").path))
    }

    func testImportCopiesIntoSeparateNamespaceAndPreservesSource() async throws {
        let source = root.deletingLastPathComponent().appendingPathComponent("old-cloud-vault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("raw/assets"), withIntermediateDirectories: true)
        let original = fixture("Imported").toMarkdown()
        try original.write(to: source.appendingPathComponent("raw/2026-10-30.md"), atomically: true, encoding: .utf8)
        try Data([1,2,3]).write(to: source.appendingPathComponent("raw/assets/photo.jpg"))
        _ = try write(fixture("Already local").toMarkdown())
        let store = NotebookStore(root: root)
        try await store.importVault(from: source)
        let saved = try await store.entries()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("raw/2026-10-30.md")), original)
        XCTAssertFalse(try XCTUnwrap(saved.first { $0.memo.body == "Imported" }).namespace.isEmpty)
    }

    func testImportRejectsSymlinksAndDoesNotPublishPartialCopies() async throws {
        let source = root.deletingLastPathComponent().appendingPathComponent("bad-vault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("raw/2026-10-30.md"), withDestinationURL: root.appendingPathComponent("outside.md"))
        do { try await NotebookStore(root: root).importVault(from: source); XCTFail("Symlinks forbidden") } catch { }
        let saved = try await NotebookStore(root: root).entries()
        XCTAssertTrue(saved.isEmpty)
    }
    func testReservedSeparatorCannotMakeArchiveUnreadable() async throws {
        let original = fixture("Original")
        let file = try write(original.toMarkdown())
        let store = NotebookStore(root: root)
        let text = "Before\n\n<!-- daypage-memo-separator -->\n\nAfter"
        do { try await store.append(fixture(text)); XCTFail("Reserved separator must be rejected") } catch { }
        do { try await store.update(.init(memo: original, day: "2026-10-30"), body: text); XCTFail("Reserved separator must be rejected") } catch { }
        XCTAssertEqual(try String(contentsOf: file), original.toMarkdown())
        let saved = try await store.entries()
        XCTAssertEqual(saved.count, 1)
    }
    func testMalformedImportDoesNotHideExistingNotes() async throws {
        _ = try write(fixture("Existing").toMarkdown())
        let source = root.deletingLastPathComponent().appendingPathComponent("bad-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try "Malformed".write(to: source.appendingPathComponent("raw/2026-10-30.md"), atomically: true, encoding: .utf8)
        let store = NotebookStore(root: root)
        do { try await store.importVault(from: source); XCTFail("Malformed import must not be published") } catch { }
        let saved = try await store.entries()
        XCTAssertEqual(saved.map(\.memo.body), ["Existing"])
    }
    func testExportOfImportOnlyNotebookCanBeRestoredWithAllNotes() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("raw"))
        let source = root.deletingLastPathComponent().appendingPathComponent("source-\(UUID())")
        let exported = root.deletingLastPathComponent().appendingPathComponent("export-\(UUID())")
        let restored = root.deletingLastPathComponent().appendingPathComponent("restore-\(UUID())")
        defer { for url in [source, exported, restored] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("raw/assets"), withIntermediateDirectories: true)
        try fixture("Imported only").toMarkdown().write(to: source.appendingPathComponent("raw/2026-10-30.md"), atomically: true, encoding: .utf8)
        try await NotebookStore(root: root).importVault(from: source)
        try FileManager.default.copyItem(at: root, to: exported)
        let destination = NotebookStore(root: restored)
        try await destination.importVault(from: exported)
        let entries = try await destination.entries()
        XCTAssertEqual(entries.map(\.memo.body), ["Imported only"])
    }
}
