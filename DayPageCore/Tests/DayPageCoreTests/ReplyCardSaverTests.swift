import XCTest
@testable import DayPageCore

final class ReplyCardSaverTests: XCTestCase {
  func testConcurrentAliasSpellingsOfANewVaultAcrossDatesSaveOnlyOneReply() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reply-alias-\(UUID())/vault")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let alternate: URL
    if root.path.hasPrefix("/private/") {
      alternate = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)))
    } else if root.path.hasPrefix("/var/") || root.path.hasPrefix("/tmp/") {
      alternate = URL(fileURLWithPath: "/private" + root.path)
    } else { alternate = root }
    let id = UUID()
    try await withThrowingTaskGroup(of: String.self) { group in
      for index in 0..<24 {
        group.addTask {
          let entry = try await ReplyCardSaver.save(id: id, text: "One reply across path spellings",
            store: NotebookStore(root: index.isMultiple(of: 2) ? root : alternate),
            created: Date(timeIntervalSince1970: 1_793_347_200 + Double(index % 2) * 86_400))
          return entry.id
        }
      }
      var refs = Set<String>()
      for try await ref in group { refs.insert(ref) }
      XCTAssertEqual(refs.count, 1)
    }
    let actual = try await NotebookStore(root: alternate).entries()
    XCTAssertEqual(actual.map(\.memo.id), [id])
    XCTAssertEqual(actual.map(\.memo.body), ["One reply across path spellings"])
  }
  func testConcurrentRetriesAcrossDateBoundaryProduceOneCard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          _ = try await ReplyCardSaver.save(id: id, text: "One reply", store: NotebookStore(root: root),
            created: Date(timeIntervalSince1970: 1_793_347_200 + Double(index % 2) * 86_400))
        }
      }
      try await group.waitForAll()
    }
    let entries = try await NotebookStore(root: root).entries()
    XCTAssertEqual(entries.count, 1)
  }
  func testSavePublishesIndependentCardAndPreservesCaptureFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let draft = root.appendingPathComponent(".daypage/capture-test.json")
    try FileManager.default.createDirectory(at: draft.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalDraft = Data("unfinished capture and selected attachment".utf8)
    try originalDraft.write(to: draft)
    let original = Memo(body: "Original capture")
    try await store.append(original)
    let id = UUID()
    let result = try await ReplyCardSaver.save(id: id, text: "A useful answer", store: store)
    XCTAssertEqual(result.memo.id, id)
    XCTAssertEqual(result.memo.body, "A useful answer")
    XCTAssertEqual(try Data(contentsOf: draft), originalDraft)
    let entries = try await store.entries()
    XCTAssertEqual(entries.count, 2)
    XCTAssertTrue(entries.contains { $0.memo.id == original.id && $0.memo.body == original.body })
  }

  func testRetryAfterReopeningAndDayChangeReturnsSameCard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let first = try await ReplyCardSaver.save(id: id, text: "Keep this", store: NotebookStore(root: root), created: Date(timeIntervalSince1970: 1_793_347_200))
    let second = try await ReplyCardSaver.save(id: id, text: "Keep this", store: NotebookStore(root: root), created: Date(timeIntervalSince1970: 1_793_520_000))
    XCTAssertEqual(first.id, second.id)
    let entries = try await NotebookStore(root: root).entries()
    XCTAssertEqual(entries.count, 1)
  }

  func testExistingDifferentContentNeverGetsOverwritten() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let id = UUID()
    try await store.append(Memo(id: id, body: "User edited this"))
    do {
      _ = try await ReplyCardSaver.save(id: id, text: "Older answer", store: store)
      XCTFail("A saved reply must not overwrite an existing edited card")
    } catch NotebookError.conflict { }
    let entries = try await store.entries()
    XCTAssertEqual(entries.map(\.memo.body), ["User edited this"])
  }
}
