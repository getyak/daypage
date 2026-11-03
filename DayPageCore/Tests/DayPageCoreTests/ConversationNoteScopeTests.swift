import XCTest
@testable import DayPageCore

final class ConversationNoteScopeTests: XCTestCase {
  func testSwitchesDenyToolsAndSelectionUsesFullNamespace() {
    let id = UUID()
    let first = NotebookEntry(memo: Memo(id: id, body: "Allowed"), day: "2026-11-03")
    let other = NotebookEntry(memo: Memo(id: id, body: "Private import"), day: "2026-11-03", namespace: "imported")
    var chat = Conversation(scope: first.id)
    XCTAssertTrue(ConversationNoteScope.entries([first, other], conversation: chat).isEmpty)
    chat.usesTools = true
    XCTAssertEqual(ConversationNoteScope.entries([first, other], conversation: chat).map(\.id), [first.id])
    chat.includesNotes = false
    XCTAssertTrue(ConversationNoteScope.entries([first, other], conversation: chat).isEmpty)
    chat.includesNotes = true
    chat = Conversation(scope: "missing-card")
    chat.usesTools = true
    XCTAssertTrue(ConversationNoteScope.entries([first, other], conversation: chat).isEmpty)
  }

  func testFullScopeDoesNotInheritTwelveExcerptLimit() {
    let entries = (0..<30).map { NotebookEntry(memo: Memo(body: "Card \($0)"), day: "2026-11-03") }
    var chat = Conversation()
    chat.usesTools = true
    XCTAssertEqual(ConversationNoteScope.entries(entries, conversation: chat).count, 30)
  }
}
