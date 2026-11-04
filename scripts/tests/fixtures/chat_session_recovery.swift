import DayPageCore
import Foundation

@MainActor final class NotebookModel {
  let conversations: ConversationStore
  let store: NotebookStore
  var entries: [NotebookEntry] = []
  var configuration = AIConfiguration(baseURL: "http://127.0.0.1:1/v1", model: "fixture-model", allowsLocalHTTP: true)
  init(root: URL) { conversations = ConversationStore(root: root); store = NotebookStore(root: root) }
  func refresh() async { if let values = try? await store.entries() { entries = values } }
  func readToolAttachment(cardRef: String, index: Int, allowedEntries: [NotebookEntry]) async throws -> String {
    guard let entry = allowedEntries.first(where: { $0.id == cardRef }), entry.memo.attachments.indices.contains(index) else { throw NotebookError.conflict }
    let attachment = entry.memo.attachments[index]
    let url = try await store.assetURL(attachment.file, for: entry)
    return try await AttachmentTextReader.read(url: url, kind: attachment.kind, transcript: attachment.transcript)
  }
}

@main enum ChatSessionRecoveryChecks {
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-session-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let notebook = NotebookModel(root: root)
    let scope = "only-this-selected-note"
    let old = Conversation(scope: scope, messages: [.init(role: .user, content: "Old question"), .init(role: .assistant, content: "Completed answer")])
    try await notebook.conversations.save(old)
    let session = ChatSession()
    await session.load(notebook: notebook, selectedIDs: [scope])
    precondition(session.ready)
    session.draft = "A new unsent question"
    let marker = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".daypage"), includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix("chat-scope-") }!
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
    session.persistDraft()
    try await Task.sleep(nanoseconds: 500_000_000)
    precondition(session.error != nil)
    precondition(!session.canRetryReply, "Saving a draft must never offer to resend an old question")
    try FileManager.default.removeItem(at: marker)
    await session.recover(notebook: notebook, context: .build(entries: [], question: ""))
    precondition(session.draft == "A new unsent question")
    precondition(session.conversation.messages.count == 2, "Save recovery must not send or append a reply")
    let saved = try await notebook.conversations.load(id: old.id)
    precondition(saved.draft == session.draft)

    let chatFile = root.appendingPathComponent(".daypage/chats/\(old.id).json")
    try Data("broken".utf8).write(to: chatFile)
    let failedLoad = ChatSession()
    await failedLoad.load(notebook: notebook, selectedIDs: [scope])
    precondition(!failedLoad.ready && failedLoad.error != nil)
    await failedLoad.newConversation()
    precondition(failedLoad.ready)
    precondition(failedLoad.conversation.scope == scope, "A failed selected-note load must not broaden a new chat to all notes")
    let retained = try Data(contentsOf: chatFile)
    precondition(retained == Data("broken".utf8), "Keep unreadable history untouched")
    print("PASS: save recovery preserves the new draft; failed history keeps selected-note scope")
    let port = CommandLine.arguments[1]
    let streamed = ChatSession()
    await streamed.load(notebook: notebook, selectedIDs: nil)
    notebook.configuration.baseURL = "http://127.0.0.1:\(port)/valid/v1"
    streamed.draft = "A streaming question"
    streamed.send(notebook: notebook, context: .build(entries: [], question: ""))
    try await waitForReply(streamed)
    precondition(streamed.conversation.messages.last?.content == "你好 **world**")
    precondition(streamed.conversation.messages.last?.reasoning == "Provider summary")
    precondition(streamed.conversation.messages.last?.delivery == .complete)
    precondition(streamed.draft.isEmpty)
    print("PASS: real fragmented UTF-8/CRLF stream completes and saves separate reasoning")

    notebook.configuration.baseURL = "http://127.0.0.1:\(port)/truncated/v1"
    streamed.draft = "A truncated question"
    streamed.send(notebook: notebook, context: .build(entries: [], question: ""))
    try await waitForReply(streamed)
    precondition(streamed.conversation.messages.last?.content == "你好 **world**")
    precondition(streamed.conversation.messages.last?.delivery == .interrupted)
    precondition(streamed.draft == "A truncated question")
    let count = streamed.conversation.messages.count
    streamed.draft = "Edited after interruption"
    await streamed.recover(notebook: notebook, context: .build(entries: [], question: ""))
    precondition(streamed.conversation.messages.count == count)
    precondition(streamed.draft == "Edited after interruption")
    print("PASS: truncated stream preserves partial output; retry never overwrites an edited draft")

    notebook.configuration.baseURL = "http://127.0.0.1:\(port)/cancel/v1"
    streamed.draft = "A cancelled question"
    streamed.send(notebook: notebook, context: .build(entries: [], question: ""))
    for _ in 0..<50 {
      if streamed.conversation.messages.last?.content.isEmpty == false { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    precondition(streamed.sending && streamed.conversation.messages.last?.content.isEmpty == false)
    streamed.cancel()
    try await waitForReply(streamed)
    let savedPartial = try await notebook.conversations.load(id: streamed.conversation.id)
    precondition(savedPartial.messages.last?.delivery == .interrupted)
    precondition(savedPartial.draft == "A cancelled question")
    precondition(savedPartial.messages.last?.content == "你好 **world**")
    print("PASS: cancelling live transport durably preserves received content and question")

    for mode in ["redirect", "oversized"] {
      notebook.configuration.baseURL = "http://127.0.0.1:\(port)/\(mode)/v1"
      streamed.draft = "A bounded question"
      streamed.send(notebook: notebook, context: .build(entries: [], question: ""))
      try await waitForReply(streamed)
      precondition(streamed.conversation.messages.last?.delivery == .interrupted)
      precondition(!streamed.draft.isEmpty)
    }
    print("PASS: redirect and oversized responses fail without losing drafts")
    let beforeSwitch = try await notebook.conversations.history().conversations.count
    streamed.draft = "Flush this before switching"
    let firstSwitch = Task { await streamed.newConversation() }
    let secondSwitch = Task { await streamed.newConversation() }
    await firstSwitch.value; await secondSwitch.value
    let afterSwitch = try await notebook.conversations.history().conversations.count
    precondition(afterSwitch == beforeSwitch + 1, "Concurrent navigation must not race two session transitions")
    print("PASS: rapid conversation navigation is serialized and flushes the old draft")
    try await checkReviewedActions(root: root.appendingPathComponent("reviewed-actions"))
  }
  @MainActor private static func checkReviewedActions(root: URL) async throws {
    let notebook = NotebookModel(root: root)
    let result = try await NoteToolExecutor.execute(name: "notes_create",
      arguments: #"{"body":"A reviewed synthetic note"}"#,
      context: .init(entries: [], proposalWriter: { try await notebook.store.saveProposal($0) }))
    guard let proposal = result.proposals.first else { preconditionFailure("Missing proposal") }
    var reply = ChatMessage(role: .assistant, content: "Review", delivery: .complete)
    reply.proposals = [proposal]
    var conversation = Conversation(messages: [reply]); conversation.usesTools = true
    try await notebook.conversations.save(conversation)
    let first = ChatSession()
    await first.load(notebook: notebook, selectedIDs: nil)
    precondition(first.canReviewActions)
    let saved = await first.confirm(proposal, messageID: reply.id, notebook: notebook)
    precondition(saved && notebook.entries.count == 1)
    let receipt = first.receipt(for: proposal)
    precondition(receipt?.status == .applied)
    let reopened = ChatSession()
    await reopened.load(notebook: notebook, selectedIDs: nil)
    precondition(reopened.receipt(for: proposal) == receipt)
    let staleUndo = await first.confirm(proposal, messageID: reply.id, notebook: notebook, undo: true)
    precondition(!staleUndo && notebook.entries.count == 1, "A superseded session must never undo")
    await reopened.setIncludesNotes(false)
    let disabledUndo = await reopened.confirm(proposal, messageID: reply.id, notebook: notebook, undo: true)
    precondition(!disabledUndo && notebook.entries.count == 1)
    await reopened.setIncludesNotes(true); await reopened.setUsesTools(true)
    let undone = await reopened.confirm(proposal, messageID: reply.id, notebook: notebook, undo: true)
    precondition(undone && notebook.entries.isEmpty)
    print("PASS: native session confirms one real note, reads receipts after reopening, rejects stale/disabled undo")
    let journal = root.appendingPathComponent(".daypage/note-actions.json")
    try FileManager.default.moveItem(at: journal, to: root.appendingPathComponent("retained-action-journal.json"))
    let damaged = ChatSession()
    await damaged.load(notebook: notebook, selectedIDs: nil)
    precondition(!damaged.actionsReady && damaged.actionError != nil)
    precondition(damaged.receipt(for: proposal)?.status == .undone,
      "Losing a journal must never turn a known receipt into a new proposal")
    let blocked = await damaged.confirm(proposal, messageID: reply.id, notebook: notebook)
    precondition(!blocked && notebook.entries.isEmpty)
    print("PASS: missing action history preserves known receipt state and blocks replay")
  }
  @MainActor private static func waitForReply(_ session: ChatSession) async throws {
    for _ in 0..<80 {
      if !session.sending { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    preconditionFailure("The local fixture did not finish within 8 seconds")
  }
}
