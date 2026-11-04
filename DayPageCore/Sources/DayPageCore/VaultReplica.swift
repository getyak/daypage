import Foundation

private struct ReplicaLocation: Codable, Equatable {
  let key: String
  let revision: String
  let namespace: String
}
private struct ReplicaState: Codable {
  var version = 1
  var locations: [String: ReplicaLocation] = [:]
}
private struct ReplicaApply: Codable {
  let identity: String
  let expected: String?
  let previous: ReplicaLocation?
  let target: ReplicaLocation?
  var started: Bool
}
private struct ReplicaJournal: Codable {
  let version: Int
  let state: ReplicaState
  var operations: [ReplicaApply]
}

/// Immutable revision DAG + local materializations. All mutable state is scoped by the native account adapter.
public actor VaultReplica {
  private let store: NotebookStore
  private let stateRoot: URL
  private let cache: DirectoryReplicaTransport
  private let validateSession: @Sendable () throws -> Void
  private var running = false
  public init(store: NotebookStore, stateRoot: URL, validateSession: @escaping @Sendable () throws -> Void = {}) {
    self.store = store; self.stateRoot = stateRoot
    self.validateSession = validateSession
    cache = DirectoryReplicaTransport(root: stateRoot.appendingPathComponent("cache"))
  }

  public func exchange(with transport: any ReplicaTransport) async throws {
    guard !running else { throw ReplicaError.busy }
    running = true; defer { running = false }
    try validateSession(); try Task.checkCancellation()
    try await recover()
    let state = try load(ReplicaState.self, name: "index.json") ?? ReplicaState()
    guard state.version == 1 else { throw ReplicaError.invalidData }
    let before = try await store.replicaRecords()
    var sources = state.locations
    let local = try await revisions()
    for record in before {
      let location = state.locations[record.identity]
      let key = location?.key ?? record.identity
      let prior = location.flatMap { local[$0.revision] }
      let candidate = try revision(record, key: key, parents: location.map { [$0.revision] } ?? [])
      if prior?.markdown != candidate.markdown || prior?.day != candidate.day || prior?.assets != candidate.assets {
        try await save(candidate, assets: record.assets)
        sources[record.identity] = ReplicaLocation(key: key, revision: candidate.id, namespace: record.namespace)
      }
    }
    let present = Set(before.map(\.identity))
    for (identity, location) in state.locations where !present.contains(identity) {
      let tombstone = VaultRevision(version: 1, key: location.key, parents: [location.revision], day: nil, markdown: nil, assets: [:])
      try await save(tombstone, assets: [:]); sources.removeValue(forKey: identity)
    }
    // Pull immutable files before publishing. Missing dependencies block integration, never delete a note.
    let remoteIDs = try await transport.revisionIDs()
    guard remoteIDs.count <= 10000 else { throw ReplicaError.invalidData }
    for id in remoteIDs {
      guard ReplicaDigest.valid(id) else { throw ReplicaError.invalidData }
      if local[id] != nil { continue } // validated immutable revisions need no repeated iCloud read
      let data = try await transport.read("revisions/" + id + ".json")
      let value = try JSONDecoder().decode(VaultRevision.self, from: data)
      try value.validate()
      guard value.id == id else { throw ReplicaError.invalidData }
      for hash in Set(value.assets.values) {
        if (try? await cache.read("objects/" + hash)) == nil {
          let object = try await transport.read("objects/" + hash)
          guard ReplicaDigest.hash(object) == hash else { throw ReplicaError.invalidData }
          try await cache.write(object, key: "objects/" + hash)
        }
      }
      try await cache.write(try ReplicaDigest.encode(value), key: "revisions/" + id + ".json")
    }
    let all = try await revisions()
    try validateGraph(all)
    let remote = Set(remoteIDs)
    for (id, value) in all.sorted(by: { $0.key < $1.key }) where !remote.contains(id) {
      for hash in Set(value.assets.values) {
        try await transport.write(try await cache.read("objects/" + hash), key: "objects/" + hash)
      }
      try await transport.write(try ReplicaDigest.encode(value), key: "revisions/" + id + ".json")
    }
    // UI edits made during network awaits must survive. A subsequent pass exports them as a branch.
    guard try await store.replicaRecords() == before else { throw ReplicaError.changed }
    let journal = try await plan(all, before: before, sources: sources)
    try persist(journal, name: "apply.json")
    try await recover()
  }

  public func history() async throws -> [VaultRevision] {
    try await revisions().values.filter { !$0.isDeleted }.sorted {
      ($0.day ?? "", $0.id) > ($1.day ?? "", $1.id)
    }
  }

  /// Restores a separate deterministic copy; re-selecting the same revision is idempotent.
  public func restore(_ id: String) async throws {
    guard !running else { throw ReplicaError.busy }
    running = true; defer { running = false }
    try validateSession(); try Task.checkCancellation()
    guard let value = try await revisions()[id], !value.isDeleted else { throw ReplicaError.invalidData }
    let namespace = ReplicaDigest.namespace("restore/" + id)
    let record = try await record(value, namespace: namespace)
    let existing = try await store.replicaRecords().first { $0.identity == record.identity }
    if existing == record { return }
    guard existing == nil else { throw ReplicaError.changed }
    try await store.applyReplica(record, identity: record.identity, expected: nil, validateSession: validateSession)
  }

  private func revision(_ record: ReplicaRecord, key: String, parents: [String]) throws -> VaultRevision {
    let result = VaultRevision(version: 1, key: key, parents: Array(Set(parents)).sorted(), day: record.day,
      markdown: record.markdown, assets: record.assets.mapValues(ReplicaDigest.hash))
    try result.validate(); return result
  }
  private func save(_ value: VaultRevision, assets: [String: Data]) async throws {
    try value.validate()
    for data in assets.values { try await cache.write(data, key: "objects/" + ReplicaDigest.hash(data)) }
    try await cache.write(try ReplicaDigest.encode(value), key: "revisions/" + value.id + ".json")
  }
  private func revisions() async throws -> [String: VaultRevision] {
    let ids = try await cache.revisionIDs()
    guard ids.count <= 10000 else { throw ReplicaError.invalidData }
    var result: [String: VaultRevision] = [:]
    for id in ids {
      let value = try JSONDecoder().decode(VaultRevision.self, from: await cache.read("revisions/" + id + ".json"))
      try value.validate(); guard value.id == id else { throw ReplicaError.invalidData }; result[id] = value
    }
    return result
  }
  private func validateGraph(_ values: [String: VaultRevision]) throws {
    for value in values.values {
      for parent in value.parents {
        guard let prior = values[parent] else { throw ReplicaError.unavailable }
        guard prior.key == value.key else { throw ReplicaError.invalidData }
      }
    }
  }
  private func record(_ value: VaultRevision, namespace: String) async throws -> ReplicaRecord {
    guard let markdown = value.markdown, let day = value.day else { throw ReplicaError.invalidData }
    var assets: [String: Data] = [:]
    for (path, hash) in value.assets {
      let data = try await cache.read("objects/" + hash)
      guard ReplicaDigest.hash(data) == hash else { throw ReplicaError.invalidData }; assets[path] = data
    }
    return ReplicaRecord(namespace: namespace, day: day, markdown: markdown, assets: assets)
  }
  private func plan(_ all: [String: VaultRevision], before: [ReplicaRecord], sources: [String: ReplicaLocation]) async throws -> ReplicaJournal {
    try validateGraph(all)
    let ancestors = Set(all.values.flatMap(\.parents))
    let grouped = Dictionary(grouping: all.values.filter { !ancestors.contains($0.id) && !$0.isDeleted }, by: \.key)
    var state = ReplicaState()
    var desired: [String: ReplicaRecord] = [:]
    for (key, heads) in grouped.sorted(by: { $0.key < $1.key }) {
      for (index, head) in heads.sorted(by: { $0.id < $1.id }).enumerated() {
        let namespace = index == 0 ? try VaultRevision.namespace(for: key) : ReplicaDigest.namespace("conflict/" + head.id)
        let target = try await record(head, namespace: namespace)
        guard desired[target.identity] == nil else { throw ReplicaError.invalidData }
        desired[target.identity] = target
        state.locations[target.identity] = ReplicaLocation(key: key, revision: head.id, namespace: namespace)
      }
    }
    let current = Dictionary(uniqueKeysWithValues: before.map { ($0.identity, $0) })
    var operations: [ReplicaApply] = []
    for identity in Set(current.keys).union(desired.keys).sorted() where current[identity] != desired[identity] {
      operations.append(ReplicaApply(identity: identity, expected: try current[identity]?.fingerprint,
        previous: sources[identity], target: state.locations[identity], started: false))
    }
    return ReplicaJournal(version: 1, state: state, operations: operations)
  }
  private func recover() async throws {
    guard var journal = try load(ReplicaJournal.self, name: "apply.json") else { return }
    guard journal.version == 1, journal.state.version == 1 else { throw ReplicaError.invalidData }
    let all = try await revisions()
    let current = try await store.replicaRecords()
    let records = Dictionary(uniqueKeysWithValues: current.map { ($0.identity, $0) })
    var replanned = false
    var sources = journal.state.locations
    for operation in journal.operations where sources[operation.identity] == nil {
      sources[operation.identity] = operation.previous
    }
    for operation in journal.operations {
      let existing = records[operation.identity]
      let target: ReplicaRecord?
      if let location = operation.target, let value = all[location.revision] {
        target = try await record(value, namespace: location.namespace)
      } else { target = nil }
      let fingerprint = try existing?.fingerprint
      if existing == target { continue }
      let deletedAfterWrite: Bool
      if operation.started, existing == nil, let target {
        deletedAfterWrite = try await store.wasReplicaTrashed(target)
      } else { deletedAfterWrite = false }
      let uncertainReplay = operation.started && existing != nil
      if fingerprint == operation.expected && !uncertainReplay && !deletedAfterWrite { continue }
      // A third value is a new local edit/deletion. Save its branch before replacing the old plan.
      let source = operation.started && fingerprint != operation.expected
        ? operation.target ?? operation.previous : operation.previous ?? operation.target
      guard let source else { throw ReplicaError.changed }
      let branch = try existing.map { try revision($0, key: source.key, parents: [source.revision]) }
        ?? VaultRevision(version: 1, key: source.key, parents: [source.revision], day: nil, markdown: nil, assets: [:])
      try await save(branch, assets: existing?.assets ?? [:])
      sources[operation.identity] = ReplicaLocation(key: source.key, revision: branch.id,
        namespace: existing?.namespace ?? source.namespace)
      replanned = true
    }
    if replanned {
      try persist(try await plan(revisions(), before: current, sources: sources), name: "apply.json")
      throw ReplicaError.changed // next foreground/query retry resumes the revised journal
    }
    for (index, operation) in journal.operations.enumerated() {
      try validateSession(); try Task.checkCancellation()
      let existing = try await store.replicaRecords().first { $0.identity == operation.identity }
      let target: ReplicaRecord?
      if let location = operation.target {
        guard let value = all[location.revision] else { throw ReplicaError.unavailable }
        target = try await record(value, namespace: location.namespace)
      } else { target = nil }
      if existing == target { continue }
      // Intent precedes raw writes, covering the raw-commit/index-commit crash window.
      journal.operations[index].started = true
      try persist(journal, name: "apply.json")
      try await store.applyReplica(target, identity: operation.identity, expected: operation.expected,
        validateSession: validateSession)
    }
    try persist(journal.state, name: "index.json")
    try FileManager.default.removeItem(at: stateRoot.appendingPathComponent("apply.json"))
  }
  private func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
    let url = stateRoot.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
    guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 10 * 1024 * 1024 else { throw ReplicaError.invalidData }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
  }
  private func persist<T: Encodable>(_ value: T, name: String) throws {
    try validateSession(); try Task.checkCancellation()
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    let url = stateRoot.appendingPathComponent(name)
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ReplicaError.invalidData }
    try ReplicaDigest.encode(value).write(to: url, options: .atomic)
  }
}
