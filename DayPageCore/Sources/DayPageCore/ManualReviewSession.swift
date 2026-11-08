import Foundation

public struct ManualReviewDraft: Sendable, Identifiable {
  public let id: UUID
  public let created: Date
  public let snapshot: ManualReviewSnapshot
  public let body: String
}

final class ManualReviewAuthority: @unchecked Sendable {
  private let lock = NSLock()
  private var active: UUID?
  func begin(_ id: UUID) { lock.lock(); active = id; lock.unlock() }
  func cancel() { lock.lock(); active = nil; lock.unlock() }
  func check(_ id: UUID) throws {
    lock.lock(); defer { lock.unlock() }
    guard active == id else { throw ManualReviewError.revoked }
  }
  func publish<T>(_ id: UUID, operation: () throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    guard active == id else { throw ManualReviewError.revoked }
    try Task.checkCancellation()
    return try operation()
  }
}

struct ManualReviewPermit: Sendable {
  let id: UUID
  let authority: ManualReviewAuthority
}

/// No automatic work: generate is called only by an explicit, consented action.
/// Cancellation revokes both late output and subsequent Save authority.
public actor ManualReviewSession {
  public typealias Generator = @Sendable (AIConfiguration, String, ManualReviewSnapshot) async throws -> String
  private let store: NotebookStore
  private let generator: Generator
  private let authority = ManualReviewAuthority()
  private var pending: ManualReviewDraft?
  public init(store: NotebookStore, generator: Generator? = nil) {
    self.store = store
    self.generator = generator ?? { config, key, snapshot in
      let prompt = "Create a \(snapshot.period.kind.rawValue) review for \(snapshot.period.title), time zone \(snapshot.period.timeZoneID). Use ONLY the selected quoted sources. Attachments were not sent. Do not claim complete coverage of the day or week. Clearly separate facts, interpretation and missing evidence. Cite source labels S1, S2 and their dates. Return readable Markdown with highlights, open loops and a few reflection questions; omit sections without evidence."
      return try await AIClient().complete(configuration: config, apiKey: key,
        messages: [ChatMessage(role: .user, content: prompt)], context: snapshot.context)
    }
  }

  public nonisolated func cancel() { authority.cancel() }

  public func generate(snapshot: ManualReviewSnapshot, configuration: AIConfiguration,
    apiKey: String, enabled: Bool) async throws -> ManualReviewDraft {
    guard enabled else { throw ManualReviewError.consent }
    try Task.checkCancellation()
    _ = try configuration.endpoint
    _ = try AITransport.key(apiKey, configuration: configuration)
    let identity = UUID()
    authority.begin(identity); pending = nil
    try snapshot.validate(against: await store.entries())
    try Task.checkCancellation()
    try authority.check(identity)
    let body = try await generator(configuration, apiKey, snapshot)
    try Task.checkCancellation()
    try authority.check(identity)
    try snapshot.validate(against: await store.entries())
    try authority.check(identity)
    let draft = ManualReviewDraft(id: identity, created: Date(), snapshot: snapshot, body: body)
    _ = try ManualReviewPage(id: draft.id, created: draft.created, snapshot: snapshot, body: body).encoded()
    pending = draft
    return draft
  }

  public func save(_ draft: ManualReviewDraft, editedBody: String) async throws -> ManualReviewPage {
    try Task.checkCancellation()
    try authority.check(draft.id)
    guard let current = pending, current.id == draft.id,
      current.snapshot.digest == draft.snapshot.digest else { throw ManualReviewError.revoked }
    let page = ManualReviewPage(id: current.id, created: current.created, snapshot: current.snapshot, body: editedBody)
    // The store checks fresh sources synchronously while coordinating their raw
    // files and publishing the independent page. No raw note/draft is mutated.
    try await store.saveManualReview(page, snapshot: current.snapshot,
      permit: ManualReviewPermit(id: current.id, authority: authority))
    return page
  }
}
