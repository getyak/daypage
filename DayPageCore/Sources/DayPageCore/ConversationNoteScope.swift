import Foundation

public enum ConversationNoteScope {
  /// The host chooses this range. Neither prompts nor tool arguments can expand it.
  public static func entries(_ all: [NotebookEntry], conversation: Conversation,
    requireTools: Bool = true) -> [NotebookEntry] {
    guard conversation.includesNotes != false,
      !requireTools || conversation.usesTools == true else { return [] }
    guard conversation.scope != "all-notes" else { return all }
    let ids = Set(conversation.scope.components(separatedBy: "\n"))
    return all.filter { ids.contains($0.id) }
  }
}
