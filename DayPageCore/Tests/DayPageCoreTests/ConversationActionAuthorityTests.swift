import XCTest
@testable import DayPageCore

final class ConversationActionAuthorityTests: XCTestCase {
  private func prepare(_ root: URL) async throws -> (NotebookStore, ConversationStore, Conversation, NoteActionProposal, UUID) {
    let notes = NotebookStore(root: root), chats = ConversationStore(root: root)
    let result = try await NoteToolExecutor.execute(name: "notes_create", arguments: #"{"body":"Confirmed only by the current session"}"#,
      context: .init(entries: [], proposalWriter: { try await notes.saveProposal($0) }))
    let proposal = try XCTUnwrap(result.proposals.first)
    var reply = ChatMessage(role: .assistant, content: "Review it", delivery: .complete)
    reply.proposals = [proposal]
    var conversation = Conversation(messages: [reply])
    conversation.usesTools = true
    try await chats.save(conversation)
    let session = try await chats.beginSession(id: conversation.id)
    return (notes, chats, conversation, proposal, session.lease)
  }
  func testASecondStoreRevokesTheOldSessionBeforeAnyNoteWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (notes, chats, conversation, proposal, lease) = try await prepare(root)
    let permit = try await chats.authorizeAction(conversationID: conversation.id,
      messageID: conversation.messages[0].id, lease: lease, proposal: proposal, allowsCreation: true)
    let before = try Data(contentsOf: root.appendingPathComponent(".daypage/note-actions.json"))
    let otherStore = ConversationStore(root: root)
    let otherSession = try await otherStore.beginSession(id: conversation.id)
    var disabled = otherSession.conversation; disabled.usesTools = false
    try await otherStore.save(disabled, lease: otherSession.lease)
    do {
      _ = try await notes.apply(proposal, allowedCardRefs: [], authorization: permit)
      XCTFail("A revoked session committed a note")
    } catch { }
    let entries = try await notes.entries()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".daypage/note-actions.json")), before)
    do { try await chats.save(conversation, lease: lease); XCTFail("A stale session restored old settings") }
    catch { }
  }
  func testCancellationWithinTheSameLeaseRevokesAnAlreadyIssuedPermit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (notes, chats, original, proposal, lease) = try await prepare(root)
    let permit = try await chats.authorizeAction(conversationID: original.id,
      messageID: original.messages[0].id, lease: lease, proposal: proposal, allowsCreation: true)
    var cancelled = original
    cancelled.messages[0].dismissedProposalIDs = [proposal.id]
    try await chats.save(cancelled, lease: lease)
    do { _ = try await notes.apply(proposal, allowedCardRefs: [], authorization: permit); XCTFail("Cancelled proposal committed") }
    catch { }
    let entries = try await notes.entries()
    XCTAssertTrue(entries.isEmpty)
  }
  func testLivePermitCommitsOnceAndUndoStillRequiresLiveAuthority() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (notes, chats, conversation, proposal, lease) = try await prepare(root)
    let permit = try await chats.authorizeAction(conversationID: conversation.id,
      messageID: conversation.messages[0].id, lease: lease, proposal: proposal, allowsCreation: true)
    let first = try await notes.apply(proposal, allowedCardRefs: [], authorization: permit)
    let again = try await notes.apply(proposal, allowedCardRefs: [], authorization: permit)
    XCTAssertEqual(first, again)
    let entries = try await notes.entries()
    XCTAssertEqual(entries.map(\.memo.body), ["Confirmed only by the current session"])
    _ = try await chats.beginSession(id: conversation.id)
    do { _ = try await notes.undo(first, allowedCardRefs: [], authorization: permit); XCTFail("Revoked session undid a change") }
    catch { }
    let retained = try await notes.entries()
    XCTAssertEqual(retained, entries)
  }
}
