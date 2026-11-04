import XCTest
@testable import DayPageCore

final class NoteActionsTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("get388-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func propose(_ name: String, _ arguments: [String: Any], entries: [NotebookEntry],
                       relations: [NoteRelation] = []) async throws -> NoteActionProposal {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    let result = try await NoteToolExecutor.execute(name: name,
      arguments: String(decoding: data, as: UTF8.self),
      context: NoteToolContext(entries: entries, relations: relations))
    XCTAssertFalse(result.isError, result.content)
    return try XCTUnwrap(result.proposals.first)
  }

  func testCreatePersistsOnceAcrossRestartAndUndo() async throws {
    let root = try temporaryRoot()
    let store = NotebookStore(root: root)
    let proposal = try await propose("notes_create", ["body": "An isolated new note"], entries: [])
    try await store.saveProposal(proposal)
    let first = try await store.apply(proposal, allowedCardRefs: [])
    let reopened = NotebookStore(root: root)
    let second = try await reopened.apply(proposal, allowedCardRefs: [])
    XCTAssertEqual(first, second)
    let entries = try await reopened.entries()
    XCTAssertEqual(entries.count, 1)
    let receipts = try await reopened.actionReceipts()
    XCTAssertEqual(receipts, [first])
    _ = try await reopened.undo(first, allowedCardRefs: Set(entries.map(\.id)))
    let after = try await reopened.entries()
    XCTAssertTrue(after.isEmpty)
    let receipt = try await reopened.actionReceipts().first
    XCTAssertEqual(receipt?.status, .undone)
  }

  func testAppendPreservesUnknownYAMLAttachmentsAndOtherRecordsAndUndoRejectsLaterEdit() async throws {
    let root = try temporaryRoot()
    let store = NotebookStore(root: root)
    let memo = Memo(attachments: [.init(file: "raw/assets/kept.png", kind: "photo")], body: "Original #old")
    try await store.append(memo)
    try await store.append(Memo(created: memo.created, body: "Neighbor untouched"))
    let beforeEntries = try await store.entries()
    let target = try XCTUnwrap(beforeEntries.first { $0.memo.id == memo.id })
    let dayFile = root.appendingPathComponent("raw/\(target.day).md")
    let raw = try String(contentsOf: dayFile, encoding: .utf8)
    try raw.replacingOccurrences(of: "type: text", with: "unknown_field: keep-me\ntype: text")
      .write(to: dayFile, atomically: true, encoding: .utf8)
    let entries = try await store.entries()
    let current = try XCTUnwrap(entries.first { $0.id == target.id })
    let proposal = try await propose("notes_append", ["card_ref": current.id, "body": "Added paragraph"], entries: entries)
    let receipt = try await store.apply(proposal, allowedCardRefs: Set(entries.map(\.id)))
    let saved = try String(contentsOf: dayFile, encoding: .utf8)
    XCTAssertTrue(saved.contains("unknown_field: keep-me"))
    XCTAssertTrue(saved.contains("raw/assets/kept.png"))
    XCTAssertTrue(saved.contains("Neighbor untouched"))
    let changedEntries = try await store.entries()
    let changed = try XCTUnwrap(changedEntries.first { $0.id == current.id })
    try await store.update(changed, body: "A later human edit")
    do {
      _ = try await store.undo(receipt, allowedCardRefs: Set(entries.map(\.id)))
      XCTFail("Undo must refuse a subsequent edit")
    } catch { }
    XCTAssertTrue(try String(contentsOf: dayFile, encoding: .utf8).contains("A later human edit"))
  }

  func testPatchAmbiguityAndScopeShrinkCannotWrite() async throws {
    let root = try temporaryRoot()
    let store = NotebookStore(root: root)
    try await store.append(Memo(body: "repeat repeat"))
    let entries = try await store.entries()
    let entry = try XCTUnwrap(entries.first)
    let data = try JSONSerialization.data(withJSONObject: ["card_ref": entry.id, "before": "repeat", "after": "once"])
    let rejected = try await NoteToolExecutor.execute(name: "notes_propose_patch", arguments: String(decoding: data, as: UTF8.self), context: .init(entries: entries))
    XCTAssertTrue(rejected.isError)
    let proposal = try await propose("notes_append", ["card_ref": entry.id, "body": "addition"], entries: entries)
    do { _ = try await store.apply(proposal, allowedCardRefs: []); XCTFail("Scope denial") } catch { }
    let saved = try await store.entries()
    XCTAssertEqual(saved.first?.memo.body, "repeat repeat")
  }

  func testConfirmedDirectionalRelationsAreIdempotentAndHideOutsideEndpoints() async throws {
    let root = try temporaryRoot()
    let store = NotebookStore(root: root)
    try await store.append(Memo(body: "Source notebook pricing"))
    try await store.append(Memo(body: "Target notebook pricing"))
    let entries = try await store.entries()
    let from = entries[0], to = entries[1]
    let scope = Set(entries.map(\.id))
    let proposal = try await propose("relations_link", ["from_card_ref": from.id, "to_card_ref": to.id,
      "type": "supplements", "reason": "Both discuss notebook pricing"], entries: entries)
    let before = try await store.relations(allowedCardRefs: scope)
    XCTAssertTrue(before.isEmpty)
    let receipt = try await store.apply(proposal, allowedCardRefs: scope)
    _ = try await store.apply(proposal, allowedCardRefs: scope)
    let edges = try await store.relations(allowedCardRefs: scope)
    XCTAssertEqual(edges.count, 1)
    XCTAssertEqual(edges.first?.from.cardRef, from.id)
    XCTAssertEqual(edges.first?.to.cardRef, to.id)
    let hidden = try await store.relations(allowedCardRefs: [from.id])
    XCTAssertTrue(hidden.isEmpty)
    _ = try await store.undo(receipt, allowedCardRefs: scope)
    let after = try await store.relations(allowedCardRefs: scope)
    XCTAssertTrue(after.isEmpty)
  }

  func testUnknownMetadataVersionAndSymlinkAreNeverOverwritten() async throws {
    let root = try temporaryRoot()
    let directory = root.appendingPathComponent(".daypage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let state = directory.appendingPathComponent("note-actions.json")
    let bytes = Data(#"{"version":999,"evidence":"preserve"}"#.utf8)
    try bytes.write(to: state)
    let store = NotebookStore(root: root)
    do { _ = try await store.actionReceipts(); XCTFail("Unknown version must fail") } catch { }
    XCTAssertEqual(try Data(contentsOf: state), bytes)
    let linkedRoot = try temporaryRoot()
    try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent(".daypage"), withDestinationURL: directory)
    let linkedStore = NotebookStore(root: linkedRoot)
    do { _ = try await linkedStore.actionReceipts(); XCTFail("Linked metadata must fail") } catch { }
  }
}
