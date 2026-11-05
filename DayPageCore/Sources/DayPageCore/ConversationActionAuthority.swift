import Foundation

/// A host-issued capability, never a model argument or a persisted instruction.
public struct NoteActionAuthorization: Sendable {
  let root: URL
  let conversationID: UUID
  let messageID: UUID
  let lease: UUID
  let scope: String
  let proposal: NoteActionProposal
  let allowsCreation: Bool
}

/// No await occurs under this lock. Session saves/lease changes and an authorized
/// note commit have a single order even across distinct Store actor instances.
enum ConversationActionGate {
  private final class State: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var leases: [String: UUID] = [:]
  }
  private static let state = State()
  private static func key(root: URL, id: UUID) -> String {
    NotebookPath.canonicalPath(root) + "\n" + id.uuidString
  }
  static func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
    state.lock.lock(); defer { state.lock.unlock() }
    return try operation()
  }
  static func register(root: URL, id: UUID, lease: UUID) {
    synchronized { state.leases[key(root: root, id: id)] = lease }
  }
  static func validateLease(root: URL, id: UUID, lease: UUID?) throws {
    if let current = state.leases[key(root: root, id: id)], current != lease { throw NotebookError.conflict }
  }
  static func issue(root: URL, conversationID: UUID, messageID: UUID, lease: UUID,
    proposal: NoteActionProposal, allowsCreation: Bool) throws -> NoteActionAuthorization {
    try synchronized {
      let conversation = try read(root: root, id: conversationID)
      let permit = NoteActionAuthorization(root: root.standardizedFileURL, conversationID: conversationID,
        messageID: messageID, lease: lease, scope: conversation.scope, proposal: proposal,
        allowsCreation: allowsCreation)
      try validate(permit, root: root, proposal: proposal, conversation: conversation)
      return permit
    }
  }
  static func validateToolAccess(root: URL, conversationID: UUID, lease: UUID, scope: String) throws {
    try synchronized {
      let conversation = try read(root: root, id: conversationID)
      guard state.leases[key(root: root, id: conversationID)] == lease,
        conversation.scope == scope, conversation.usesTools == true,
        conversation.includesNotes != false else { throw NotebookError.conflict }
    }
  }
  static func withAuthorization<T>(_ permit: NoteActionAuthorization?, root: URL,
    proposal: NoteActionProposal, allowedCardRefs: Set<String>, operation: () throws -> T) throws -> T {
    // Trusted standalone core operations retain their explicit caller authority.
    // Every shipping native review passes a non-nil live conversation permit.
    guard let permit else { return try operation() }
    return try synchronized {
      let conversation = try read(root: root, id: permit.conversationID)
      try validate(permit, root: root, proposal: proposal, conversation: conversation)
      if permit.scope != "all-notes" {
        guard allowedCardRefs.isSubset(of: Set(permit.scope.components(separatedBy: "\n"))) else {
          throw NoteActionError.outOfScope
        }
      }
      return try operation()
    }
  }
  private static func validate(_ permit: NoteActionAuthorization, root: URL,
    proposal: NoteActionProposal, conversation: Conversation) throws {
    guard NotebookPath.canonicalPath(permit.root) == NotebookPath.canonicalPath(root),
      state.leases[key(root: root, id: conversation.id)] == permit.lease,
      conversation.id == permit.conversationID, conversation.scope == permit.scope,
      conversation.includesNotes != false, conversation.usesTools == true,
      permit.proposal == proposal, proposal.kind != .create || permit.allowsCreation,
      let message = conversation.messages.first(where: { $0.id == permit.messageID }),
      message.role == .assistant, message.delivery != .streaming,
      message.proposals?.contains(proposal) == true,
      message.dismissedProposalIDs?.contains(proposal.id) != true else { throw NotebookError.conflict }
  }
  private static func read(root: URL, id: UUID) throws -> Conversation {
    var path = root.standardizedFileURL
    for component in [".daypage", "chats", id.uuidString + ".json"] {
      path.appendPathComponent(component)
      guard (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
        throw NotebookError.invalidPath
      }
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
      let size = attrs[.size] as? NSNumber, size.int64Value <= 16 * 1024 * 1024 else { throw NotebookError.unreadableFile }
    let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
    let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 16 * 1024 * 1024 else { throw NotebookError.unreadableFile }
    let conversation = try JSONDecoder().decode(Conversation.self, from: data)
    guard conversation.id == id else { throw NotebookError.conflict }
    return conversation
  }
}
