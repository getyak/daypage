import XCTest
@testable import DayPageCore

final class ChatHistoryTests: XCTestCase {
  func testLegacyFilesAppearAcrossScopesAndCorruptionIsReportedWithoutRewrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent(".daypage/chats")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let id = UUID()
    let legacy = Data("{\"id\":\"\(id)\",\"scope\":\"selected-note-id\",\"messages\":[{\"id\":\"\(UUID())\",\"role\":\"user\",\"content\":\"Old question\"}],\"draft\":\"Old draft\"}".utf8)
    let file = folder.appendingPathComponent("\(id).json")
    try legacy.write(to: file)
    try Data("broken".utf8).write(to: folder.appendingPathComponent("\(UUID()).json"))
    let store = ConversationStore(root: root)
    let new = try await store.createSession(scope: "all-notes")
    try await store.save(new.conversation, revision: 1, lease: new.lease)
    let history = try await store.history()
    XCTAssertEqual(Set(history.conversations.map(\.id)), [id, new.conversation.id])
    XCTAssertEqual(history.unreadableCount, 1)
    let opened = try await store.beginSession(id: id)
    XCTAssertEqual(opened.conversation.draft, "Old draft")
    XCTAssertEqual(opened.conversation.scope, "selected-note-id")
    XCTAssertEqual(try Data(contentsOf: file), legacy)
  }

  func testCharacterSnapshotRotationAndInterruptedMessagesSurviveRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationStore(root: root)
    let first = ChatCharacter(name: "Moss", role: "Editor", soul: "Be concrete")
    let second = ChatCharacter(name: "River", role: "Friend", soul: "Listen patiently")
    try await store.saveCharacters([first, second])
    var conversation = Conversation()
    conversation.characters = [first, second]
    conversation.rotatesCharacters = true
    XCTAssertEqual(conversation.nextCharacter.id, first.id)
    conversation.messages.append(.init(role: .assistant, content: "Partial", reasoning: "Summary", character: first, delivery: .interrupted))
    XCTAssertEqual(conversation.nextCharacter.id, second.id)
    try await store.save(conversation)
    let restarted = ConversationStore(root: root)
    let loaded = try await restarted.load(id: conversation.id)
    XCTAssertEqual(loaded.messages.last?.character?.name, "Moss")
    XCTAssertEqual(loaded.messages.last?.delivery, .interrupted)
    XCTAssertEqual(loaded.messages.last?.reasoning, "Summary")
    let characters = try await restarted.loadCharacters()
    XCTAssertEqual(characters, [first, second])
  }
}
