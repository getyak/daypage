import XCTest
@testable import DayPageCore

final class NoteAuthoringAcceptanceTests: XCTestCase {
  func testCreatingANoteProducesAReviewableProposalWithoutClaimingASave() async throws {
    let result = try await NoteToolExecutor.execute(name: "notes_create",
      arguments: #"{"body":"A new idea about slow notebooks"}"#,
      context: NoteToolContext(entries: []))
    XCTAssertFalse(result.isError, "A valid creation request must produce a pending proposal")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
    XCTAssertEqual(object["status"] as? String, "pending_confirmation")
  }

  func testSimilarNotesExcludeTheAnchorAndReturnRelatedContent() async throws {
    let anchor = NotebookEntry(memo: Memo(body: "A notebook helps develop pricing ideas #product"), day: "2026-11-01")
    let related = NotebookEntry(memo: Memo(body: "Pricing experiments for the notebook product #product"), day: "2026-11-02")
    let unrelated = NotebookEntry(memo: Memo(body: "Bought tomatoes for dinner"), day: "2026-11-03")
    let arguments = try JSONSerialization.data(withJSONObject: ["card_ref": anchor.id])
    let result = try await NoteToolExecutor.execute(name: "notes_similar",
      arguments: String(decoding: arguments, as: UTF8.self),
      context: NoteToolContext(entries: [anchor, related, unrelated]))
    XCTAssertFalse(result.isError)
    XCTAssertEqual(result.sources.map(\.cardRef), [related.id])
  }
}
