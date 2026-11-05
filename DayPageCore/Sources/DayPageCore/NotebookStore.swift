import Foundation
import Darwin

/// Stable path identity even when Foundation canonicalizes a newly-created
/// /private/tmp or /private/var ancestor differently from its missing children.
/// This is not authorization: callers must separately reject notebook links.
enum NotebookPath {
  static func canonicalPath(_ url: URL) -> String {
    var ancestor = url.standardizedFileURL
    var missing: [String] = []
    while ancestor.path != "/" && !FileManager.default.fileExists(atPath: ancestor.path) {
      missing.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    let existing = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
    guard !missing.isEmpty else { return existing }
    return (existing == "/" ? "" : existing) + "/" + missing.reversed().joined(separator: "/")
  }
}

public struct NotebookEntry: Identifiable, Equatable, Sendable {
  public let memo: Memo
  public let day: String
  public let namespace: String
  fileprivate let originalMarkdown: String?
  fileprivate let originRoot: URL?
  public var id: String { "\(namespace)/\(day)/\(memo.id.uuidString)" }
  /// Hash the exact original Markdown, including unknown YAML and spacing.
  public var revision: String { NoteActionIdentity.digest(originalMarkdown ?? memo.toMarkdown()) }
  public init(memo: Memo, day: String, namespace: String = "") {
    self.memo = memo
    self.day = day
    self.namespace = namespace
    originalMarkdown = nil
    originRoot = nil
  }
  fileprivate init(memo: Memo, day: String, namespace: String, originalMarkdown: String, originRoot: URL) {
    self.memo = memo
    self.day = day
    self.namespace = namespace
    self.originalMarkdown = originalMarkdown
    self.originRoot = originRoot
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.memo == rhs.memo && lhs.day == rhs.day && lhs.namespace == rhs.namespace
  }
}

extension NotebookStore {
  /// Persisting a proposal grants no raw-write authority. The host separately owns
  /// the enabled conversation selection and the person's explicit Save gesture.
  public func saveProposal(_ proposal: NoteActionProposal) throws {
    try validateActionProposal(proposal)
    try withActionState { state, metadata in
      if let old = state.proposals.first(where: { $0.id == proposal.id }) {
        guard old == proposal else { throw NoteActionError.transactionConflict }
        return
      }
      guard state.proposals.count < 1000 else { throw NoteActionError.limitExceeded }
      state.proposals.append(proposal)
      try writeActionState(state, to: metadata)
    }
  }

  public func pendingProposals() throws -> [NoteActionProposal] {
    try withActionState { state, metadata in
      try reconcileActions(&state, metadata: metadata)
      let completed = Set(state.records.filter { $0.committed || $0.quarantined }.map { $0.receipt.id })
      return state.proposals.filter { !completed.contains($0.id) }
    }
  }

  public func actionReceipts() throws -> [NoteActionReceipt] {
    try withActionState { state, metadata in
      try reconcileActions(&state, metadata: metadata)
      return state.records.filter(\.committed).map(\.receipt).sorted {
        $0.appliedAt == $1.appliedAt ? $0.id.uuidString < $1.id.uuidString : $0.appliedAt > $1.appliedAt
      }
    }
  }

  public func relations(allowedCardRefs: Set<String>, allNotes: Bool = false) throws -> [NoteRelation] {
    try toolSnapshot(allowedCardRefs: allowedCardRefs, allNotes: allNotes).relations
  }

  public func toolSnapshot(allowedCardRefs: Set<String>, allNotes: Bool = false) throws -> NoteToolSnapshot {
    try withActionState { state, metadata in
      let fresh = try readEntries(in: root)
      try reconcileActions(&state, metadata: metadata, entries: fresh)
      let byRef = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
      let edges = state.relations.filter {
        allNotes || allowedCardRefs.contains($0.from.cardRef) && allowedCardRefs.contains($0.to.cardRef)
      }.map { edge in
        var result = edge
        result.isStale = byRef[edge.from.cardRef]?.revision != edge.fromRevision
          || byRef[edge.to.cardRef]?.revision != edge.toRevision
        return result
      }
      return NoteToolSnapshot(entries: fresh.filter { allNotes || allowedCardRefs.contains($0.id) }, relations: edges)
    }
  }

  /// Synchronous actor transaction: no suspension between journal preparation,
  /// exact revision validation and raw-file publication. Cross-instance writers
  /// also coordinate the metadata lock and affected raw file.
  public func apply(_ proposal: NoteActionProposal, allowedCardRefs: Set<String>, authorization: NoteActionAuthorization? = nil) throws -> NoteActionReceipt {
    try ConversationActionGate.withAuthorization(authorization, root: root, proposal: proposal, allowedCardRefs: allowedCardRefs) {
      try applyAction(proposal, allowedCardRefs: allowedCardRefs)
    }
  }

  private func applyAction(_ proposal: NoteActionProposal, allowedCardRefs: Set<String>) throws -> NoteActionReceipt {
    try validateActionProposal(proposal)
    try requireActionScope(proposal, allowed: allowedCardRefs)
    return try withActionState { state, metadata in
      try reconcileActions(&state, metadata: metadata)
      guard !state.records.contains(where: { $0.receipt.id == proposal.id && $0.quarantined }) else { throw NoteActionError.transactionConflict }
      if let record = state.records.first(where: { $0.receipt.id == proposal.id && $0.committed }) {
        guard record.receipt.proposal == proposal else { throw NoteActionError.transactionConflict }
        return record.receipt
      }
      guard state.proposals.first(where: { $0.id == proposal.id }) == proposal else { throw NoteActionError.transactionConflict }
      guard state.records.count < 1000 else { throw NoteActionError.limitExceeded }
      if proposal.kind == .link || proposal.kind == .unlink {
        return try applyRelation(proposal, state: &state, metadata: metadata)
      }
      let ref: String
      if proposal.kind == .create {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        ref = "/\(formatter.string(from: proposal.createdAt))/\(proposal.id.uuidString)"
      } else {
        guard let target = proposal.target else { throw NoteActionError.invalidProposal }
        ref = target.cardRef
      }
      let url = try actionURL(cardRef: ref)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var receipt: NoteActionReceipt?
      try coordinatedWrite(at: url) { coordinated in
        var document = try self.actionDocument(at: coordinated)
        let index = try self.actionIndex(cardRef: ref, document: document)
        let before = index.map { document.blocks[$0] }
        let after: String
        if proposal.kind == .create {
          guard before == nil, let body = proposal.body else { throw NoteActionError.transactionConflict }
          after = Memo(id: proposal.id, created: proposal.createdAt, body: body).toMarkdown()
        } else {
          guard let before, NoteActionIdentity.digest(before) == proposal.expectedRevision,
            let memo = Memo.fromMarkdown(before), memo.body.hasPrefix(proposal.target?.snippet ?? "") else { throw NoteActionError.transactionConflict }
          after = try self.actionEditedBlock(before, memo: memo, proposal: proposal)
        }
        guard let memo = Memo.fromMarkdown(after), let day = self.actionDay(cardRef: ref) else { throw NoteActionError.invalidProposal }
        let saved = NoteToolSource(cardRef: ref, day: day, snippet: memo.body)
        let applied = NoteActionReceipt(id: proposal.id, proposal: proposal, status: .applied,
          savedSource: saved, appliedAt: Date())
        let record = NoteActionRecord(receipt: applied, committed: false, undoPrepared: false,
          relationGeneration: nil, cardRef: ref, beforeBlock: before, afterBlock: after, ownsRelation: false)
        if let index { document.blocks[index] = after } else { document.blocks.append(after) }
        try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
        guard document.content.utf8.count <= 4 * 1024 * 1024 else { throw NoteActionError.limitExceeded }
        state.records.removeAll { $0.receipt.id == proposal.id && !$0.committed }
        state.records.append(record)
        // Journal goes first. Restart will only read/compare these bytes, never
        // publish the prepared after-block without a fresh confirmed apply call.
        try self.writeActionState(state, to: metadata)
        try self.validateContained(coordinated)
        try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
        state.records[state.records.count - 1].committed = true
        // If finalization fails, retain the prepared journal and return an error.
        // A retry/reopen reconciles the already-written exact after-block once.
        try self.writeActionState(state, to: metadata)
        receipt = applied
      }
      guard let receipt else { throw NoteActionError.transactionConflict }
      return receipt
    }
  }

  public func undo(_ receipt: NoteActionReceipt, allowedCardRefs: Set<String>, authorization: NoteActionAuthorization? = nil) throws -> NoteActionReceipt {
    try ConversationActionGate.withAuthorization(authorization, root: root, proposal: receipt.proposal, allowedCardRefs: allowedCardRefs) {
      try undoAction(receipt, allowedCardRefs: allowedCardRefs)
    }
  }

  private func undoAction(_ receipt: NoteActionReceipt, allowedCardRefs: Set<String>) throws -> NoteActionReceipt {
    try validateActionProposal(receipt.proposal)
    // A persisted receipt authorizes undo of its own newly-created note, even
    // when that note was not silently added to a selected-note conversation.
    try requireActionScope(receipt.proposal, allowed: allowedCardRefs)
    return try withActionState { state, metadata in
      try reconcileActions(&state, metadata: metadata)
      guard let index = state.records.firstIndex(where: { $0.receipt.id == receipt.id && $0.committed }),
        state.records[index].receipt.proposal == receipt.proposal,
        state.records[index].receipt.appliedAt == receipt.appliedAt else { throw NoteActionError.transactionConflict }
      var record = state.records[index]
      guard !record.quarantined else { throw NoteActionError.transactionConflict }
      if record.receipt.status == .undone { return record.receipt }
      if let edge = record.receipt.relation {
        let key = actionRelationKey(edge)
        if record.ownsRelation {
          guard state.relationGenerations[key] == record.relationGeneration else { throw NoteActionError.transactionConflict }
        }
        if record.receipt.proposal.kind == .link {
          if record.ownsRelation {
            guard state.relations.contains(edge) else { throw NoteActionError.transactionConflict }
            // A later confirmed action may now depend on this same edge.
            guard !state.records.contains(where: {
              $0.committed && $0.receipt.status == .applied && $0.receipt.id != receipt.id
                && $0.receipt.appliedAt > receipt.appliedAt && $0.receipt.relation?.id == edge.id
            }) else { throw NoteActionError.transactionConflict }
            state.relations.removeAll { $0.id == edge.id }
          }
        } else {
          guard !state.relations.contains(where: { $0.id == edge.id || $0.sameEdge(as: edge) }) else {
            throw NoteActionError.transactionConflict
          }
          state.relations.append(edge)
        }
        if record.ownsRelation { _ = try nextRelationGeneration(key, state: &state) }
        record.receipt = record.receipt.withStatus(.undone)
        state.records[index] = record
        try writeActionState(state, to: metadata)
        return record.receipt
      }
      guard let ref = record.cardRef else { throw NoteActionError.corruptMetadata }
      var result: NoteActionReceipt?
      try coordinatedWrite(at: actionURL(cardRef: ref)) { coordinated in
        var document = try self.actionDocument(at: coordinated)
        guard let targetIndex = try self.actionIndex(cardRef: ref, document: document),
          document.blocks[targetIndex].utf8.elementsEqual((record.afterBlock ?? "").utf8) else {
          throw NoteActionError.transactionConflict
        }
        if let before = record.beforeBlock { document.blocks[targetIndex] = before }
        else { document.blocks.remove(at: targetIndex) }
        try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
        guard document.content.utf8.count <= 4 * 1024 * 1024 else { throw NoteActionError.limitExceeded }
        record.undoPrepared = true; state.records[index] = record
        try self.writeActionState(state, to: metadata)
        try self.validateContained(coordinated)
        try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
        record.receipt = record.receipt.withStatus(.undone); record.undoPrepared = false
        state.records[index] = record
        try self.writeActionState(state, to: metadata)
        result = record.receipt
      }
      guard let result else { throw NoteActionError.transactionConflict }
      return result
    }
  }

  private func withActionState<T>(_ operation: (inout NoteActionState, URL) throws -> T) throws -> T {
    let directory = root.appendingPathComponent(".daypage")
    let metadata = directory.appendingPathComponent("note-actions.json")
    try validateContained(metadata)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    var result: T?
    try coordinatedWrite(at: metadata) { coordinated in
      var state = try self.readActionState(at: coordinated)
      result = try operation(&state, coordinated)
    }
    guard let result else { throw NoteActionError.corruptMetadata }
    return result
  }

  private func readActionState(at url: URL) throws -> NoteActionState {
    try validateContained(url)
    let originURL = url.deletingLastPathComponent().appendingPathComponent("note-actions-origin.json")
    try validateContained(originURL)
    let hasJournal = fm.fileExists(atPath: url.path), hasOrigin = fm.fileExists(atPath: originURL.path)
    if !hasJournal && !hasOrigin { return NoteActionState() }
    guard hasOrigin else { throw NoteActionError.corruptMetadata }
    let origin = try readActionOrigin(at: originURL)
    if !hasJournal {
      guard !origin.established else { throw NoteActionError.corruptMetadata }
      return NoteActionState(origin: origin.origin)
    }
    let data = try boundedActionData(at: url, maximum: 32 * 1024 * 1024)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["version"] as? Int else { throw NoteActionError.corruptMetadata }
    guard version == 1 else { throw NoteActionError.unsupportedVersion }
    try validateActionMetadataShape(object)
    guard let state = try? JSONDecoder().decode(NoteActionState.self, from: data), state.origin == origin.origin,
      state.proposals.count <= 1000, state.records.count <= 1000, state.relations.count <= 1000, state.relationGenerations.count <= 1000,
      Set(state.proposals.map(\.id)).count == state.proposals.count,
      Set(state.records.map { $0.receipt.id }).count == state.records.count,
      Set(state.relations.map(\.id)).count == state.relations.count else { throw NoteActionError.corruptMetadata }
    for proposal in state.proposals { try validateActionProposal(proposal) }
    for record in state.records {
      try validateActionProposal(record.receipt.proposal)
      guard record.receipt.id == record.receipt.proposal.id,
        state.proposals.contains(record.receipt.proposal),
        record.receipt.appliedAt.timeIntervalSince1970.isFinite,
        record.receipt.status != .undone || record.committed && !record.undoPrepared else { throw NoteActionError.corruptMetadata }
      let relationAction = record.receipt.proposal.kind == .link || record.receipt.proposal.kind == .unlink
      guard relationAction == (record.cardRef == nil), relationAction == (record.receipt.relation != nil) else { throw NoteActionError.corruptMetadata }
      if let edge = record.receipt.relation {
        try validateActionRelation(edge)
        guard let proposed = record.receipt.proposal.relation, edge.sameEdge(as: proposed),
          record.committed, !record.undoPrepared, record.beforeBlock == nil, record.afterBlock == nil,
          record.receipt.savedSource == nil, let generation = record.relationGeneration, generation > 0,
          state.relationGenerations[actionRelationKey(edge)].map({ $0 >= generation }) == true else { throw NoteActionError.corruptMetadata }
      }
      if let ref = record.cardRef {
        guard record.relationGeneration == nil else { throw NoteActionError.corruptMetadata }
        _ = try actionURL(cardRef: ref)
        guard let after = record.afterBlock, after.utf8.count <= 4 * 1024 * 1024,
          let afterMemo = Memo.fromMarkdown(after), ref.hasSuffix("/" + afterMemo.id.uuidString),
          record.receipt.savedSource?.cardRef == ref,
          record.receipt.savedSource?.day == actionDay(cardRef: ref),
          record.receipt.savedSource?.snippet == String(afterMemo.body.prefix(360)),
          record.beforeBlock.map({ $0.utf8.count <= 4 * 1024 * 1024 && Memo.fromMarkdown($0)?.id == afterMemo.id }) ?? true,
          record.receipt.proposal.kind == .create ? record.receipt.proposal.id == afterMemo.id && record.beforeBlock == nil : record.receipt.proposal.target?.cardRef == ref
        else { throw NoteActionError.corruptMetadata }
        if let before = record.beforeBlock {
          guard NoteActionIdentity.digest(before) == record.receipt.proposal.expectedRevision,
            let memo = Memo.fromMarkdown(before),
            try actionEditedBlock(before, memo: memo, proposal: record.receipt.proposal).utf8.elementsEqual(after.utf8)
          else { throw NoteActionError.corruptMetadata }
        } else {
          guard record.receipt.proposal.kind == .create, let body = record.receipt.proposal.body,
            Memo(id: afterMemo.id, created: record.receipt.proposal.createdAt, body: body).toMarkdown().utf8.elementsEqual(after.utf8)
          else { throw NoteActionError.corruptMetadata }
        }
      }
    }
    for relation in state.relations {
      try validateActionRelation(relation)
      guard state.relationGenerations[actionRelationKey(relation)].map({ $0 > 0 }) == true else { throw NoteActionError.corruptMetadata }
    }
    for (key, generation) in state.relationGenerations {
      let fields = key.components(separatedBy: "\n")
      guard generation > 0, fields.count == 3, NoteRelationType(rawValue: fields[2]) != nil else { throw NoteActionError.corruptMetadata }
      _ = try actionURL(cardRef: fields[0]); _ = try actionURL(cardRef: fields[1])
    }
    let edgeKeys = state.relations.map { $0.from.cardRef + "\n" + $0.to.cardRef + "\n" + $0.type.rawValue }
    guard Set(edgeKeys).count == edgeKeys.count else { throw NoteActionError.corruptMetadata }
    if !origin.established {
      guard state.records.isEmpty, state.relations.isEmpty, state.relationGenerations.isEmpty else { throw NoteActionError.corruptMetadata }
      // Initial proposal-only publication finished; finalize its provenance
      // before allowing saveProposal to return or any apply to proceed.
      try writeActionOrigin(NoteActionOrigin(version: 1, origin: state.origin, established: true), to: originURL)
    }
    return state
  }

  /// Unknown fields cannot be silently discarded by Codable on the next save.
  /// A future format must increment its version or explicitly preserve extensions.
  private func validateActionMetadataShape(_ object: [String: Any]) throws {
    func keys(_ value: Any, _ allowed: Set<String>) throws -> [String: Any] {
      guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw NoteActionError.corruptMetadata }
      return object
    }
    func source(_ value: Any?) throws {
      if let value, !(value is NSNull) { _ = try keys(value, ["cardRef", "day", "snippet"]) }
    }
    func relation(_ value: Any?) throws {
      if let value, !(value is NSNull) {
        let edge = try keys(value, ["id", "from", "to", "type", "reason", "createdAt", "fromRevision", "toRevision", "isStale"])
        try source(edge["from"]); try source(edge["to"])
      }
    }
    func proposal(_ value: Any) throws {
      let item = try keys(value, ["id", "kind", "createdAt", "target", "expectedRevision", "body", "before", "after", "tags", "pinned", "relation"])
      try source(item["target"]); try relation(item["relation"])
    }
    _ = try keys(object, ["version", "origin", "proposals", "records", "relations", "relationGenerations"])
    for value in object["proposals"] as? [Any] ?? [] { try proposal(value) }
    for value in object["relations"] as? [Any] ?? [] { try relation(value) }
    for value in object["records"] as? [Any] ?? [] {
      let record = try keys(value, ["receipt", "committed", "undoPrepared", "quarantined", "relationGeneration", "cardRef", "beforeBlock", "afterBlock", "ownsRelation"])
      guard let receiptValue = record["receipt"] else { throw NoteActionError.corruptMetadata }
      let receipt = try keys(receiptValue, ["id", "proposal", "status", "savedSource", "relation", "appliedAt"])
      guard let proposalValue = receipt["proposal"] else { throw NoteActionError.corruptMetadata }
      try proposal(proposalValue); try source(receipt["savedSource"]); try relation(receipt["relation"])
    }
  }

  private func writeActionState(_ state: NoteActionState, to url: URL) throws {
    try validateContained(url)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 32 * 1024 * 1024 else { throw NoteActionError.limitExceeded }
    let originURL = url.deletingLastPathComponent().appendingPathComponent("note-actions-origin.json")
    try validateContained(originURL)
    let established: Bool
    if fm.fileExists(atPath: originURL.path) {
      let marker = try readActionOrigin(at: originURL)
      guard marker.origin == state.origin, !marker.established || fm.fileExists(atPath: url.path) else { throw NoteActionError.corruptMetadata }
      established = marker.established
    } else {
      guard !fm.fileExists(atPath: url.path) else { throw NoteActionError.corruptMetadata }
      established = false
      try encoder.encode(NoteActionOrigin(version: 1, origin: state.origin, established: false)).write(to: originURL, options: .withoutOverwriting)
    }
    if !established {
      guard state.records.isEmpty, state.relations.isEmpty, state.relationGenerations.isEmpty else { throw NoteActionError.corruptMetadata }
    }
    try validateContained(url)
    try data.write(to: url, options: .atomic)
    if !established { try writeActionOrigin(NoteActionOrigin(version: 1, origin: state.origin, established: true), to: originURL) }
  }

  private func readActionOrigin(at url: URL) throws -> NoteActionOrigin {
    let data = try boundedActionData(at: url, maximum: 1024)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["version", "origin", "established"],
      let origin = try? JSONDecoder().decode(NoteActionOrigin.self, from: data), origin.version == 1 else { throw NoteActionError.corruptMetadata }
    return origin
  }

  private func writeActionOrigin(_ origin: NoteActionOrigin, to url: URL) throws {
    try validateContained(url)
    try JSONEncoder().encode(origin).write(to: url, options: .atomic)
  }

  private func boundedActionData(at url: URL, maximum: Int) throws -> Data {
    try validateContained(url)
    let attrs = try fm.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
      let size = attrs[.size] as? NSNumber, size.int64Value <= maximum else { throw NoteActionError.limitExceeded }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let data = try handle.read(upToCount: maximum + 1) ?? Data()
    guard data.count <= maximum else { throw NoteActionError.limitExceeded }
    return data
  }

  private func actionDocument(at url: URL) throws -> DayDocument {
    try validateContained(url)
    guard fm.fileExists(atPath: url.path) else { return DayDocument("") }
    let data = try boundedActionData(at: url, maximum: 4 * 1024 * 1024)
    guard let text = String(data: data, encoding: .utf8) else { throw NotebookError.unreadableFile }
    let document = DayDocument(text)
    guard document.valid else { throw NotebookError.ambiguousRecord }
    return document
  }

  private func actionDay(cardRef: String) -> String? {
    let parts = cardRef.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }
    return String(parts[parts.count - 2])
  }

  private func actionURL(cardRef: String) throws -> URL {
    let parts = cardRef.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 3, let last = parts.last, UUID(uuidString: String(last)) != nil,
      let day = actionDay(cardRef: cardRef), Self.validDay(day) else { throw NotebookError.invalidPath }
    let namespace = parts.dropLast(2).joined(separator: "/")
    // Local refs have exactly one empty leading namespace; imported refs are
    // slash-separated UUIDs. Empty intermediate components are rejected.
    guard namespace.isEmpty ? parts.count == 3 && parts[0].isEmpty : !parts[0].isEmpty else { throw NotebookError.invalidPath }
    let url = try vaultURL(namespace: namespace).appendingPathComponent("raw/\(day).md")
    try validateContained(url)
    return url
  }

  private func actionIndex(cardRef: String, document: DayDocument) throws -> Int? {
    guard let idText = cardRef.split(separator: "/").last, let id = UUID(uuidString: String(idText)) else { throw NotebookError.invalidPath }
    let matches = document.blocks.indices.filter { Memo.fromMarkdown(document.blocks[$0])?.id == id }
    guard matches.count <= 1 else { throw NotebookError.ambiguousRecord }
    return matches.first
  }

  private func requireActionScope(_ proposal: NoteActionProposal, allowed: Set<String>) throws {
    if let target = proposal.target, !allowed.contains(target.cardRef) { throw NoteActionError.outOfScope }
    if let relation = proposal.relation,
      !allowed.contains(relation.from.cardRef) || !allowed.contains(relation.to.cardRef) { throw NoteActionError.outOfScope }
  }

  private func validateActionRelation(_ edge: NoteRelation) throws {
    _ = try actionURL(cardRef: edge.from.cardRef); _ = try actionURL(cardRef: edge.to.cardRef)
    guard edge.from.cardRef != edge.to.cardRef, edge.reason.count <= 1000,
      edge.createdAt.timeIntervalSince1970.isFinite,
      !edge.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      edge.from.snippet.count <= 360, edge.to.snippet.count <= 360,
      edge.from.day == actionDay(cardRef: edge.from.cardRef), edge.to.day == actionDay(cardRef: edge.to.cardRef),
      edge.fromRevision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
      edge.toRevision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw NoteActionError.invalidProposal }
  }

  private func validateActionProposal(_ proposal: NoteActionProposal) throws {
    guard proposal.createdAt.timeIntervalSince1970.isFinite else { throw NoteActionError.invalidProposal }
    if let target = proposal.target {
      _ = try actionURL(cardRef: target.cardRef)
      guard target.day == actionDay(cardRef: target.cardRef), target.snippet.count <= 360,
        proposal.expectedRevision?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw NoteActionError.invalidProposal }
    }
    for text in [proposal.body, proposal.before, proposal.after].compactMap({ $0 }) {
      guard text.count <= 6000, !text.contains(DayDocument.modern) else { throw NoteActionError.invalidProposal }
    }
    func nonempty(_ text: String?) -> Bool { text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
    if proposal.kind != .create && proposal.kind != .append, proposal.body != nil { throw NoteActionError.invalidProposal }
    if proposal.kind != .patch, proposal.before != nil || proposal.after != nil { throw NoteActionError.invalidProposal }
    if proposal.kind != .setTags, proposal.tags != nil { throw NoteActionError.invalidProposal }
    if proposal.kind != .setPin, proposal.pinned != nil { throw NoteActionError.invalidProposal }
    if proposal.target == nil, proposal.expectedRevision != nil { throw NoteActionError.invalidProposal }
    switch proposal.kind {
    case .create:
      guard proposal.target == nil, nonempty(proposal.body), proposal.relation == nil else { throw NoteActionError.invalidProposal }
    case .append:
      guard proposal.target != nil, nonempty(proposal.body), proposal.relation == nil else { throw NoteActionError.invalidProposal }
    case .patch:
      guard proposal.target != nil, nonempty(proposal.before), proposal.after != nil, proposal.relation == nil else { throw NoteActionError.invalidProposal }
    case .setTags:
      guard proposal.target != nil, let tags = proposal.tags, tags.count <= 20,
        Set(tags).count == tags.count, tags.allSatisfy({ $0.range(of: #"^[\p{L}\p{N}_-]{1,64}$"#, options: .regularExpression) != nil }),
        proposal.relation == nil else { throw NoteActionError.invalidProposal }
    case .setPin:
      guard proposal.target != nil, proposal.pinned != nil, proposal.relation == nil else { throw NoteActionError.invalidProposal }
    case .link, .unlink:
      guard proposal.target == nil, let relation = proposal.relation else { throw NoteActionError.invalidProposal }
      try validateActionRelation(relation)
    }
  }

  private func actionEditedBlock(_ block: String, memo: Memo, proposal: NoteActionProposal) throws -> String {
    let header = try frontmatterRange(in: block)
    if proposal.kind == .setPin {
      if (memo.pinnedAt != nil) == proposal.pinned { return block }
      var lines = String(block[header]).components(separatedBy: "\n")
      let pins = lines.indices.filter { lines[$0].hasPrefix("pinned_at:") }
      guard pins.count <= 1 else { throw NotebookError.ambiguousRecord }
      if let pin = pins.first { lines.remove(at: pin) }
      if proposal.pinned == true { lines.insert("pinned_at: " + ISO8601DateFormatter.memo.string(from: proposal.createdAt), at: 0) }
      return String(block[..<header.lowerBound]) + lines.joined(separator: "\n") + String(block[header.upperBound...])
    }
    // Work from raw body bytes rather than the parser's trimmed presentation.
    // Appending must retain the user's existing trailing whitespace/newlines.
    let closingLineEnd = block[header.upperBound...].firstIndex(of: "\n") ?? block.endIndex
    var bodyStart = closingLineEnd
    if bodyStart < block.endIndex { bodyStart = block.index(after: bodyStart) }
    if bodyStart < block.endIndex, block[bodyStart] == "\n" { bodyStart = block.index(after: bodyStart) }
    var body = String(block[bodyStart...])
    switch proposal.kind {
    case .append:
      guard let text = proposal.body else { throw NoteActionError.invalidProposal }
      body += (body.isEmpty ? "" : "\n\n") + text
    case .patch:
      guard let before = proposal.before, let after = proposal.after,
        let range = NoteActionIdentity.uniqueRange(of: before, in: body) else { throw NoteActionError.invalidProposal }
      body.replaceSubrange(range, with: after)
    case .setTags:
      let regex = try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_-]+)"#)
      body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
      let tags = (proposal.tags ?? []).map { "#" + $0 }.joined(separator: " ")
      if !tags.isEmpty { body += (body.isEmpty ? "" : "\n\n") + tags }
    default: throw NoteActionError.invalidProposal
    }
    guard !body.contains(DayDocument.modern), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !memo.attachments.isEmpty else { throw NotebookError.emptyNote }
    // Replace only the body. Preserve all header bytes, including unknown YAML.
    var prefix = String(block[..<bodyStart])
    if bodyStart == block.endIndex {
      if !prefix.hasSuffix("\n") { prefix += "\n\n" }
      else if !prefix.hasSuffix("\n\n") { prefix += "\n" }
    }
    return prefix + body
  }

  private func applyRelation(_ proposal: NoteActionProposal, state: inout NoteActionState, metadata: URL) throws -> NoteActionReceipt {
    guard let proposed = proposal.relation else { throw NoteActionError.invalidProposal }
    // Lock both endpoint day files in stable path order until the metadata commit.
    let urls = proposal.kind == .link ? try Array(Set([actionURL(cardRef: proposed.from.cardRef), actionURL(cardRef: proposed.to.cardRef)])).sorted { $0.path < $1.path } : []
    var result: NoteActionReceipt?
    try withActionEndpointLocks(urls) {
      if proposal.kind == .link {
        let fresh = try self.readEntries(in: self.root)
        guard let from = fresh.first(where: { $0.id == proposed.from.cardRef }), let to = fresh.first(where: { $0.id == proposed.to.cardRef }),
          from.revision == proposed.fromRevision, to.revision == proposed.toRevision,
          from.memo.body.hasPrefix(proposed.from.snippet), to.memo.body.hasPrefix(proposed.to.snippet) else { throw NoteActionError.transactionConflict }
      }
    let edge: NoteRelation
    let owns: Bool
    if proposal.kind == .link {
      if let existing = state.relations.first(where: { $0.sameEdge(as: proposed) }) { edge = existing; owns = false }
      else {
        guard state.relations.count < 1000, !state.relations.contains(where: { $0.id == proposed.id }) else { throw NoteActionError.limitExceeded }
        edge = proposed; owns = true; state.relations.append(proposed)
      }
    } else {
      guard let existing = state.relations.first(where: { $0.id == proposed.id }), existing == proposed else {
        throw NoteActionError.transactionConflict
      }
      edge = existing; owns = true; state.relations.removeAll { $0.id == proposed.id }
    }
    let receipt = NoteActionReceipt(id: proposal.id, proposal: proposal, status: .applied, relation: edge, appliedAt: Date())
    let key = self.actionRelationKey(edge)
    let generation: Int
    if owns { generation = try self.nextRelationGeneration(key, state: &state) }
    else {
      guard let current = state.relationGenerations[key] else { throw NoteActionError.corruptMetadata }
      generation = current
    }
    state.records.removeAll { $0.receipt.id == proposal.id && !$0.committed }
    state.records.append(NoteActionRecord(receipt: receipt, committed: true, undoPrepared: false,
      relationGeneration: generation, cardRef: nil, beforeBlock: nil, afterBlock: nil, ownsRelation: owns))
      try self.writeActionState(state, to: metadata)
      result = receipt
    }
    guard let result else { throw NoteActionError.transactionConflict }
    return result
  }

  private func withActionEndpointLocks(_ urls: [URL], operation: () throws -> Void) throws {
    guard let first = urls.first else { return try operation() }
    try coordinatedWrite(at: first) { _ in
      try self.withActionEndpointLocks(Array(urls.dropFirst()), operation: operation)
    }
  }

  private func reconcileActions(_ state: inout NoteActionState, metadata: URL, entries: [NotebookEntry]? = nil) throws {
    var changed = false
    let pending = state.records.indices.filter { !state.records[$0].quarantined && (!state.records[$0].committed || state.records[$0].undoPrepared) }
    guard !pending.isEmpty else { return }
    let fresh = try entries ?? readEntries(in: root)
    let byRef = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
    for index in pending {
      let record = state.records[index]
      guard let ref = record.cardRef else { throw NoteActionError.corruptMetadata }
      let block = byRef[ref]?.originalMarkdown
      func same(_ a: String?, _ b: String?) -> Bool {
        if let a, let b { return a.utf8.elementsEqual(b.utf8) }; return a == nil && b == nil
      }
      if record.undoPrepared {
        if same(block, record.beforeBlock) {
          state.records[index].receipt = record.receipt.withStatus(.undone)
          state.records[index].undoPrepared = false; changed = true
        } else if !same(block, record.afterBlock) {
          state.records[index].quarantined = true; changed = true
        }
      } else if same(block, record.afterBlock) {
        state.records[index].committed = true; changed = true
      } else if !same(block, record.beforeBlock) {
        state.records[index].quarantined = true; changed = true
      }
      // Equal before-block means publication did not happen. Keep the pending
      // evidence; only a new explicit apply may attempt the write.
    }
    if changed { try writeActionState(state, to: metadata) }
  }

  private func actionRelationKey(_ edge: NoteRelation) -> String {
    edge.from.cardRef + "\n" + edge.to.cardRef + "\n" + edge.type.rawValue
  }

  private func nextRelationGeneration(_ key: String, state: inout NoteActionState) throws -> Int {
    let old = state.relationGenerations[key, default: 0]
    guard old < Int.max, old > 0 || state.relationGenerations.count < 1000 else { throw NoteActionError.limitExceeded }
    state.relationGenerations[key] = old + 1
    return old + 1
  }
}

public struct NotebookAssetInput: Sendable {
  public let data: Data
  public let fileExtension: String
  public let kind: String
  public let duration: Double?

  public init(data: Data, fileExtension: String, kind: String, duration: Double? = nil) {
    self.data = data
    self.fileExtension = fileExtension
    self.kind = kind
    self.duration = duration
  }
}

public struct NotebookTrashReceipt: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let entry: NotebookEntry
  fileprivate let origin: UUID
  fileprivate let originRoot: URL
}

private struct TrashManifest: Codable {
  let version: Int
  let origin: UUID
  let namespace: String
  let day: String
  let memoID: UUID
  let index: Int
  let created: Date
}

private struct TrashRecord {
  let manifest: TrashManifest
  let original: DayDocument
  let receipt: NotebookTrashReceipt
}

public enum NotebookError: LocalizedError {
  case invalidPath, emptyNote, conflict, ambiguousRecord, invalidVault, unreadableFile,
    reservedSeparator, invalidAsset
  public var errorDescription: String? {
    switch self {
    case .invalidPath: return "The file path is not inside this notebook."
    case .emptyNote: return "Write something before saving."
    case .conflict: return "This note changed elsewhere. Reopen it before editing."
    case .ambiguousRecord:
      return "This file needs attention. Its original content has been preserved."
    case .invalidVault:
      return
        "Choose a downloaded Vault folder containing a raw folder. Linked files cannot be imported."
    case .unreadableFile:
      return "Some records could not be read. Their original files have not been changed."
    case .reservedSeparator:
      return
        "This text contains a reserved record separator. Remove that separator before saving; your draft has been kept."
    case .invalidAsset:
      return "Use up to 10 nonempty attachments, each no larger than 25 MB, with a valid file type."
    }
  }
}

/// Keeps the original record blocks, including unknown YAML and spacing.
private struct DayDocument {
  static let modern = "\n\n<!-- daypage-memo-separator -->\n\n"
  static let legacy = "\n\n---\n\n"
  var blocks: [String]
  let separator: String
  init(_ content: String) {
    if content.contains(Self.modern) {
      blocks = content.components(separatedBy: Self.modern)
      separator = Self.modern
    } else if content.contains(Self.legacy) {
      let candidates = content.components(separatedBy: Self.legacy)
      let nonempty = candidates.filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if !nonempty.isEmpty && nonempty.allSatisfy({ Memo.fromMarkdown($0) != nil }) {
        blocks = candidates
        separator = Self.legacy
      } else {
        blocks = content.isEmpty ? [] : [content]
        separator = Self.modern
      }
    } else {
      blocks = content.isEmpty ? [] : [content]
      separator = Self.modern
    }
  }
  var content: String { blocks.joined(separator: separator) }
  var valid: Bool {
    blocks.allSatisfy {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Memo.fromMarkdown($0) != nil
    }
  }
}

public actor NotebookStore {
  public let root: URL
  private let fm = FileManager.default
  public init(root: URL) { self.root = root.standardizedFileURL }

  public func entries() throws -> [NotebookEntry] {
    try readEntries(in: root)
  }

  /// Byte-preserving export for personal replication; rejects identities ambiguous across days.
  public func replicaRecords() throws -> [ReplicaRecord] {
    let entries = try readEntries(in: root)
    try ReplicaNamespace.validateAliases(entries.map(\.namespace))
    let identities = entries.map { $0.namespace + "/" + $0.memo.id.uuidString }
    guard Set(identities).count == identities.count else { throw ReplicaError.invalidData }
    return try entries.map { entry in
      var assets: [String: Data] = [:]
      for attachment in entry.memo.attachments {
        let url = try assetURL(attachment.file, for: entry)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 25 * 1024 * 1024 else { throw ReplicaError.invalidData }
        assets[attachment.file] = try Data(contentsOf: url, options: .mappedIfSafe)
      }
      return ReplicaRecord(namespace: entry.namespace, day: entry.day,
        markdown: entry.originalMarkdown ?? entry.memo.toMarkdown(), assets: assets)
    }
  }

  /// Compare-and-swap integration. Called only after every needed object is downloaded/verified.
  public func applyReplica(_ replacement: ReplicaRecord?, identity: String, expected: String?,
    validateSession: @Sendable () throws -> Void = {}) throws {
    try validateSession(); try Task.checkCancellation()
    let currentRecords = try replicaRecords()
    try ReplicaNamespace.validateAliases(currentRecords.map(\.namespace) + [try VaultRevision.namespace(for: identity)])
    let existing = currentRecords.first { $0.identity == identity }
    if try existing?.fingerprint != expected { throw ReplicaError.changed }
    if replacement == nil {
      if let entry = try readEntries(in: root).first(where: { $0.namespace + "/" + $0.memo.id.uuidString == identity }) {
        _ = try trash(entry, validateSession: validateSession)
      }
      return
    }
    guard let record = replacement, record.identity == identity,
      let memo = Memo.fromMarkdown(record.markdown), Self.validDay(record.day),
      !record.markdown.contains(DayDocument.modern),
      existing == nil || existing?.day == record.day,
      Set(memo.attachments.map(\.file)) == Set(record.assets.keys) else { throw ReplicaError.invalidData }
    let base = try vaultURL(namespace: record.namespace)
    let url = base.appendingPathComponent("raw/" + record.day + ".md")
    try validateContained(url)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try coordinatedWrite(at: url) { coordinated in
      try validateSession(); try Task.checkCancellation()
      _ = try self.vaultURL(namespace: record.namespace)
      // Other NotebookStore instances can write while this actor is awaiting coordination.
      let currentRecords = try self.replicaRecords()
      try ReplicaNamespace.validateAliases(currentRecords.map(\.namespace) + [record.namespace])
      guard try currentRecords.first(where: { $0.identity == identity })?.fingerprint == expected
      else { throw ReplicaError.changed }
      var document = DayDocument(self.fm.fileExists(atPath: coordinated.path)
        ? try String(contentsOf: coordinated, encoding: .utf8) : "")
      guard document.valid else { throw ReplicaError.invalidData }
      for (path, data) in record.assets {
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw ReplicaError.invalidData }
        let asset = try self.assetURL(path, for: .init(memo: memo, day: record.day, namespace: record.namespace))
        try self.fm.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fm.fileExists(atPath: asset.path) {
          guard try Data(contentsOf: asset) == data else { throw ReplicaError.invalidData }
        } else { try data.write(to: asset, options: .atomic) }
      }
      let matches = document.blocks.indices.filter { Memo.fromMarkdown(document.blocks[$0])?.id == memo.id }
      if let index = matches.first {
        guard matches.count == 1, expected != nil else { throw ReplicaError.changed }
        document.blocks[index] = record.markdown
      } else { document.blocks.append(record.markdown) }
      try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      try validateSession(); try Task.checkCancellation()
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
    }
  }

  public func wasReplicaTrashed(_ record: ReplicaRecord) throws -> Bool {
    try trashReceipts().contains {
      $0.entry.namespace == record.namespace && $0.entry.memo.id == record.memoID
        && $0.entry.day == record.day && $0.entry.originalMarkdown == record.markdown
    }
  }

  private func readEntries(in searchRoot: URL) throws -> [NotebookEntry] {
    var locations: [(URL, String)] = [(searchRoot, "")]
    var result: [NotebookEntry] = []
    var cursor = 0
    while cursor < locations.count {
      guard locations.count <= 1000 else { throw NotebookError.invalidVault }
      let (vault, namespace) = locations[cursor]
      cursor += 1
      let imports = vault.appendingPathComponent("imports")
      if fm.fileExists(atPath: imports.path) {
        try validateContained(imports, within: searchRoot)
        for folder in try fm.contentsOfDirectory(
          at: imports, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        where UUID(uuidString: folder.lastPathComponent) != nil {
          let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isSymbolicLink != true, values.isDirectory == true,
            namespace.split(separator: "/").count < 16
          else { throw NotebookError.invalidVault }
          locations.append(
            (
              folder,
              namespace.isEmpty
                ? folder.lastPathComponent : namespace + "/" + folder.lastPathComponent
            ))
        }
      }
      let raw = vault.appendingPathComponent("raw")
      guard fm.fileExists(atPath: raw.path) else { continue }
      try validateContained(raw, within: searchRoot)
      for url in try fm.contentsOfDirectory(
        at: raw, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      {
        guard url.pathExtension == "md",
          Self.validDay(url.deletingPathExtension().lastPathComponent)
        else { continue }
        try validateContained(url, within: searchRoot)
        let document = DayDocument(try String(contentsOf: url, encoding: .utf8))
        guard document.valid else { throw NotebookError.unreadableFile }
        result += document.blocks.compactMap { block in
          Memo.fromMarkdown(block).map {
            NotebookEntry(memo: $0, day: url.deletingPathExtension().lastPathComponent,
              namespace: namespace, originalMarkdown: block, originRoot: root)
          }
        }
      }
    }
    guard Set(result.map(\.id)).count == result.count else { throw NotebookError.ambiguousRecord }
    return result.sorted {
      $0.memo.created == $1.memo.created ? $0.id < $1.id : $0.memo.created > $1.memo.created
    }
  }

  public func append(_ memo: Memo) throws {
    try append(memo, assets: [])
  }

  /// Publishes generated assets and their Markdown record as one coordinated operation.
  /// Existing attachments retain their original paths and metadata.
  public func append(_ memo: Memo, assets: [NotebookAssetInput]) throws {
    guard assets.count <= 10 else { throw NotebookError.invalidAsset }
    for asset in assets {
      guard !asset.data.isEmpty, asset.data.count <= 25 * 1024 * 1024,
        asset.fileExtension.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil,
        ["photo", "audio", "file"].contains(asset.kind),
        asset.duration.map({ $0.isFinite && $0 >= 0 && asset.kind == "audio" }) ?? true
      else { throw NotebookError.invalidAsset }
    }
    guard !memo.body.contains(DayDocument.modern) else { throw NotebookError.reservedSeparator }
    guard
      !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !memo.attachments.isEmpty || !assets.isEmpty
    else { throw NotebookError.emptyNote }
    let date = DateFormatter()
    date.calendar = Calendar(identifier: .gregorian)
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "yyyy-MM-dd"
    let url = root.appendingPathComponent("raw/\(date.string(from: memo.created)).md")
    try validateContained(url)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try coordinatedWrite(at: url) { coordinated in
      let existing =
        self.fm.fileExists(atPath: coordinated.path)
        ? try String(contentsOf: coordinated, encoding: .utf8) : ""
      var document = DayDocument(existing)
      guard document.valid else { throw NotebookError.ambiguousRecord }
      try self.requireIdentityCount(memo.id, namespace: "", count: 0)
      var saved = memo
      let generated = assets.map { asset in
        (asset, "\(UUID().uuidString).\(asset.fileExtension.lowercased())")
      }
      saved.attachments += generated.map { asset, filename in
        Memo.Attachment(file: "raw/assets/" + filename, kind: asset.kind, duration: asset.duration)
      }
      if !assets.isEmpty {
        let kinds = Set(saved.attachments.map(\.kind))
        saved.type = kinds == ["photo"] ? .photo : kinds == ["audio"] ? .voice : .mixed
      }
      let expected = document.blocks.compactMap(Memo.fromMarkdown).map(\.id) + [memo.id]
      document.blocks.append(saved.toMarkdown())
      try self.validateEncoding(document, expected: expected)
      let assetsFolder = self.root.appendingPathComponent("raw/assets")
      let staging = self.root.appendingPathComponent(".daypage-assets-\(UUID())")
      var published: [URL] = []
      var committed = false
      defer {
        if !committed {
          for url in published {
            if (try? self.validateContained(url)) != nil { try? self.fm.removeItem(at: url) }
          }
        }
        if !generated.isEmpty { try? self.fm.removeItem(at: staging) }
      }
      if !generated.isEmpty {
        try self.validateContained(assetsFolder)
        try self.fm.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
        try self.validateContained(staging)
        try self.fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for (asset, filename) in generated {
          let temporary = staging.appendingPathComponent(filename)
          try asset.data.write(to: temporary, options: .atomic)
          let destination = assetsFolder.appendingPathComponent(filename)
          try self.validateContained(destination)
          // moveItem fails if a destination already exists; no original is overwritten.
          try self.fm.moveItem(at: temporary, to: destination)
          published.append(destination)
        }
      }
      try self.validateContained(coordinated)
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
      committed = true
    }
  }

  public func update(_ entry: NotebookEntry, body: String) throws {
    guard !body.contains(DayDocument.modern) else { throw NotebookError.reservedSeparator }
    guard
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !entry.memo.attachments.isEmpty
    else { throw NotebookError.emptyNote }
    let url = try fileURL(for: entry)
    try coordinatedWrite(at: url) { coordinated in
      var (document, index) = try self.target(entry, at: coordinated)
      let block = document.blocks[index]
      guard let opening = block.range(of: "---\n"),
        let closing = block.range(of: "\n---", range: opening.upperBound..<block.endIndex)
      else { throw NotebookError.ambiguousRecord }
      // Preserve unknown YAML fields and every untargeted record's bytes.
      let expected = document.blocks.compactMap(Memo.fromMarkdown).map(\.id)
      document.blocks[index] = String(block[..<closing.upperBound]) + "\n\n" + body
      try self.validateEncoding(document, expected: expected)
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
    }
  }

  public func setPinned(_ entry: NotebookEntry, pinned: Bool) throws {
    let url = try fileURL(for: entry)
    try coordinatedWrite(at: url) { coordinated in
      var (document, index) = try self.target(entry, at: coordinated)
      guard (entry.memo.pinnedAt != nil) != pinned else { return }
      let block = document.blocks[index]
      let header = try self.frontmatterRange(in: block)
      var lines = String(block[header]).components(separatedBy: "\n")
      let existing = lines.indices.filter { lines[$0].hasPrefix("pinned_at:") }
      guard existing.count <= 1 else { throw NotebookError.ambiguousRecord }
      if let old = existing.first { lines.remove(at: old) }
      if pinned { lines.insert("pinned_at: " + ISO8601DateFormatter.memo.string(from: Date()), at: 0) }
      document.blocks[index] = String(block[..<header.lowerBound]) + lines.joined(separator: "\n") + String(block[header.upperBound...])
      try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      guard (Memo.fromMarkdown(document.blocks[index])?.pinnedAt != nil) == pinned else {
        throw NotebookError.ambiguousRecord
      }
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
    }
  }

  /// Moves only the selected record into a recoverable hidden backup. Assets stay in place.
  public func trash(_ entry: NotebookEntry, validateSession: @Sendable () throws -> Void = {}) throws -> NotebookTrashReceipt {
    let url = try fileURL(for: entry)
    var result: NotebookTrashReceipt?
    try coordinatedWrite(at: url) { coordinated in
      try validateSession(); try Task.checkCancellation()
      var (document, index) = try self.target(entry, at: coordinated)
      try self.finishPendingRestores(for: entry)
      let original = document.content
      let block = document.blocks.remove(at: index)
      try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      let origin = try self.trashOrigin(create: true)
      let id = UUID()
      let folder = self.trashFolder(id)
      try self.validateContained(folder)
      try self.fm.createDirectory(at: folder, withIntermediateDirectories: false)
      var committed = false
      defer { if !committed { try? self.fm.removeItem(at: folder) } }
      let manifest = TrashManifest(version: 1, origin: origin, namespace: entry.namespace,
        day: entry.day, memoID: entry.memo.id, index: index, created: Date())
      try original.write(to: folder.appendingPathComponent("original.md"), atomically: true, encoding: .utf8)
      try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
      let deleting = folder.appendingPathComponent("deleting")
      try Data().write(to: deleting, options: .atomic)
      try self.validateContained(coordinated)
      try validateSession(); try Task.checkCancellation()
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
      committed = true
      // Keep deletion's commit separate from its prepared backup. If finalizing this
      // journal is interrupted, readback reconciles it against the original raw block.
      try? self.fm.moveItem(at: deleting, to: folder.appendingPathComponent("deleted"))
      let saved = NotebookEntry(memo: entry.memo, day: entry.day, namespace: entry.namespace,
        originalMarkdown: block, originRoot: self.root)
      result = NotebookTrashReceipt(id: id, entry: saved, origin: origin, originRoot: self.root)
    }
    guard let result else { throw NotebookError.unreadableFile }
    return result
  }

  /// Reads validated, unconsumed recovery records after an app restart.
  public func trashReceipts() throws -> [NotebookTrashReceipt] {
    let directory = root.appendingPathComponent(".daypage-trash")
    try validateContained(directory)
    guard fm.fileExists(atPath: directory.path) else { return [] }
    let origin = try trashOrigin(create: false)
    var records: [TrashRecord] = []
    for listed in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: listed.lastPathComponent) else { continue }
      let folder = trashFolder(id)
      try validateContained(folder)
      let restored = folder.appendingPathComponent("restored")
      try validateContained(restored)
      if fm.fileExists(atPath: restored.path) { continue }
      let manifest = folder.appendingPathComponent("manifest.json")
      try validateContained(manifest)
      // Raw deletion is ordered after the completed manifest; incomplete preparations
      // therefore cannot be real deletions. Keep their backups without publishing them.
      guard fm.fileExists(atPath: manifest.path) else { continue }
      let record = try readTrash(id, origin: origin)
      var committed = false
      try coordinatedWrite(at: fileURL(for: record.receipt.entry)) { coordinated in
        committed = try self.trashWasCommitted(record, at: coordinated)
      }
      guard committed else { continue }
      let pending = folder.appendingPathComponent("restoring")
      try validateContained(pending)
      if fm.fileExists(atPath: pending.path),
        try readEntries(in: root).contains(where: {
          $0.namespace == record.receipt.entry.namespace && $0.memo.id == record.receipt.entry.memo.id
        })
      {
        try? fm.moveItem(at: pending, to: restored)
        continue
      }
      records.append(record)
    }
    return records.sorted { $0.manifest.created > $1.manifest.created }.map(\.receipt)
  }

  public func restore(_ receipt: NotebookTrashReceipt) throws {
    guard NotebookPath.canonicalPath(receipt.originRoot) == NotebookPath.canonicalPath(root) else { throw NotebookError.invalidPath }
    let url = try fileURL(for: receipt.entry)
    try coordinatedWrite(at: url) { coordinated in
      let record = try self.readTrash(receipt.id, origin: self.trashOrigin(create: false))
      guard record.receipt.origin == receipt.origin, record.receipt.entry == receipt.entry,
        let saved = record.receipt.entry.originalMarkdown, let original = receipt.entry.originalMarkdown,
        saved.utf8.elementsEqual(original.utf8)
      else { throw NotebookError.conflict }
      let folder = self.trashFolder(receipt.id)
      let restored = folder.appendingPathComponent("restored")
      try self.validateContained(restored)
      guard !self.fm.fileExists(atPath: restored.path) else { throw NotebookError.conflict }
      guard try self.trashWasCommitted(record, at: coordinated) else { throw NotebookError.conflict }
      // An imported namespace must still exist; undo never recreates a removed namespace.
      let vault = try self.vaultURL(namespace: receipt.entry.namespace)
      guard self.fm.fileExists(atPath: vault.appendingPathComponent("raw").path) else {
        throw NotebookError.conflict
      }
      try self.requireIdentityCount(receipt.entry.memo.id, namespace: receipt.entry.namespace, count: 0)
      let content = self.fm.fileExists(atPath: coordinated.path)
        ? try String(contentsOf: coordinated, encoding: .utf8) : ""
      var current = DayDocument(content)
      guard current.valid else { throw NotebookError.ambiguousRecord }
      var remainder = record.original
      let block = remainder.blocks.remove(at: record.manifest.index)
      if content.utf8.elementsEqual(remainder.content.utf8) {
        current = record.original
      } else {
        current.blocks.insert(block, at: min(record.manifest.index, current.blocks.count))
      }
      try self.validateEncoding(current, expected: current.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      let pending = folder.appendingPathComponent("restoring")
      try self.validateContained(pending)
      // Preflight recovery metadata before changing Markdown. An interrupted journal is
      // resolved against the live identity when Recently Deleted is opened again.
      try Data().write(to: pending, options: .atomic)
      var committed = false
      defer { if !committed { try? self.fm.removeItem(at: pending) } }
      try self.validateContained(coordinated)
      try current.content.write(to: coordinated, atomically: true, encoding: .utf8)
      committed = true
      // The original backup is retained even after recovery; no permanent-delete API exists.
      try? self.fm.moveItem(at: pending, to: restored)
    }
  }

  /// Copies only into a new namespace; originals and existing local notes are untouched.
  public func importVault(from source: URL) throws {
    let original = source.standardizedFileURL
    let sourcePath = NotebookPath.canonicalPath(original), rootPath = NotebookPath.canonicalPath(root)
    guard sourcePath != rootPath, !sourcePath.hasPrefix(rootPath + "/"),
      fm.fileExists(atPath: original.appendingPathComponent("raw").path)
        || fm.fileExists(atPath: original.appendingPathComponent("imports").path)
    else { throw NotebookError.invalidVault }
    let keys: Set<URLResourceKey> = [
      .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]
    guard (try original.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
      let enumerator = fm.enumerator(at: original, includingPropertiesForKeys: Array(keys))
    else { throw NotebookError.invalidVault }
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true,
        !(values.isUbiquitousItem == true
          && values.ubiquitousItemDownloadingStatus == .notDownloaded)
      else { throw NotebookError.invalidVault }
    }
    let stagingParent = root.appendingPathComponent(".import-\(UUID())")
    let staging = stagingParent.appendingPathComponent("vault")
    let imports = root.appendingPathComponent("imports")
    let destination = imports.appendingPathComponent(UUID().uuidString)
    // Validate every publication path before creating or copying anything. A
    // linked root/imports folder must never redirect staging or the final move.
    try validateContained(stagingParent)
    try validateContained(staging)
    try validateContained(imports)
    try validateContained(destination)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try validateContained(stagingParent)
    // mkdir is exclusive: a failed reservation never claims an existing tree.
    guard mkdir(stagingParent.path, mode_t(0o700)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer {
      if (try? validateContained(stagingParent)) != nil,
        fm.fileExists(atPath: stagingParent.path) { try? fm.removeItem(at: stagingParent) }
    }
    try validateContained(staging)
    try fm.copyItem(at: original, to: staging)
    _ = try readEntries(in: staging)
    try validateContained(imports)
    try fm.createDirectory(at: imports, withIntermediateDirectories: true)
    try validateContained(staging)
    try validateContained(imports)
    try validateContained(destination)
    try fm.moveItem(at: staging, to: destination)
  }

  public func assetURL(_ path: String, for entry: NotebookEntry) throws -> URL {
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      throw NotebookError.invalidPath
    }
    let base = try vaultURL(namespace: entry.namespace)
    let relative = path.hasPrefix("raw/assets/") ? path : "raw/assets/" + path
    let url = base.appendingPathComponent(relative).standardizedFileURL
    let assets = NotebookPath.canonicalPath(base.appendingPathComponent("raw/assets"))
    guard NotebookPath.canonicalPath(url).hasPrefix(assets + "/") else {
      throw NotebookError.invalidPath
    }
    try validateContained(url)
    return url
  }

  private func target(_ entry: NotebookEntry, at url: URL) throws -> (DayDocument, Int) {
    let document = DayDocument(try String(contentsOf: url, encoding: .utf8))
    guard document.valid else { throw NotebookError.ambiguousRecord }
    try requireIdentityCount(entry.memo.id, namespace: entry.namespace, count: 1)
    let matches = document.blocks.indices.filter {
      Memo.fromMarkdown(document.blocks[$0])?.id == entry.memo.id
    }
    guard matches.count == 1, let index = matches.first else { throw NotebookError.ambiguousRecord }
    guard Memo.fromMarkdown(document.blocks[index]) == entry.memo,
      entry.originalMarkdown.map({ $0.utf8.elementsEqual(document.blocks[index].utf8) }) ?? true
    else { throw NotebookError.conflict }
    return (document, index)
  }

  private func requireIdentityCount(_ id: UUID, namespace: String, count: Int) throws {
    let matching = try readEntries(in: root).filter { $0.namespace == namespace && $0.memo.id == id }
    guard matching.count == count else { throw NotebookError.conflict }
  }

  private func frontmatterRange(in block: String) throws -> Range<String.Index> {
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
    guard let opening = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      lines[opening].trimmingCharacters(in: .whitespaces) == "---",
      let closing = lines.indices.dropFirst(opening + 1).first(where: {
        lines[$0].trimmingCharacters(in: .whitespaces) == "---"
      }), lines[opening].endIndex < block.endIndex
    else { throw NotebookError.ambiguousRecord }
    return block.index(after: lines[opening].endIndex)..<lines[closing].startIndex
  }

  private func trashFolder(_ id: UUID) -> URL {
    root.appendingPathComponent(".daypage-trash/\(id.uuidString)")
  }

  /// Called while the affected raw file is coordinated, so another Store cannot
  /// mistake an in-flight preparation for an abandoned deletion.
  private func trashWasCommitted(_ record: TrashRecord, at url: URL) throws -> Bool {
    let folder = trashFolder(record.receipt.id)
    let deleted = folder.appendingPathComponent("deleted")
    let cancelled = folder.appendingPathComponent("cancelled")
    let deleting = folder.appendingPathComponent("deleting")
    for marker in [deleted, cancelled, deleting] { try validateContained(marker) }
    // A completed deletion stays recoverable even if its exact UUID/body is reintroduced.
    if fm.fileExists(atPath: deleted.path) { return true }
    if fm.fileExists(atPath: cancelled.path) { return false }
    let content = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    let current = DayDocument(content)
    guard current.valid else { throw NotebookError.unreadableFile }
    let matches = current.blocks.filter { Memo.fromMarkdown($0)?.id == record.manifest.memoID }
    let original = record.original.blocks[record.manifest.index]
    if matches.count == 1, let active = matches.first, active.utf8.elementsEqual(original.utf8) {
      // The original record never left raw. Persist cancellation so later edits or
      // removal of that active record cannot resurrect this abandoned preparation.
      try Data().write(to: cancelled, options: .atomic)
      return false
    }
    if matches.isEmpty {
      if fm.fileExists(atPath: deleting.path) {
        try fm.moveItem(at: deleting, to: deleted)
      } else {
        try Data().write(to: deleted, options: .atomic)
      }
    }
    // A changed/ambiguous active identity keeps its backup visible as a conflict.
    return true
  }

  private func finishPendingRestores(for entry: NotebookEntry) throws {
    let directory = root.appendingPathComponent(".daypage-trash")
    try validateContained(directory)
    guard fm.fileExists(atPath: directory.path) else { return }
    let origin = try trashOrigin(create: false)
    for listed in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: listed.lastPathComponent) else { continue }
      let folder = trashFolder(id)
      let pending = folder.appendingPathComponent("restoring")
      let restored = folder.appendingPathComponent("restored")
      try validateContained(pending)
      try validateContained(restored)
      guard fm.fileExists(atPath: pending.path), !fm.fileExists(atPath: restored.path) else { continue }
      let record = try readTrash(id, origin: origin)
      if record.receipt.entry.id == entry.id {
        try fm.moveItem(at: pending, to: restored)
      }
    }
  }

  private func trashOrigin(create: Bool) throws -> UUID {
    let directory = root.appendingPathComponent(".daypage-trash")
    let marker = directory.appendingPathComponent(".origin")
    try validateContained(marker)
    if create {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      if !fm.fileExists(atPath: marker.path) {
        do {
          try Data(UUID().uuidString.utf8).write(to: marker, options: .withoutOverwriting)
        } catch {
          guard fm.fileExists(atPath: marker.path) else { throw error }
        }
      }
    }
    try validateContained(marker)
    guard let origin = UUID(uuidString: try String(contentsOf: marker, encoding: .utf8)) else {
      throw NotebookError.unreadableFile
    }
    return origin
  }

  private func readTrash(_ id: UUID, origin: UUID) throws -> TrashRecord {
    let folder = trashFolder(id)
    let manifestURL = folder.appendingPathComponent("manifest.json")
    let originalURL = folder.appendingPathComponent("original.md")
    try validateContained(manifestURL)
    try validateContained(originalURL)
    let manifest = try JSONDecoder().decode(TrashManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.version == 1, manifest.origin == origin, Self.validDay(manifest.day),
      manifest.index >= 0
    else { throw NotebookError.invalidPath }
    // Validate the namespace before exposing any recovered entry to the app.
    let vault = try vaultURL(namespace: manifest.namespace)
    try validateContained(vault.appendingPathComponent("raw/\(manifest.day).md"))
    let original = DayDocument(try String(contentsOf: originalURL, encoding: .utf8))
    let ids = original.blocks.compactMap(Memo.fromMarkdown).map(\.id)
    guard original.valid, original.blocks.indices.contains(manifest.index),
      Set(ids).count == ids.count,
      let memo = Memo.fromMarkdown(original.blocks[manifest.index]), memo.id == manifest.memoID
    else { throw NotebookError.unreadableFile }
    let entry = NotebookEntry(memo: memo, day: manifest.day, namespace: manifest.namespace,
      originalMarkdown: original.blocks[manifest.index], originRoot: root)
    return TrashRecord(manifest: manifest, original: original,
      receipt: NotebookTrashReceipt(id: id, entry: entry, origin: origin, originRoot: root))
  }

  private func fileURL(for entry: NotebookEntry) throws -> URL {
    guard Self.validDay(entry.day) else { throw NotebookError.invalidPath }
    if let origin = entry.originRoot, NotebookPath.canonicalPath(origin) != NotebookPath.canonicalPath(root) { throw NotebookError.invalidPath }
    let url = try vaultURL(namespace: entry.namespace).appendingPathComponent("raw/\(entry.day).md")
    try validateContained(url)
    return url
  }
  private func vaultURL(namespace: String) throws -> URL {
    if namespace.isEmpty { return root }
    let parts = namespace.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 16, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else {
      throw NotebookError.invalidPath
    }
    var base = root
    for part in parts {
      let imports = base.appendingPathComponent("imports")
      try validateContained(imports)
      if fm.fileExists(atPath: imports.path) {
        let aliases = try fm.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)
          .filter { $0.lastPathComponent.lowercased() == part.lowercased() }
        guard aliases.count <= 1, aliases.first.map({ $0.lastPathComponent == String(part) }) ?? true
        else { throw NotebookError.invalidPath }
      }
      base = imports.appendingPathComponent(String(part))
    }
    return base
  }
  private func validateEncoding(_ document: DayDocument, expected: [UUID]) throws {
    let candidate = DayDocument(document.content)
    guard candidate.valid, candidate.blocks.compactMap(Memo.fromMarkdown).map(\.id) == expected
    else { throw NotebookError.reservedSeparator }
  }
  /// Coordinates the entire transaction with Files and other store instances,
  /// rather than coordinating only the final atomic replacement.
  private func coordinatedWrite(at url: URL, operation: (URL) throws -> Void) throws {
    var coordinationError: NSError?
    var operationError: Error?
    var performed = false
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forMerging, error: &coordinationError
    ) { coordinated in
      performed = true
      do {
        try self.validateContained(coordinated)
        try operation(coordinated)
      } catch { operationError = error }
    }
    if let operationError { throw operationError }
    if let coordinationError { throw coordinationError }
    guard performed else { throw NotebookError.unreadableFile }
  }
  private func validateContained(_ url: URL, within allowedRoot: URL? = nil) throws {
    let requestedBase = (allowedRoot ?? root).standardizedFileURL
    let candidate = url.standardizedFileURL
    if let attributes = try? fm.attributesOfItem(atPath: requestedBase.path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    { throw NotebookError.invalidPath }
    let base = NotebookPath.canonicalPath(requestedBase)
    let resolved = NotebookPath.canonicalPath(candidate)
    guard resolved.hasPrefix(base + "/") else { throw NotebookError.invalidPath }
    // Reject links even when they resolve inside the notebook, including dangling links.
    // Walk the original spelling so canonical comparison cannot hide a link.
    var path = candidate
    while true {
      do {
        let attributes = try fm.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          throw NotebookError.invalidPath
        }
      } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        // New files and directories are validated through their existing ancestors.
      }
      let current = NotebookPath.canonicalPath(path)
      if current == base { break }
      guard current.hasPrefix(base + "/") else { throw NotebookError.invalidPath }
      path.deleteLastPathComponent()
    }
  }
  private static func validDay(_ day: String) -> Bool {
    guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
      return false
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: day) else { return false }
    return formatter.string(from: date) == day
  }
}
