import XCTest
@testable import DayPage

/// Tests for InflightDraftStore — issue #23.
///
/// The store exists to protect against silent body-text loss when a submit
/// Task gets cancelled or the app is killed during the await chain that
/// precedes RawStorage.append (location, weather). Tests cover:
///
///   1. enqueue → file appears under vault/raw/.inflight/
///   2. dequeue → file disappears (and is idempotent if already gone)
///   3. pending() → returns newest-first, skips corrupt entries
///   4. clearAll() → drains every file
final class InflightDraftStoreTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("InflightDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - enqueue / dequeue

    func testEnqueue_createsFileUnderInflightDirectory() throws {
        let url = InflightDraftStore.enqueue(body: "hello world", attachmentPaths: [])
        XCTAssertNotNil(url)
        XCTAssertTrue(fm.fileExists(atPath: url!.path))
        XCTAssertTrue(url!.path.contains("/raw/.inflight/"))
        XCTAssertEqual(url!.pathExtension, "json")
    }

    func testEnqueue_persistsBodyAndAttachments() throws {
        let body = "今天去山顶看日出，遇到一只松鼠"
        let atts = ["raw/assets/voice_A.m4a", "raw/assets/IMG_B.jpg"]
        guard let url = InflightDraftStore.enqueue(body: body, attachmentPaths: atts) else {
            XCTFail("enqueue returned nil"); return
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InflightDraft.self, from: data)
        XCTAssertEqual(decoded.body, body)
        XCTAssertEqual(decoded.attachmentPaths, atts)
    }

    func testDequeue_removesFile() throws {
        let url = InflightDraftStore.enqueue(body: "body", attachmentPaths: [])!
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        InflightDraftStore.dequeue(url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testDequeue_isIdempotent() {
        let url = InflightDraftStore.enqueue(body: "body", attachmentPaths: [])!
        InflightDraftStore.dequeue(url)
        // Second call must not throw or assert.
        InflightDraftStore.dequeue(url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testDequeue_acceptsNilURL() {
        InflightDraftStore.dequeue(nil) // must not crash
    }

    // MARK: - pending

    func testPending_returnsEmptyWhenDirectoryMissing() {
        XCTAssertEqual(InflightDraftStore.pending(), [])
    }

    func testPending_returnsAllEnqueuedDrafts() throws {
        _ = InflightDraftStore.enqueue(body: "a", attachmentPaths: [])
        _ = InflightDraftStore.enqueue(body: "b", attachmentPaths: [])
        _ = InflightDraftStore.enqueue(body: "c", attachmentPaths: [])
        let pending = InflightDraftStore.pending()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(Set(pending.map { $0.body }), Set(["a", "b", "c"]))
    }

    func testPending_sortsNewestFirst() throws {
        // Enqueue three drafts with explicit timestamps via JSON injection
        // so we don't depend on Date() resolution.
        try fm.createDirectory(at: InflightDraftStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let now = Date()
        for (label, offset) in [("old", -3600.0), ("mid", -60.0), ("new", -1.0)] {
            let id = UUID()
            let draft = InflightDraft(
                id: id,
                body: label,
                enqueuedAt: now.addingTimeInterval(offset),
                attachmentPaths: []
            )
            let url = InflightDraftStore.directory.appendingPathComponent("\(id.uuidString).json")
            try encoder.encode(draft).write(to: url)
        }

        let pending = InflightDraftStore.pending()
        XCTAssertEqual(pending.map { $0.body }, ["new", "mid", "old"])
    }

    func testPending_skipsCorruptEntries() throws {
        let healthy = InflightDraftStore.enqueue(body: "healthy", attachmentPaths: [])!
        let corruptURL = InflightDraftStore.directory
            .appendingPathComponent("garbage.json")
        try "{ not valid json".write(to: corruptURL, atomically: true, encoding: .utf8)

        let pending = InflightDraftStore.pending()
        XCTAssertEqual(pending.count, 1, "Corrupt entry must be skipped, not crash recovery")
        XCTAssertEqual(pending.first?.body, "healthy")
        _ = healthy
    }

    // MARK: - clearAll

    func testClearAll_removesEveryDraft() throws {
        _ = InflightDraftStore.enqueue(body: "a", attachmentPaths: [])
        _ = InflightDraftStore.enqueue(body: "b", attachmentPaths: [])
        InflightDraftStore.clearAll()
        XCTAssertEqual(InflightDraftStore.pending(), [])
    }

    func testClearAll_noopWhenDirectoryMissing() {
        InflightDraftStore.clearAll() // must not throw
    }
}
