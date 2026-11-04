import Foundation

public enum NoteRelationType: String, Codable, CaseIterable, Sendable {
  case related, supplements, contradicts, evolves, duplicate
  case derivedFrom = "derived_from"
}

/// Directed edge with original evidence, not an assertion that a model's reason is true.
public struct NoteRelation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let from: NoteToolSource
  public let to: NoteToolSource
  public let type: NoteRelationType
  public let reason: String
  public let createdAt: Date
  public let fromRevision: String
  public let toRevision: String
  public var isStale: Bool
  public init(id: UUID = UUID(), from: NoteToolSource, to: NoteToolSource,
              type: NoteRelationType, reason: String, createdAt: Date = Date(),
              fromRevision: String, toRevision: String, isStale: Bool = false) {
    self.id = id; self.from = from; self.to = to; self.type = type
    self.reason = reason; self.createdAt = createdAt
    self.fromRevision = fromRevision; self.toRevision = toRevision; self.isStale = isStale
  }
  func sameEdge(as other: Self) -> Bool {
    from.cardRef == other.from.cardRef && to.cardRef == other.to.cardRef && type == other.type
  }
}
