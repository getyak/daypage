import XCTest
@testable import DayPageCore

final class NoteDiscoveryTests: XCTestCase {
  private func call(_ name: String, _ args: [String: Any], _ entries: [NotebookEntry],
                    relations: [NoteRelation] = []) async throws -> NoteToolResult {
    let data = try JSONSerialization.data(withJSONObject: args)
    return try await NoteToolExecutor.execute(name: name, arguments: String(decoding: data, as: UTF8.self),
      context: .init(entries: entries, relations: relations))
  }
  private func object(_ result: NoteToolResult) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
  }

  func testChineseWithoutSpacesAndNoMatchRemainLexicalAndBounded() async throws {
    let anchor = NotebookEntry(memo: Memo(body: "今天继续设计笔记工具与知识关系"), day: "2026-11-01")
    let related = NotebookEntry(memo: Memo(body: "笔记工具需要展示知识关系的出处"), day: "2026-11-02")
    let unrelated = NotebookEntry(memo: Memo(body: "市场买菜准备番茄晚餐"), day: "2026-11-03")
    let result = try await call("notes_similar", ["card_ref": anchor.id, "limit": 1], [anchor, related, unrelated])
    XCTAssertEqual(result.sources.map(\.cardRef), [related.id])
    XCTAssertEqual(try object(result)["method"] as? String, "local_lexical_words_cjk_bigrams_tags")
    let none = try await call("notes_similar", ["query": "quartz nebula"], [anchor, related, unrelated])
    XCTAssertTrue(none.sources.isEmpty)
    XCTAssertEqual((try object(none)["cards"] as? [[String: Any]])?.count, 0)
    let empty = try await call("notes_find_duplicates", [:], [])
    XCTAssertEqual((try object(empty)["pairs"] as? [[String: Any]])?.count, 0)
  }

  func testNeighborsUseFullNamespacedIdentityAndChronologicalOrder() async throws {
    let id = UUID()
    let before = NotebookEntry(memo: Memo(id: id, created: Date(timeIntervalSince1970: 1), body: "before"), day: "2026-11-01")
    let anchor = NotebookEntry(memo: Memo(id: id, created: Date(timeIntervalSince1970: 2), body: "anchor"), day: "2026-11-02", namespace: UUID().uuidString)
    let after = NotebookEntry(memo: Memo(created: Date(timeIntervalSince1970: 3), body: "after"), day: "2026-11-03")
    let far = NotebookEntry(memo: Memo(created: Date(timeIntervalSince1970: 4), body: "far"), day: "2026-11-04")
    let result = try await call("notes_neighbors", ["card_ref": anchor.id, "limit": 2], [far, anchor, after, before])
    XCTAssertEqual(result.sources.map(\.cardRef), [before.id, after.id])
    XCTAssertEqual(try object(result)["order"] as? String, "chronological")
    let denied = try await call("notes_neighbors", ["card_ref": "/2026-11-02/\(id.uuidString)"], [anchor])
    XCTAssertTrue(denied.isError)
  }

  func testDuplicateReportsDistinguishNormalizedExactNearAndTruncatedPrefixes() async throws {
    let exactA = NotebookEntry(memo: Memo(body: "Notebook pricing experiments support careful product learning"), day: "2026-11-01")
    let exactB = NotebookEntry(memo: Memo(body: "  notebook  PRICING experiments support careful product learning \n"), day: "2026-11-02")
    let near = NotebookEntry(memo: Memo(body: "Notebook pricing experiments support careful product learning today"), day: "2026-11-03")
    let short = NotebookEntry(memo: Memo(body: "Thanks"), day: "2026-11-04")
    let result = try await call("notes_find_duplicates", ["card_ref": exactA.id], [exactA, exactB, near, short])
    let pairs = try XCTUnwrap(try object(result)["pairs"] as? [[String: Any]])
    XCTAssertEqual(pairs.count, 2)
    XCTAssertEqual(pairs.first { $0["to_card_ref"] as? String == exactB.id }?["match"] as? String, "exact_normalized")
    XCTAssertEqual(pairs.first { $0["to_card_ref"] as? String == near.id }?["match"] as? String, "near_lexical")
    let prefix = String(repeating: "notebook pricing product ", count: 300)
    let longA = NotebookEntry(memo: Memo(body: prefix + "different ending alpha"), day: "2026-11-01")
    let longB = NotebookEntry(memo: Memo(body: prefix + "different ending beta"), day: "2026-11-02")
    let longResult = try await call("notes_find_duplicates", ["card_ref": longA.id], [longA, longB])
    let longPairs = try XCTUnwrap(try object(longResult)["pairs"] as? [[String: Any]])
    XCTAssertFalse(longPairs.contains { $0["match"] as? String == "exact_normalized" })
    XCTAssertEqual(try object(longResult)["text_character_limit"] as? Int, 6000)
  }

  func testSuggestionIsReadOnlyAndListIncludesBothDirectionsOnlyWithinScope() async throws {
    let a = NotebookEntry(memo: Memo(body: "Notebook pricing experiments #product"), day: "2026-11-01")
    let b = NotebookEntry(memo: Memo(body: "Notebook product development #product"), day: "2026-11-02")
    let c = NotebookEntry(memo: Memo(body: "Another notebook"), day: "2026-11-03")
    let suggestion = try await call("relations_suggest", ["card_ref": a.id], [a, b])
    XCTAssertTrue(suggestion.proposals.isEmpty)
    let suggested = try XCTUnwrap(try object(suggestion)["suggestions"] as? [[String: Any]])
    XCTAssertEqual(suggested.first?["status"] as? String, "suggestion_only")
    XCTAssertEqual(suggested.first?["from_excerpt"] as? String, a.memo.body)
    let edge = NoteRelation(from: .init(cardRef: a.id, day: a.day, snippet: a.memo.body),
      to: .init(cardRef: b.id, day: b.day, snippet: b.memo.body), type: .derivedFrom,
      reason: "One source quotes the other", fromRevision: a.revision, toRevision: b.revision)
    let outgoing = try await call("relations_list", ["card_ref": a.id], [a, b, c], relations: [edge])
    let incoming = try await call("relations_list", ["card_ref": b.id], [a, b], relations: [edge])
    XCTAssertEqual((try object(outgoing)["relations"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual((try object(incoming)["relations"] as? [[String: Any]])?.count, 1)
    let hidden = try await call("relations_list", [:], [a], relations: [edge])
    XCTAssertEqual((try object(hidden)["relations"] as? [[String: Any]])?.count, 0)
    XCTAssertTrue(hidden.sources.isEmpty)
  }

  func testAllNewToolsRejectUnknownKeysTypesAndScope() async throws {
    let note = NotebookEntry(memo: Memo(body: "A note for argument tests"), day: "2026-11-01")
    for name in NoteToolExecutor.names.dropFirst(6) {
      let result = try await call(name, ["path": "/private/notes"], [note])
      XCTAssertTrue(result.isError, name)
      XCTAssertTrue(result.proposals.isEmpty, name)
    }
    let invalidInputs: [(String, [String: Any])] = [
      ("notes_create", ["body": ""]), ("notes_append", ["card_ref": "outside", "body": "secret"]),
      ("notes_set_pin", ["card_ref": note.id, "pinned": 1]),
      ("notes_set_tags", ["card_ref": note.id, "tags": ["bad tag"]]),
      ("notes_similar", ["card_ref": note.id, "query": "ambiguous"]),
      ("notes_neighbors", ["card_ref": note.id, "limit": true]),
      ("notes_find_duplicates", ["limit": 21]), ("relations_suggest", [:]),
      ("relations_list", ["card_ref": "outside"]),
      ("relations_link", ["from_card_ref": note.id, "to_card_ref": note.id, "type": "related", "reason": "same"]),
      ("relations_unlink", ["relation_id": UUID().uuidString])
    ]
    for (name, args) in invalidInputs {
      let result = try await call(name, args, [note])
      XCTAssertTrue(result.isError, "\(name):\(args)")
      XCTAssertTrue(result.proposals.isEmpty)
    }
    let overlapping = NotebookEntry(memo: Memo(body: "aaa"), day: "2026-11-01")
    let patch = try await call("notes_propose_patch", ["card_ref": overlapping.id, "before": "aa", "after": "b"], [overlapping])
    XCTAssertTrue(patch.isError)
  }

  func testProposalIdentityIsStableForCanonicalArgsWithinOneUserTurn() async throws {
    let note = NotebookEntry(memo: Memo(body: "Original"), day: "2026-11-01")
    let namespace = UUID(), timestamp = Date(timeIntervalSince1970: 1_799_999_999)
    let context = NoteToolContext(entries: [note], proposalNamespace: namespace, proposalCreatedAt: timestamp)
    let firstArgs = try JSONSerialization.data(withJSONObject: ["card_ref": note.id, "body": "Added"])
    let first = try await NoteToolExecutor.execute(name: "notes_append", arguments: String(decoding: firstArgs, as: UTF8.self), context: context)
    let second = try await NoteToolExecutor.execute(name: "notes_append", arguments: "{\"body\":\"Added\",\"card_ref\":\"\(note.id)\"}", context: context)
    XCTAssertEqual(first.proposals, second.proposals)
    let other = try await NoteToolExecutor.execute(name: "notes_append", arguments: String(decoding: firstArgs, as: UTF8.self), context: .init(entries: [note], proposalCreatedAt: timestamp))
    XCTAssertNotEqual(first.proposals.first?.id, other.proposals.first?.id)
  }

  func testEveryToolChecksLiveAccessBeforeReadingOrProposing() async throws {
    let probe = NoteAccessProbe()
    let entry = NotebookEntry(memo: Memo(body: "Protected note text"), day: "2026-11-01")
    let context = NoteToolContext(entries: [entry], proposalWriter: { _ in XCTFail("Revoked access cannot persist proposals") },
      validateAccess: { try await probe.check() })
    for name in NoteToolExecutor.names {
      do {
        _ = try await NoteToolExecutor.execute(name: name, arguments: "{}", context: context)
        XCTFail("\(name) must throw the live authority error before evaluating arguments")
      } catch NotebookError.conflict { }
    }
    let count = await probe.count
    XCTAssertEqual(count, NoteToolExecutor.names.count)
  }
}

private actor NoteAccessProbe {
  var count = 0
  func check() throws { count += 1; throw NotebookError.conflict }
}
