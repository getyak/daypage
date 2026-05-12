import Testing
import Foundation
@testable import DayPage

/// Tests for RawStorage.parse(fileContent:) — multi-memo splitting, YAML body isolation,
/// and write-then-read concurrency. Acceptance criteria for US-002 (fixtures) and US-003
/// (parser fix + concurrency).
@Suite("ParserTests")
struct ParserTests {

    // MARK: - Fixture

    /// Builds a raw YAML+Markdown block for a single memo.
    private func memoBlock(id: String = UUID().uuidString, body: String) -> String {
        """
        ---
        id: \(id)
        type: text
        created: 2026-05-12T10:00:00.000Z
        attachments: []
        ---

        \(body)
        """
    }

    // MARK: - US-002: 4-memo fixture + body isolation

    /// parse(fileContent:) must return exactly 4 Memo objects when given a file with 4
    /// blocks separated by the HTML-comment separator.
    @Test func fourMemoFixture_parsesAllFour() {
        let sep = RawStorage.memoSeparator
        let ids = (0..<4).map { _ in UUID().uuidString }
        let content = ids
            .map { memoBlock(id: $0, body: "body for \($0)") }
            .joined(separator: sep)

        let memos = RawStorage.parse(fileContent: content)
        #expect(memos.count == 4, "Expected 4 memos, got \(memos.count)")
    }

    /// Parsed Memo bodies must not contain YAML front-matter keys like 'id:', 'type:', 'created:'.
    @Test func parsedBodies_containNoYAMLKeys() {
        let sep = RawStorage.memoSeparator
        let content = (0..<4)
            .map { memoBlock(id: UUID().uuidString, body: "memo \($0)") }
            .joined(separator: sep)

        let memos = RawStorage.parse(fileContent: content)
        for memo in memos {
            #expect(!memo.body.contains("id:"), "Body must not contain 'id:' — got: \(memo.body)")
            #expect(!memo.body.contains("type:"), "Body must not contain 'type:'")
            #expect(!memo.body.contains("created:"), "Body must not contain 'created:'")
            #expect(!memo.body.contains("attachments:"), "Body must not contain 'attachments:'")
        }
    }

    // MARK: - US-003: concurrency — write-then-read returns consistent count

    /// Concurrent appends from multiple threads must all persist; a subsequent read must
    /// return a count equal to the number of appended memos.
    @Test func concurrentAppend_readBackConsistentCount() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: tempDir)
        }

        let date = Date()
        let memoCount = 4
        let group = DispatchGroup()
        var errors: [Error] = []
        let lock = NSLock()

        for _ in 0..<memoCount {
            group.enter()
            DispatchQueue.global().async {
                var m = Memo(type: .text, created: date, body: "concurrent memo \(UUID().uuidString)")
                m.created = date
                do {
                    try RawStorage.append(m)
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        #expect(errors.isEmpty, "Concurrent appends must not throw: \(errors)")
        let memos = try RawStorage.read(for: date)
        #expect(memos.count == memoCount, "Expected \(memoCount) memos after concurrent writes, got \(memos.count)")
    }

    // MARK: - Edge cases

    /// A single memo block (no separator) must parse to exactly one memo.
    @Test func singleBlock_parsesToOneMemo() {
        let content = memoBlock(body: "only memo")
        let memos = RawStorage.parse(fileContent: content)
        #expect(memos.count == 1)
    }

    /// Empty content returns empty array.
    @Test func emptyContent_returnsEmpty() {
        let memos = RawStorage.parse(fileContent: "")
        #expect(memos.isEmpty)
    }

    /// A memo body that contains "---" must not be truncated at that line.
    @Test func bodyWithTripleDash_isPreservedFully() {
        let bodyWithDash = "before\n\n---\n\nafter"
        let content = memoBlock(body: bodyWithDash)
        let memos = RawStorage.parse(fileContent: content)
        #expect(memos.count == 1, "Memo with '---' in body must still parse as one memo")
        #expect(memos.first?.body == bodyWithDash, "Body must survive '---' round-trip")
    }

    /// Three memos separated by the new HTML-comment separator must all be parsed.
    @Test func threeMemos_newSeparator_allParsed() {
        let sep = RawStorage.memoSeparator
        let content = [
            memoBlock(body: "alpha"),
            memoBlock(body: "beta"),
            memoBlock(body: "gamma"),
        ].joined(separator: sep)

        let memos = RawStorage.parse(fileContent: content)
        #expect(memos.count == 3)
        let bodies = memos.map { $0.body }
        #expect(bodies.contains("alpha"))
        #expect(bodies.contains("beta"))
        #expect(bodies.contains("gamma"))
    }
}
