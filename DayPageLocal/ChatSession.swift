import DayPageCore
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
  @Published var conversation = Conversation()
  @Published var draft = ""
  @Published var sending = false
  @Published var ready = false
  @Published var error: String?
  @Published var libraryError: String?
  @Published var characters: [ChatCharacter] = [.companion]
  @Published var update = 0
  private var revision: UInt64 = 0
  private var task: Task<Void, Never>?
  private var draftTask: Task<Void, Never>?
  private var store: ConversationStore?
  private var lease: UUID?
  private var lastCheckpoint = Date.distantPast

  func load(notebook: NotebookModel, selectedIDs: Set<String>?) async {
    guard !ready else { return }
    store = notebook.conversations
    do {
      let scope = selectedIDs.map { $0.sorted().joined(separator: "\n") } ?? "all-notes"
      adopt(try await notebook.conversations.beginSession(scope: scope))
      await reloadCharacters()
    } catch {
      self.error = String(localized: "The previous conversation could not be read. Its file is still on this device.")
    }
  }
  private func adopt(_ session: (conversation: Conversation, lease: UUID)) {
    conversation = session.conversation
    for index in conversation.messages.indices where conversation.messages[index].delivery == .streaming {
      conversation.messages[index].delivery = .interrupted
    }
    lease = session.lease; revision = 0; draft = conversation.draft
    error = nil; ready = true; update += 1
  }
  func reloadCharacters() async {
    guard let store else { return }
    do { characters = try await store.loadCharacters(); libraryError = nil }
    catch { libraryError = String(localized: "Characters could not be read. The original file is kept. Try again.") }
  }
  func persistDraft() {
    guard ready, !sending else { return }
    draftTask?.cancel()
    draftTask = Task {
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
        try Task.checkCancellation()
        try await flush()
      } catch is CancellationError { }
      catch { self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
    }
  }
  func flush() async throws {
    guard ready, let store else { return }
    conversation.draft = draft
    conversation.updatedAt = Date()
    revision += 1
    try await store.save(conversation, revision: revision, lease: lease)
  }
  func open(id: UUID) async -> Bool {
    guard !sending, let store else { return false }
    draftTask?.cancel()
    do {
      try await flush()
      adopt(try await store.beginSession(id: id))
      try await flush()
      return true
    } catch {
      self.error = String(localized: "Could not switch conversations. Your current question is kept.")
      return false
    }
  }
  func newConversation() async {
    guard !sending, let store else { return }
    draftTask?.cancel()
    do {
      try await flush()
      let scope = conversation.scope
      let selected = conversation.characters
      let rotation = conversation.rotatesCharacters
      adopt(try await store.createSession(scope: scope))
      conversation.characters = selected; conversation.rotatesCharacters = rotation
      try await flush()
    } catch { self.error = String(localized: "Could not switch conversations. Your current question is kept.") }
  }
  func saveCharacter(_ character: ChatCharacter) async -> Bool {
    guard let store, libraryError == nil else { return false }
    var updated = characters
    if let index = updated.firstIndex(where: { $0.id == character.id }) { updated[index] = character }
    else { updated.append(character) }
    do {
      try await store.saveCharacters(updated)
      characters = updated
      if let index = conversation.characters?.firstIndex(where: { $0.id == character.id }) {
        conversation.characters?[index] = character
        try await flush()
      }
      return true
    } catch { self.error = String(localized: "The character could not be saved. Your edits are kept."); return false }
  }
  func selectCharacters(_ selected: [ChatCharacter], rotating: Bool) async {
    guard !sending, !selected.isEmpty else { return }
    conversation.characters = selected; conversation.rotatesCharacters = rotating
    do { try await flush() }
    catch { self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
  }
  func setIncludesNotes(_ value: Bool) async {
    guard !sending else { return }
    conversation.includesNotes = value
    do { try await flush() } catch { self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
  }
  func send(notebook: NotebookModel, context: NoteContext, retry: Bool = false) {
    guard ready, !sending else { return }
    let question = (retry ? conversation.messages.last(where: { $0.role == .user })?.content ?? "" : draft)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= 4000 else { return }
    let config = notebook.configuration
    do {
      let origin = try config.origin
      _ = try config.endpoint
      let key = config.usesAPIKey ? try KeychainSecretStore.read(origin: origin) : ""
      let character = retry ? conversation.messages.last?.character ?? conversation.nextCharacter : conversation.nextCharacter
      draftTask?.cancel(); sending = true; error = nil
      if !retry, conversation.messages.last?.role != .user || conversation.messages.last?.content != question {
        conversation.messages.append(.init(role: .user, content: question))
      }
      draft = question; conversation.draft = question
      let outbound = conversation.messages.filter { $0.delivery != .interrupted && $0.delivery != .streaming && !$0.content.isEmpty }
      let reply = ChatMessage(role: .assistant, content: "", character: character, delivery: .streaming)
      conversation.messages.append(reply)
      task = Task {
        defer { sending = false; update += 1 }
        do {
          try await flush() // Save the question before starting any network request.
          lastCheckpoint = Date()
          try await AIClient().stream(configuration: config, apiKey: key, messages: outbound,
            context: context, character: character) { [weak self] event in
              try await self?.receive(event, replyID: reply.id)
            }
          try Task.checkCancellation()
          guard let index = conversation.messages.firstIndex(where: { $0.id == reply.id }),
            !conversation.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else { throw AIError.invalidResponse }
          conversation.messages[index].delivery = .complete
          draft = ""
          try await flush()
        } catch {
          if let index = conversation.messages.firstIndex(where: { $0.id == reply.id }) {
            conversation.messages[index].delivery = .interrupted
          }
          draft = question
          let savedError = Task.isCancelled
            ? String(localized: "Reply stopped. Your question and partial reply are saved.")
            : String(localized: "Could not finish the reply. Your question and partial reply are kept. Try again.")
          do { try await flush(); self.error = savedError }
          catch { self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
        }
      }
    } catch {
      self.error = String(localized: "Check your AI connection in Settings before sending.")
    }
  }
  private func receive(_ event: AIStreamEvent, replyID: UUID) async throws {
    try Task.checkCancellation()
    guard let index = conversation.messages.firstIndex(where: { $0.id == replyID }) else { throw CancellationError() }
    switch event {
    case .text(let text): conversation.messages[index].content += text
    case .reasoning(let text): conversation.messages[index].reasoning = (conversation.messages[index].reasoning ?? "") + text
    case .finished: break
    }
    update += 1
    if Date().timeIntervalSince(lastCheckpoint) >= 0.5 {
      try await flush(); lastCheckpoint = Date()
    }
  }
  func cancel() { task?.cancel() }
  func leave() {
    draftTask?.cancel(); task?.cancel()
    Task { do { try await flush() } catch { self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") } }
  }
}
