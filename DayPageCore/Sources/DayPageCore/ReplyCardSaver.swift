import Foundation

/// Explicit reply capture is independent of the quick-capture draft and assets.
public enum ReplyCardSaver {
  private static let coordinator = ReplySaveCoordinator()
  public static func save(id: UUID, text: String, store: NotebookStore,
    created: Date = Date()) async throws -> NotebookEntry {
    try await coordinator.save(id: id, text: text, store: store, created: created)
  }

  fileprivate static func publish(id: UUID, text: String, store: NotebookStore,
    created: Date) async throws -> NotebookEntry {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NotebookError.emptyNote
    }
    if let existing = try await find(id: id, store: store) {
      guard existing.memo.body == text else { throw NotebookError.conflict }
      return existing
    }
    do {
      try await store.append(Memo(id: id, created: created, body: text))
    } catch {
      // Another caller may have committed this same reply while append waited.
      if let existing = try await find(id: id, store: store), existing.memo.body == text {
        return existing
      }
      throw error
    }
    guard let saved = try await find(id: id, store: store) else { throw NotebookError.conflict }
    return saved
  }

  private static func find(id: UUID, store: NotebookStore) async throws -> NotebookEntry? {
    let entries = try await store.entries().filter { $0.namespace.isEmpty && $0.memo.id == id }
    guard entries.count <= 1 else { throw NotebookError.conflict }
    return entries.first
  }
}

/// Coalesces rapid taps even when separate store actors straddle a local-day boundary.
private actor ReplySaveCoordinator {
  private struct Key: Hashable { let root: URL; let id: UUID }
  private var pending: [Key: Task<NotebookEntry, Error>] = [:]

  func save(id: UUID, text: String, store: NotebookStore, created: Date) async throws -> NotebookEntry {
    let key = Key(root: store.root.standardizedFileURL, id: id)
    if let task = pending[key] {
      let result = try await task.value
      guard result.memo.body == text else { throw NotebookError.conflict }
      return result
    }
    let task = Task { try await ReplyCardSaver.publish(id: id, text: text, store: store, created: created) }
    pending[key] = task
    defer { pending[key] = nil }
    return try await task.value
  }
}
