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

  func testPatchTagsAndPinPreserveRawHeaderAndCanUndo() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    try await store.append(Memo(body: "Original paragraph #old\n\nKeep spacing  "))
    var entries = try await store.entries()
    let target = try XCTUnwrap(entries.first)
    let file = root.appendingPathComponent("raw/\(target.day).md")
    let raw = try String(contentsOf: file, encoding: .utf8)
      .replacingOccurrences(of: "type: text", with: "custom: untouched\ntype: text")
    try raw.write(to: file, atomically: true, encoding: .utf8)
    entries = try await store.entries()
    let patch = try await propose("notes_propose_patch", ["card_ref": target.id, "before": "Original", "after": "Revised"], entries: entries)
    let patchReceipt = try await store.apply(patch, allowedCardRefs: [target.id])
    let patched = try String(contentsOf: file, encoding: .utf8)
    XCTAssertEqual(patched, raw.replacingOccurrences(of: "Original", with: "Revised"))
    _ = try await store.undo(patchReceipt, allowedCardRefs: [target.id])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
    entries = try await store.entries()
    let tags = try await propose("notes_set_tags", ["card_ref": target.id, "tags": ["新标签", "work"]], entries: entries)
    let tagReceipt = try await store.apply(tags, allowedCardRefs: [target.id])
    entries = try await store.entries()
    XCTAssertEqual(NotebookCatalog.tags(in: entries[0].memo.body), ["work", "新标签"])
    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("custom: untouched"))
    _ = try await store.undo(tagReceipt, allowedCardRefs: [target.id])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
    entries = try await store.entries()
    let pin = try await propose("notes_set_pin", ["card_ref": target.id, "pinned": true], entries: entries)
    let pinReceipt = try await store.apply(pin, allowedCardRefs: [target.id])
    entries = try await store.entries()
    XCTAssertNotNil(entries[0].memo.pinnedAt)
    XCTAssertEqual(entries[0].memo.body, target.memo.body)
    _ = try await store.undo(pinReceipt, allowedCardRefs: [target.id])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
  }

  func testExactRawRevisionConflictsEvenWhenOnlyUnknownYAMLChanges() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    try await store.append(Memo(body: "Original protected body"))
    let entries = try await store.entries(), target = try XCTUnwrap(entries.first)
    let proposal = try await propose("notes_append", ["card_ref": target.id, "body": "Should not appear"], entries: entries)
    let file = root.appendingPathComponent("raw/\(target.day).md")
    let changed = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "type: text", with: "new_unknown: changed\ntype: text")
    try changed.write(to: file, atomically: true, encoding: .utf8)
    do { _ = try await store.apply(proposal, allowedCardRefs: [target.id]); XCTFail("Exact revision conflict") } catch { }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), changed)
  }

  func testConcurrentStoreRequestsPublishOneNote() async throws {
    let root = try temporaryRoot(), a = NotebookStore(root: root), b = NotebookStore(root: root)
    let proposal = try await propose("notes_create", ["body": "Once despite two confirmed taps"], entries: [])
    async let first = a.apply(proposal, allowedCardRefs: [])
    async let second = b.apply(proposal, allowedCardRefs: [])
    let receipts = try await [first, second]
    XCTAssertEqual(receipts[0], receipts[1])
    let entries = try await a.entries()
    XCTAssertEqual(entries.count, 1)
  }

  func testStaleRelationReadsAndUnlinkUndoKeepExactSelectedEdge() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    try await store.append(Memo(body: "First source pricing notebook"))
    try await store.append(Memo(body: "Second source pricing notebook"))
    var entries = try await store.entries()
    let a = entries[0], b = entries[1], scope = Set(entries.map(\.id))
    let link = try await propose("relations_link", ["from_card_ref": a.id, "to_card_ref": b.id, "type": "related", "reason": "Shared pricing topic"], entries: entries)
    _ = try await store.apply(link, allowedCardRefs: scope)
    let secondLink = try await propose("relations_link", ["from_card_ref": a.id, "to_card_ref": b.id, "type": "supplements", "reason": "Second distinct directed edge"], entries: entries)
    _ = try await store.apply(secondLink, allowedCardRefs: scope)
    try await store.update(a, body: "Human edited this source")
    entries = try await store.entries()
    let stale = try await store.relations(allowedCardRefs: scope)
    XCTAssertEqual(stale.count, 2)
    XCTAssertTrue(stale.allSatisfy(\.isStale))
    let selected = try XCTUnwrap(stale.first { $0.type == .related })
    let unlink = try await propose("relations_unlink", ["relation_id": selected.id.uuidString], entries: entries, relations: stale)
    let receipt = try await store.apply(unlink, allowedCardRefs: scope)
    let remaining = try await store.relations(allowedCardRefs: scope)
    XCTAssertEqual(remaining.map(\.type), [.supplements])
    _ = try await store.undo(receipt, allowedCardRefs: scope)
    let restored = try await store.relations(allowedCardRefs: scope)
    XCTAssertEqual(Set(restored.map(\.id)), Set(stale.map(\.id)))
    XCTAssertTrue(restored.allSatisfy(\.isStale))
  }

  func testUndoDeduplicatedLinkDoesNotRemoveExistingEdge() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    try await store.append(Memo(body: "First pricing source"))
    try await store.append(Memo(body: "Second pricing source"))
    let entries = try await store.entries(), scope = Set(entries.map(\.id))
    let arguments: [String: Any] = ["from_card_ref": entries[0].id, "to_card_ref": entries[1].id, "type": "related", "reason": "Same pair"]
    let first = try await propose("relations_link", arguments, entries: entries)
    _ = try await store.apply(first, allowedCardRefs: scope)
    let repeated = try await propose("relations_link", arguments, entries: entries)
    let receipt = try await store.apply(repeated, allowedCardRefs: scope)
    _ = try await store.undo(receipt, allowedCardRefs: scope)
    let edges = try await store.relations(allowedCardRefs: scope)
    XCTAssertEqual(edges.count, 1)
    XCTAssertEqual(edges[0].id, first.relation?.id)
  }

  func testPreparedApplyAndUndoRecoveryOnlyReconcileAlreadyPublishedBytes() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    try await store.append(Memo(body: "Original before crash"))
    let entries = try await store.entries(), target = try XCTUnwrap(entries.first)
    let file = root.appendingPathComponent("raw/\(target.day).md")
    let before = try String(contentsOf: file, encoding: .utf8)
    let proposal = try await propose("notes_append", ["card_ref": target.id, "body": "After publication"], entries: entries)
    let receipt = try await store.apply(proposal, allowedCardRefs: [target.id])
    let after = try String(contentsOf: file, encoding: .utf8)
    let metadata = root.appendingPathComponent(".daypage/note-actions.json")
    let savedMetadata = try Data(contentsOf: metadata)
    func prepare(committed: Bool, undo: Bool) throws {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedMetadata) as? [String: Any])
      var records = try XCTUnwrap(object["records"] as? [[String: Any]])
      records[0]["committed"] = committed; records[0]["undoPrepared"] = undo
      object["records"] = records
      try JSONSerialization.data(withJSONObject: object).write(to: metadata)
    }
    // Crash before publication: reopening must not execute a prepared mutation.
    try prepare(committed: false, undo: false)
    try before.write(to: file, atomically: true, encoding: .utf8)
    let beforeRestart = NotebookStore(root: root)
    let absent = try await beforeRestart.actionReceipts()
    XCTAssertTrue(absent.isEmpty)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
    let pending = try await beforeRestart.pendingProposals()
    XCTAssertEqual(pending.map(\.id), [proposal.id])
    // Crash after publication: recognize the exact saved block without replay.
    try after.write(to: file, atomically: true, encoding: .utf8)
    let afterRestart = NotebookStore(root: root)
    let recovered = try await afterRestart.actionReceipts()
    XCTAssertEqual(recovered, [receipt])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), after)
    // Prepared undo before publication stays applied and cannot auto-undo.
    try prepare(committed: true, undo: true)
    let uncommittedUndo = try await NotebookStore(root: root).actionReceipts()
    XCTAssertEqual(uncommittedUndo.first?.status, .applied)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), after)
    // Published undo is finalized from the exact prior block.
    try before.write(to: file, atomically: true, encoding: .utf8)
    let committedUndo = try await NotebookStore(root: root).actionReceipts()
    XCTAssertEqual(committedUndo.first?.status, .undone)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
  }

  func testImportedNamespaceMutationLeavesSameUUIDLocalRecordUntouched() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    let memo = Memo(body: "Same UUID in different namespaces")
    try await store.append(memo)
    let entries = try await store.entries(), local = try XCTUnwrap(entries.first)
    let namespace = UUID().uuidString
    let importedRaw = root.appendingPathComponent("imports/\(namespace)/raw")
    try FileManager.default.createDirectory(at: importedRaw, withIntermediateDirectories: true)
    let file = importedRaw.appendingPathComponent("\(local.day).md")
    let importedOriginal = memo.toMarkdown().replacingOccurrences(of: "type: text", with: "external_key: preserve\ntype: text")
    try importedOriginal.write(to: file, atomically: true, encoding: .utf8)
    let scopeEntries = try await store.entries()
    let imported = try XCTUnwrap(scopeEntries.first { $0.namespace == namespace })
    let proposal = try await propose("notes_append", ["card_ref": imported.id, "body": "Imported-only addition"], entries: scopeEntries)
    let receipt = try await store.apply(proposal, allowedCardRefs: [imported.id])
    let after = try await store.entries()
    XCTAssertEqual(after.first { $0.namespace.isEmpty }?.memo.body, memo.body)
    XCTAssertEqual(after.first { $0.namespace == namespace }?.memo.body, memo.body + "\n\nImported-only addition")
    _ = try await store.undo(receipt, allowedCardRefs: [imported.id])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), importedOriginal)
  }

  func testMalformedOrExtendedMetadataIsPreservedAndOversizeWritesAreRejectedBeforePublication() async throws {
    let root = try temporaryRoot(), store = NotebookStore(root: root)
    let directory = root.appendingPathComponent(".daypage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let metadata = directory.appendingPathComponent("note-actions.json")
    for text in ["{", #"{"version":1}"#,
      #"{"version":1,"proposals":[],"records":[],"relations":[],"future_evidence":"keep"}"#] {
      let bytes = Data(text.utf8); try bytes.write(to: metadata)
      do { _ = try await store.actionReceipts(); XCTFail("Malformed/extended metadata") } catch { }
      XCTAssertEqual(try Data(contentsOf: metadata), bytes)
    }
    // Restore valid metadata explicitly in the isolated fixture only.
    try Data(#"{"version":1,"proposals":[],"records":[],"relations":[]}"#.utf8).write(to: metadata)
    let memo = Memo(body: "placeholder")
    try await store.append(memo)
    var entries = try await store.entries()
    let target = try XCTUnwrap(entries.first)
    let file = root.appendingPathComponent("raw/\(target.day).md")
    var large = memo.toMarkdown()
    large += String(repeating: "x", count: 4 * 1024 * 1024 - large.utf8.count - 20)
    try large.write(to: file, atomically: true, encoding: .utf8)
    entries = try await store.entries()
    let proposal = try await propose("notes_append", ["card_ref": target.id, "body": String(repeating: "z", count: 100)], entries: entries)
    do { _ = try await store.apply(proposal, allowedCardRefs: [target.id]); XCTFail("Bounded raw day cap") } catch { }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), large)
    let receipts = try await store.actionReceipts()
    XCTAssertTrue(receipts.isEmpty)
  }
}
