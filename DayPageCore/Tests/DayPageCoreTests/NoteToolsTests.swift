import XCTest
@testable import DayPageCore

final class NoteToolsTests: XCTestCase {
  private let sharedID = UUID(uuidString: "00000000-0000-0000-0000-000000000369")!
  private func entry(_ body: String, day: String = "2026-11-03", namespace: String = "") -> NotebookEntry {
    NotebookEntry(memo: Memo(id: sharedID, body: body), day: day, namespace: namespace)
  }
  private func object(_ result: NoteToolResult) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
  }
  func testSearchHasNoFallbackAndNeverExpandsHostScope() async throws {
    let allowed = entry("山里旅行 #计划")
    let context = NoteToolContext(entries: [allowed])
    let found = try await NoteToolExecutor.execute(name: "notes_search", arguments: #"{"query":"旅行"}"#, context: context)
    XCTAssertEqual(found.sources.map(\.cardRef), [allowed.id])
    let absent = try await NoteToolExecutor.execute(name: "notes_search", arguments: #"{"query":"missing"}"#, context: context)
    XCTAssertEqual(try object(absent)["total"] as? Int, 0)
    XCTAssertTrue(absent.sources.isEmpty)
    let denied = try await NoteToolExecutor.execute(name: "notes_read", arguments: #"{"card_ref":"outside/2026-11-03/00000000-0000-0000-0000-000000000369"}"#, context: context)
    XCTAssertTrue(denied.isError)
    XCTAssertFalse(denied.content.contains("山里"))
  }
  func testReadUsesFullNamespaceDayAndUUIDAndSourcesRoundTrip() async throws {
    let local = entry("Local")
    let imported = entry("Imported", namespace: "import-a/import-b")
    let args = String(data: try JSONSerialization.data(withJSONObject: ["card_ref": imported.id]), encoding: .utf8)!
    let result = try await NoteToolExecutor.execute(name: "notes_read", arguments: args,
      context: NoteToolContext(entries: [local, imported]))
    XCTAssertEqual(try object(result)["body"] as? String, "Imported")
    XCTAssertEqual(result.sources.map(\.cardRef), [imported.id])
    XCTAssertEqual(try JSONDecoder().decode([NoteToolSource].self, from: JSONEncoder().encode(result.sources)), result.sources)
    let context = NoteContext.build(entries: [local, imported], question: "")
    XCTAssertTrue(context.text.contains(imported.id))
  }
  func testListDateRangeAndStatisticsAreExactBeforeResultLimit() async throws {
    let entries = (1...25).map { index in
      NotebookEntry(memo: Memo(body: "note #work #work \(index)"), day: index < 20 ? "2026-11-02" : "2026-11-03")
    } + [entry("Excluded #old", day: "2026-11-01")]
    let context = NoteToolContext(entries: entries)
    let args = #"{"from_day":"2026-11-02","to_day":"2026-11-03","limit":2}"#
    let listed = try await NoteToolExecutor.execute(name: "notes_list", arguments: args, context: context)
    XCTAssertEqual(try object(listed)["total"] as? Int, 25)
    XCTAssertEqual(listed.sources.count, 2)
    let stats = try await NoteToolExecutor.execute(name: "notes_stats", arguments: #"{"from_day":"2026-11-02"}"#, context: context)
    XCTAssertEqual(try object(stats)["card_count"] as? Int, 25)
    XCTAssertEqual(try object(stats)["day_count"] as? Int, 2)
    let tags = try await NoteToolExecutor.execute(name: "notes_tags", arguments: #"{"from_day":"2026-11-02"}"#, context: context)
    let counts = try XCTUnwrap(try object(tags)["tags"] as? [[String: Any]])
    XCTAssertEqual(counts.count, 1)
    XCTAssertEqual(counts.first?["tag"] as? String, "work")
    XCTAssertEqual(counts.first?["card_count"] as? Int, 25)
  }
  func testMalformedAndUnboundedArgumentsReturnErrorsWithoutReadingAssets() async throws {
    let context = NoteToolContext(entries: [entry("Text")], attachmentReader: { _, _ in
      XCTFail("Invalid input must never reach an attachment reader"); return "private"
    })
    for (name, args) in [
      ("notes_search", "{bad"), ("notes_search", #"{"query":""}"#),
      ("notes_list", #"{"limit":true}"#), ("notes_list", #"{"limit":21}"#),
      ("notes_list", #"{"from_day":"2026-02-30"}"#),
      ("notes_list", #"{"from_day":"2026-11-03","to_day":"2026-01-01"}"#),
      ("notes_list", #"{"path":"/private"}"#),
      ("assets_read", #"{"card_ref":"outside","attachment_index":0}"#),
      ("files_write", "{}")
    ] {
      let result = try await NoteToolExecutor.execute(name: name, arguments: args, context: context)
      XCTAssertTrue(result.isError, "\(name): \(args)")
      XCTAssertTrue(result.sources.isEmpty)
    }
  }
  func testReadAndAttachmentTextAreBoundedAndAssetIdentityIsCheckedFirst() async throws {
    let note = NotebookEntry(memo: Memo(attachments: [.init(file: "raw/assets/fixture.pdf", kind: "file")],
      body: String(repeating: "汉", count: 10000)), day: "2026-11-03")
    let context = NoteToolContext(entries: [note], attachmentReader: { ref, index in
      XCTAssertEqual(ref, note.id); XCTAssertEqual(index, 0)
      return String(repeating: "文", count: 10000)
    })
    let readArgs = String(data: try JSONSerialization.data(withJSONObject: ["card_ref": note.id]), encoding: .utf8)!
    let read = try await NoteToolExecutor.execute(name: "notes_read", arguments: readArgs, context: context)
    XCTAssertEqual((try object(read)["body"] as? String)?.count, 6000)
    XCTAssertEqual(try object(read)["truncated"] as? Bool, true)
    let args = String(data: try JSONSerialization.data(withJSONObject: ["card_ref": note.id, "attachment_index": 0]), encoding: .utf8)!
    let asset = try await NoteToolExecutor.execute(name: "assets_read", arguments: args, context: context)
    XCTAssertEqual((try object(asset)["text"] as? String)?.count, 6000)
    XCTAssertFalse(asset.content.contains("raw/assets"))
    XCTAssertEqual(asset.sources.map(\.cardRef), [note.id])
    let noReader = try await NoteToolExecutor.execute(name: "assets_read", arguments: args, context: NoteToolContext(entries: [note]))
    XCTAssertTrue(noReader.isError)
  }
}
