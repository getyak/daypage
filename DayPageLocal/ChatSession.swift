import DayPageCore
import SwiftUI

@MainActor
final class ChatSession: ObservableObject {
  enum Recovery { case none, load, save, reply }
  @Published var conversation = Conversation()
  @Published var draft = ""
  @Published var sending = false
  @Published private(set) var switching = false
  @Published var ready = false
  @Published var error: String?
  @Published private(set) var recovery: Recovery = .none
  @Published var libraryError: String?
  @Published private(set) var toolStatus: String?
  @Published private(set) var applyingProposal: UUID?
  @Published private(set) var persistedReceipts: [UUID: NoteActionReceipt] = [:]
  @Published private(set) var actionsReady = false
  @Published var actionError: String?
  @Published var characters: [ChatCharacter] = [.companion]
  @Published var update = 0
  private var revision: UInt64 = 0
  private var task: Task<Void, Never>?
  private var draftTask: Task<Void, Never>?
  private var store: ConversationStore?
  private var actionStore: NotebookStore?
  private var lease: UUID?
  private var lastCheckpoint = Date.distantPast
  private var requestedScope = "all-notes"
  var canRetryReply: Bool {
    recovery == .reply && draft == conversation.messages.last(where: { $0.role == .user })?.content
  }
  var canReviewActions: Bool {
    ready && actionsReady && !sending && !switching && applyingProposal == nil
      && conversation.includesNotes != false && conversation.usesTools == true
  }

  func load(notebook: NotebookModel, selectedIDs: Set<String>?) async {
    guard !ready else { return }
    store = notebook.conversations
    actionStore = notebook.store
    do {
      let scope = selectedIDs.map { $0.sorted().joined(separator: "\n") } ?? "all-notes"
      requestedScope = scope
      adopt(try await notebook.conversations.beginSession(scope: scope))
      await reloadReceipts()
      await reloadCharacters()
    } catch {
      recovery = .load
      self.error = String(localized: "The previous conversation could not be read. Its file is still on this device.")
    }
  }
  private func adopt(_ session: (conversation: Conversation, lease: UUID)) {
    conversation = session.conversation
    for index in conversation.messages.indices where conversation.messages[index].delivery == .streaming {
      conversation.messages[index].delivery = .interrupted
    }
    lease = session.lease; revision = 0; draft = conversation.draft
    error = nil; recovery = .none; ready = true; update += 1
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
      catch { self.recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
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
    guard !sending, !switching, applyingProposal == nil, let store else { return false }
    switching = true
    defer { switching = false }
    draftTask?.cancel()
    do {
      try await flush()
      adopt(try await store.beginSession(id: id))
      await reloadReceipts()
      try await flush()
      return true
    } catch {
      recovery = .save
      self.error = String(localized: "Could not switch conversations. Your current question is kept.")
      return false
    }
  }
  func newConversation() async {
    guard !sending, !switching, applyingProposal == nil, let store else { return }
    switching = true
    defer { switching = false }
    draftTask?.cancel()
    do {
      try await flush()
      let scope = ready ? conversation.scope : requestedScope
      let selected = conversation.characters
      let rotation = conversation.rotatesCharacters
      let includesNotes = conversation.includesNotes
      let usesTools = conversation.usesTools
      adopt(try await store.createSession(scope: scope))
      conversation.characters = selected; conversation.rotatesCharacters = rotation
      conversation.includesNotes = includesNotes; conversation.usesTools = usesTools
      await reloadReceipts()
      try await flush()
    } catch { recovery = .save; self.error = String(localized: "Could not switch conversations. Your current question is kept.") }
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
      error = nil; recovery = .none
      return true
    } catch { recovery = .save; self.error = String(localized: "The character could not be saved. Your edits are kept."); return false }
  }
  func selectCharacters(_ selected: [ChatCharacter], rotating: Bool) async {
    guard !sending, !selected.isEmpty else { return }
    conversation.characters = selected; conversation.rotatesCharacters = rotating
    do { try await flush(); error = nil; recovery = .none }
    catch { recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
  }
  func setIncludesNotes(_ value: Bool) async {
    guard !sending, applyingProposal == nil else { return }
    conversation.includesNotes = value
    if !value { conversation.usesTools = false }
    do { try await flush(); error = nil; recovery = .none } catch { recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
  }
  func setUsesTools(_ value: Bool) async {
    guard !sending, !switching, applyingProposal == nil, !value || conversation.includesNotes != false else { return }
    conversation.usesTools = value
    do { try await flush(); error = nil; recovery = .none }
    catch { recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
  }
  func recover(notebook: NotebookModel, context: NoteContext) async {
    switch recovery {
    case .load: await load(notebook: notebook, selectedIDs: requestedScope == "all-notes" ? nil : Set(requestedScope.components(separatedBy: "\n")))
    case .reply where canRetryReply: send(notebook: notebook, context: context, retry: true)
    case .save, .reply:
      do { try await flush(); error = nil; recovery = .none }
      catch { recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
    case .none: break
    }
  }
  func send(notebook: NotebookModel, context: NoteContext, retry: Bool = false) {
    guard ready, !sending, !switching, applyingProposal == nil else { return }
    let question = (retry ? conversation.messages.last(where: { $0.role == .user })?.content ?? "" : draft)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= 4000 else { return }
    guard !retry || canRetryReply else { return }
    let config = notebook.configuration
    do {
      let origin = try config.origin
      _ = try config.endpoint
      let key = config.usesAPIKey ? try KeychainSecretStore.read(origin: origin) : ""
      let character = retry ? conversation.messages.last?.character ?? conversation.nextCharacter : conversation.nextCharacter
      let useTools = conversation.usesTools == true && conversation.includesNotes != false
      draftTask?.cancel(); sending = true; error = nil; recovery = .none
      toolStatus = nil
      if !retry, conversation.messages.last?.role != .user || conversation.messages.last?.content != question {
        conversation.messages.append(.init(role: .user, content: question))
      }
      guard let userIndex = conversation.messages.lastIndex(where: { $0.role == .user }) else {
        sending = false; return
      }
      if conversation.messages[userIndex].createdAt == nil { conversation.messages[userIndex].createdAt = Date() }
      let userID = conversation.messages[userIndex].id
      let userDate = conversation.messages[userIndex].createdAt ?? Date()
      draft = question; conversation.draft = question
      let outbound = conversation.messages.filter { $0.delivery != .interrupted && $0.delivery != .streaming && !$0.content.isEmpty }
      let reply = ChatMessage(role: .assistant, content: "", character: character, delivery: .streaming)
      conversation.messages.append(reply)
      update += 1
      task = Task {
        defer { sending = false; toolStatus = nil; update += 1 }
        do {
          try await flush() // Save the question before starting any network request.
          lastCheckpoint = Date()
          if useTools {
            let allNotes = conversation.scope == "all-notes"
            let authorizedRefs = allNotes ? Set<String>() : Set(conversation.scope.components(separatedBy: "\n"))
            let snapshot = try await notebook.store.toolSnapshot(allowedCardRefs: authorizedRefs, allNotes: allNotes)
            let allowedEntries = snapshot.entries
            guard let currentLease = lease else { throw NotebookError.conflict }
            let chatStore = notebook.conversations
            let conversationID = conversation.id, scope = conversation.scope
            let toolContext = NoteToolContext(entries: allowedEntries, attachmentReader: { cardRef, index in
              try await notebook.readToolAttachment(cardRef: cardRef, index: index, allowedEntries: allowedEntries)
            }, relations: snapshot.relations, proposalWriter: { try await notebook.store.saveProposal($0) },
              proposalNamespace: userID, proposalCreatedAt: userDate,
              authorizedCardRefs: authorizedRefs, allNotes: allNotes, allowsCreation: true,
              validateAccess: { try await chatStore.validateToolAccess(conversationID: conversationID,
                lease: currentLease, scope: scope) })
            await notebook.refresh()
            try await AIClient().runWithTools(configuration: config, apiKey: key, messages: outbound,
              context: NoteContext.build(entries: allowedEntries, question: question), toolContext: toolContext, character: character) { [weak self] event in
                try await self?.receiveAgent(event, replyID: reply.id)
              }
          } else {
            let fresh: [NotebookEntry]
            if conversation.includesNotes == false { fresh = [] }
            else { fresh = try await notebook.store.entries() }
            let allowed = ConversationNoteScope.entries(fresh, conversation: conversation, requireTools: false)
            try await AIClient().stream(configuration: config, apiKey: key, messages: outbound,
              context: NoteContext.build(entries: allowed, question: question), character: character) { [weak self] event in
                try await self?.receive(event, replyID: reply.id)
              }
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
            : (error as? AgentError)?.errorDescription.map { NSLocalizedString($0, comment: "") }
              ?? String(localized: "Could not finish the reply. Your question and partial reply are kept. Try again.")
          do { try await flush(); self.recovery = .reply; self.error = savedError }
          catch { self.recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") }
        }
      }
    } catch {
      recovery = .none
      self.error = String(localized: "Check your AI connection in Settings before sending.")
    }
  }
  private func receiveAgent(_ event: AgentEvent, replyID: UUID) async throws {
    try Task.checkCancellation()
    guard let index = conversation.messages.firstIndex(where: { $0.id == replyID }) else { throw CancellationError() }
    switch event {
    case .stream(let stream): try await receive(stream, replyID: replyID)
    case .toolStarted: toolStatus = String(localized: "Looking through your notes…"); update += 1
    case .sources(let sources): conversation.messages[index].sources = sources; update += 1
    case .proposals(let proposals):
      conversation.messages[index].proposals = proposals
      try await flush()
      update += 1
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

  func reloadReceipts() async {
    guard let actionStore else { return }
    let known = conversation.messages.flatMap { $0.receipts ?? [] }
      .reduce(into: [UUID: NoteActionReceipt]()) { $0[$1.id] = $1 }
    do {
      let receipts = try await actionStore.actionReceipts()
      guard Set(receipts.map(\.id)).count == receipts.count else { throw NotebookError.ambiguousRecord }
      let disk = receipts.reduce(into: [UUID: NoteActionReceipt]()) { $0[$1.id] = $1 }
      guard known.allSatisfy({ id, old in
        disk[id]?.proposal == old.proposal && disk[id]?.appliedAt == old.appliedAt
          && (old.status != .undone || disk[id]?.status == .undone)
      }) else { throw NoteActionError.corruptMetadata }
      persistedReceipts = disk
      actionsReady = true
      actionError = nil
    } catch {
      // Never present a known historical success as a new unsaved proposal.
      persistedReceipts.merge(known) { current, _ in current }
      actionsReady = false
      actionError = String(localized: "Previous changes could not be checked. Your notes are kept. Retry before saving another change.")
    }
  }

  func receipt(for proposal: NoteActionProposal) -> NoteActionReceipt? {
    persistedReceipts[proposal.id]
  }

  func dismissProposal(_ proposal: NoteActionProposal, messageID: UUID) async {
    guard canReviewActions, receipt(for: proposal) == nil,
      let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
      conversation.messages[index].proposals?.contains(proposal) == true else { return }
    var dismissed = conversation.messages[index].dismissedProposalIDs ?? []
    if !dismissed.contains(proposal.id) { dismissed.append(proposal.id) }
    conversation.messages[index].dismissedProposalIDs = dismissed
    do { try await flush() }
    catch { actionError = String(localized: "The cancellation could not be saved. No note was changed. Try again.") }
    update += 1
  }

  @discardableResult
  func confirm(_ proposal: NoteActionProposal, messageID: UUID, notebook: NotebookModel,
    undo: Bool = false) async -> Bool {
    guard canReviewActions,
      let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
      conversation.messages[index].delivery != .streaming,
      conversation.messages[index].proposals?.contains(proposal) == true,
      conversation.messages[index].dismissedProposalIDs?.contains(proposal.id) != true else { return false }
    let conversationID = conversation.id
    applyingProposal = proposal.id; actionError = nil
    defer { applyingProposal = nil; update += 1 }
    do {
      let fresh = try await notebook.store.entries()
      guard conversation.id == conversationID, conversation.includesNotes != false,
        conversation.usesTools == true else { throw NotebookError.conflict }
      var refs = conversation.scope == "all-notes" ? Set(fresh.map(\.id))
        : Set(conversation.scope.components(separatedBy: "\n"))
      if conversation.scope == "all-notes", let relation = proposal.relation {
        refs.formUnion([relation.from.cardRef, relation.to.cardRef])
      }
      guard let store, let lease else { throw NotebookError.conflict }
      let authorization = try await store.authorizeAction(conversationID: conversationID,
        messageID: messageID, lease: lease, proposal: proposal, allowsCreation: true)
      let saved: NoteActionReceipt
      if undo {
        guard let receipt = persistedReceipts[proposal.id], receipt.status == .applied else { return false }
        saved = try await notebook.store.undo(receipt, allowedCardRefs: refs, authorization: authorization)
      } else {
        saved = try await notebook.store.apply(proposal, allowedCardRefs: refs, authorization: authorization)
      }
      persistedReceipts[saved.id] = saved
      var receipts = conversation.messages[index].receipts ?? []
      receipts.removeAll { $0.id == saved.id }; receipts.append(saved)
      conversation.messages[index].receipts = receipts
      await notebook.refresh()
      do { try await flush() }
      catch { actionError = String(localized: "The change was saved. Its conversation status could not be saved; reopen to check the receipt.") }
      return true
    } catch {
      await reloadReceipts()
      await notebook.refresh()
      actionError = (error as? NotebookError)?.errorDescription.map { NSLocalizedString($0, comment: "") }
        ?? (error as? NoteActionError)?.errorDescription.map { NSLocalizedString($0, comment: "") }
        ?? String(localized: "This change could not be completed. The proposal is kept. Check the note and try again.")
      return false
    }
  }
  func leave() {
    draftTask?.cancel(); task?.cancel()
    Task { do { try await flush() } catch { self.recovery = .save; self.error = String(localized: "Your draft could not be saved. Keep this screen open and try again.") } }
  }
}
