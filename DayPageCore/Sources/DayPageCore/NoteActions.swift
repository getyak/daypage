import CryptoKit
import Foundation

public enum NoteActionKind: String, Codable, Sendable {
  case create, append, patch, setTags, setPin, link, unlink
}

public enum NoteActionStatus: String, Codable, Sendable { case applied, undone }

/// Review data only. Constructing or persisting this value never changes a note.
public struct NoteActionProposal: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: NoteActionKind
  public let createdAt: Date
  public let target: NoteToolSource?
  public let expectedRevision: String?
  public let body: String?
  public let before: String?
  public let after: String?
  public let tags: [String]?
  public let pinned: Bool?
  public let relation: NoteRelation?
  public init(id: UUID = UUID(), kind: NoteActionKind, createdAt: Date = Date(),
              target: NoteToolSource? = nil, expectedRevision: String? = nil,
              body: String? = nil, before: String? = nil, after: String? = nil,
              tags: [String]? = nil, pinned: Bool? = nil, relation: NoteRelation? = nil) {
    self.id = id; self.kind = kind; self.createdAt = createdAt; self.target = target
    self.expectedRevision = expectedRevision; self.body = body; self.before = before
    self.after = after; self.tags = tags; self.pinned = pinned; self.relation = relation
  }
}

public struct NoteActionReceipt: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let proposal: NoteActionProposal
  public let status: NoteActionStatus
  public let savedSource: NoteToolSource?
  public let relation: NoteRelation?
  public let appliedAt: Date
  public init(id: UUID, proposal: NoteActionProposal, status: NoteActionStatus,
              savedSource: NoteToolSource? = nil, relation: NoteRelation? = nil, appliedAt: Date) {
    self.id = id; self.proposal = proposal; self.status = status
    self.savedSource = savedSource; self.relation = relation; self.appliedAt = appliedAt
  }
  func withStatus(_ status: NoteActionStatus) -> Self {
    Self(id: id, proposal: proposal, status: status, savedSource: savedSource,
         relation: relation, appliedAt: appliedAt)
  }
}

public enum NoteActionError: LocalizedError {
  case invalidProposal, outOfScope, corruptMetadata, unsupportedVersion, transactionConflict, limitExceeded
  public var errorDescription: String? {
    switch self {
    case .invalidProposal: return "This proposed change is invalid. Ask for a new proposal."
    case .outOfScope: return "The notes in this proposal are outside the current conversation selection."
    case .corruptMetadata: return "The note action records need attention. Existing files have been preserved."
    case .unsupportedVersion: return "This notebook uses a newer note action format. Existing records have been preserved."
    case .transactionConflict: return "The note changed after this action. Reopen it before saving or undoing."
    case .limitExceeded: return "This operation exceeds the bounded local note action limit."
    }
  }
}

enum NoteActionIdentity {
  static func uniqueRange(of needle: String, in text: String) -> Range<String.Index>? {
    guard !needle.isEmpty, let first = text.range(of: needle) else { return nil }
    let next = text.index(after: first.lowerBound)
    guard text.range(of: needle, range: next..<text.endIndex) == nil else { return nil }
    return first
  }
  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func uuid(_ text: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
      bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}

// One bounded versioned journal. Prepared entries are reconciled against exact raw
// blocks on restart; reconciliation never performs an unconfirmed raw write.
struct NoteActionState: Codable {
  var version = 1
  var origin = UUID()
  var proposals: [NoteActionProposal] = []
  var records: [NoteActionRecord] = []
  var relations: [NoteRelation] = []
  var relationGenerations: [String: Int] = [:]
}

struct NoteActionOrigin: Codable {
  let version: Int
  let origin: UUID
  let established: Bool
}

struct NoteActionRecord: Codable {
  var receipt: NoteActionReceipt
  var committed: Bool
  var undoPrepared: Bool
  var quarantined = false
  let relationGeneration: Int?
  let cardRef: String?
  let beforeBlock: String?
  let afterBlock: String?
  let ownsRelation: Bool
}
