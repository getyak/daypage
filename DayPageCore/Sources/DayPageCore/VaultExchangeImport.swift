import Darwin
import DayPageCapture
import Foundation

public struct PendingVaultImport: Identifiable, Sendable {
  public enum Phase: String, Sendable { case needsSource, ready, published, unreadable }
  public let id: UUID
  public let sourceName: String
  public let manifest: VaultExchangeManifest?
  public let phase: Phase
  public let byteCount: Int
  let token: UUID?
  public var namespace: String { id.uuidString }
}

/// Explicit selected-folder exchange. Publication is a new namespace only.
/// Pending copies survive termination and never become live notes on their own.
public actor VaultExchangeImport {
  public let root: URL
  private let fm = FileManager.default
  private struct Job: Codable {
    let version: Int; let id: UUID; let token: UUID; let sourceName: String; let manifest: VaultExchangeManifest
  }
  private struct Receipt: Codable, Equatable {
    let version: Int; let id: UUID; let token: UUID; let contentSHA256: String
  }
  public init(root: URL) { self.root = root.standardizedFileURL }
  private var jobs: URL { root.appendingPathComponent(".daypage/exchange-imports-v1") }
  private func jobFolder(_ id: UUID) -> URL { jobs.appendingPathComponent(id.uuidString) }
  private func destination(_ id: UUID) -> URL { root.appendingPathComponent("imports/" + id.uuidString) }

  public func prepare(from source: URL) async throws -> PendingVaultImport {
    try Task.checkCancellation()
    try ExchangeIO.safe(source, within: source)
    let sourcePath = NotebookPath.canonicalPath(source), target = NotebookPath.canonicalPath(root)
    guard sourcePath != target, !sourcePath.hasPrefix(target + "/") else { throw VaultExchangeError.invalid }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let snapshot = try await loadSource(source)
    try Task.checkCancellation()
    return try locked {
      let existing = try jobIDs()
      let occupied = try existing.reduce(0) { try $0 + ExchangeIO.measure(jobFolder($1), within: root) }
      guard existing.count < 3, occupied + snapshot.manifest.byteCount <= 100 * 1024 * 1024 else { throw VaultExchangeError.full }
      let id = UUID(), folder = jobFolder(id)
      try ExchangeIO.safe(folder, within: root)
      guard mkdir(folder.path, mode_t(0o700)) == 0 else { throw VaultExchangeError.conflict }
      let name = String(source.lastPathComponent.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(160))
      let job = Job(version: 1, id: id, token: UUID(), sourceName: name, manifest: snapshot.manifest)
      // Plan first. No payload is copied until a complete, resumable job exists.
      let pending = folder.appendingPathComponent("job.pending")
      try ReplicaDigest.encode(job).write(to: pending, options: .completeFileProtectionUnlessOpen)
      try fm.moveItem(at: pending, to: folder.appendingPathComponent("job.json"))
      try copy(snapshot, for: job)
      return try status(id)
    }
  }

  public func pendingImports() throws -> [PendingVaultImport] {
    try locked { try jobIDs().map { try status($0) } }
  }

  public func preview(_ pending: PendingVaultImport) throws -> ExchangeRecords {
    try locked {
      let job = try requiredJob(pending)
      let vault = jobFolder(job.id).appendingPathComponent("vault")
      let snapshot = try ExchangeIO.loadV1(vault)
      try validateStagedTree(vault, manifest: job.manifest)
      guard snapshot.manifest.contentSHA256 == job.manifest.contentSHA256 else { throw VaultExchangeError.changed }
      try NotebookStore.validateExchangeProjection(snapshot)
      return snapshot.records
    }
  }

  public func resume(_ pending: PendingVaultImport, from source: URL) async throws -> PendingVaultImport {
    try Task.checkCancellation()
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let sourcePath = NotebookPath.canonicalPath(source), target = NotebookPath.canonicalPath(root)
    guard sourcePath != target, !sourcePath.hasPrefix(target + "/") else { throw VaultExchangeError.invalid }
    let snapshot = try await loadSource(source)
    try Task.checkCancellation()
    return try locked {
      let job = try requiredJob(pending)
      guard snapshot.manifest.contentSHA256 == job.manifest.contentSHA256 else { throw VaultExchangeError.changed }
      if try hasReceipt(job) { return try status(job.id) }
      try copy(snapshot, for: job)
      return try status(job.id)
    }
  }

  /// Confirmation is separate from selection/validation. A durable private
  /// receipt distinguishes retry from a same-UUID directory collision.
  @discardableResult
  public func confirm(_ pending: PendingVaultImport) throws -> String {
    try locked {
      try Task.checkCancellation()
      let job = try requiredJob(pending)
      if try hasReceipt(job) {
        try? fm.removeItem(at: jobFolder(job.id))
        return job.id.uuidString
      }
      let vault = jobFolder(job.id).appendingPathComponent("vault")
      let snapshot = try ExchangeIO.loadV1(vault)
      try validateStagedTree(vault, manifest: job.manifest)
      guard snapshot.manifest.contentSHA256 == job.manifest.contentSHA256 else { throw VaultExchangeError.changed }
      try NotebookStore.validateExchangeProjection(snapshot)
      let imports = root.appendingPathComponent("imports")
      try ExchangeIO.safe(imports, within: root)
      try fm.createDirectory(at: imports, withIntermediateDirectories: true)
      let aliases = try fm.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.lowercased() == job.id.uuidString.lowercased() }
      guard aliases.isEmpty else { throw VaultExchangeError.conflict }
      let receipt = Receipt(version: 1, id: job.id, token: job.token, contentSHA256: job.manifest.contentSHA256)
      let receiptFile = vault.appendingPathComponent(".daypage/exchange-receipt.json")
      try ExchangeIO.safe(receiptFile, within: vault)
      try fm.createDirectory(at: receiptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try ReplicaDigest.encode(receipt).write(to: receiptFile, options: .completeFileProtectionUnlessOpen)
      let target = destination(job.id)
      try ExchangeIO.safe(target, within: root)
      try Task.checkCancellation()
      try fm.moveItem(at: vault, to: target)
      // Namespace publication is the commit point. Cleanup failure is pending
      // housekeeping, not a failed import or a reason to create another copy.
      try? fm.removeItem(at: jobFolder(job.id))
      return job.id.uuidString
    }
  }

  public func discard(_ pending: PendingVaultImport) throws {
    try locked {
      let folder = jobFolder(pending.id)
      try ExchangeIO.safe(folder, within: root)
      if let token = pending.token {
        guard try readJob(pending.id).token == token else { throw VaultExchangeError.changed }
      } else if (try? readJob(pending.id)) != nil { throw VaultExchangeError.changed }
      // Only the app-owned pending copy. Never the source or published import.
      try fm.removeItem(at: folder)
    }
  }

  private func loadSource(_ source: URL) async throws -> VaultExchangeSnapshot {
    let snapshot: VaultExchangeSnapshot
    if fm.fileExists(atPath: source.appendingPathComponent("daypage-exchange.json").path) {
      snapshot = try ExchangeIO.loadV1(source)
    } else {
      snapshot = try await NotebookStore(root: source).exchangeSnapshot()
    }
    try NotebookStore.validateExchangeProjection(snapshot)
    return snapshot
  }

  private func copy(_ snapshot: VaultExchangeSnapshot, for job: Job) throws {
    let vault = jobFolder(job.id).appendingPathComponent("vault")
    try ExchangeIO.safe(vault, within: root)
    try fm.createDirectory(at: vault, withIntermediateDirectories: true)
    for file in job.manifest.files {
      try Task.checkCancellation()
      guard let data = snapshot.files[file.path], data.count == file.bytes,
        ReplicaDigest.hash(data) == file.sha256 else { throw VaultExchangeError.changed }
      let target = vault.appendingPathComponent(file.path)
      try ExchangeIO.safe(target, within: vault)
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      // The pending folder is not live. A killed write leaves a known partial
      // file which Resume replaces from the re-verified identical source.
      try data.write(to: target, options: .completeFileProtectionUnlessOpen)
    }
    try ReplicaDigest.encode(job.manifest).write(to: vault.appendingPathComponent("daypage-exchange.json"),
      options: .completeFileProtectionUnlessOpen)
    let verified = try ExchangeIO.loadV1(vault)
    guard verified.manifest.contentSHA256 == job.manifest.contentSHA256 else { throw VaultExchangeError.changed }
    try NotebookStore.validateExchangeProjection(verified)
  }

  private func readJob(_ id: UUID) throws -> Job {
    let path = jobFolder(id).appendingPathComponent("job.json")
    let job = try JSONDecoder().decode(Job.self, from: ExchangeIO.read(path, within: root, maximum: 512 * 1024))
    guard job.version == 1, job.id == id, job.sourceName.count <= 160 else { throw VaultExchangeError.invalid }
    try job.manifest.validate()
    return job
  }
  /// Only the verified exchange may become a live namespace. Reject unexpected
  /// files (including private sidecars) rather than moving them with the stage.
  private func validateStagedTree(_ vault: URL, manifest: VaultExchangeManifest) throws {
    let allowed = Set(manifest.files.map(\.path) + ["daypage-exchange.json", ".daypage/exchange-receipt.json"])
    let folders = Set(allowed.flatMap { path -> [String] in
      let parts = path.split(separator: "/")
      return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
    })
    guard let enumerator = fm.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else {
      throw VaultExchangeError.invalid
    }
    let basePath = NotebookPath.canonicalPath(vault)
    var count = 0
    for case let file as URL in enumerator {
      count += 1
      guard count <= 4000 else { throw VaultExchangeError.limit }
      try ExchangeIO.safe(file, within: vault)
      // Foundation may enumerate a /var URL as /private/var (or the reverse).
      // Reject notebook links first, then compare the same canonical identity.
      let path = NotebookPath.canonicalPath(file)
      guard path.hasPrefix(basePath + "/") else { throw VaultExchangeError.invalid }
      let relative = String(path.dropFirst(basePath.count + 1))
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      guard (values.isRegularFile == true && allowed.contains(relative))
        || (values.isDirectory == true && folders.contains(relative)) else { throw VaultExchangeError.invalid }
    }
  }
  private func requiredJob(_ pending: PendingVaultImport) throws -> Job {
    let job = try readJob(pending.id)
    guard pending.token == job.token, pending.manifest?.contentSHA256 == job.manifest.contentSHA256 else { throw VaultExchangeError.changed }
    return job
  }
  private func hasReceipt(_ job: Job) throws -> Bool {
    let target = destination(job.id)
    try ExchangeIO.safe(target, within: root)
    guard fm.fileExists(atPath: target.path) else { return false }
    let path = target.appendingPathComponent(".daypage/exchange-receipt.json")
    guard let bytes = try? ExchangeIO.read(path, within: root, maximum: 4096),
      let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes) else { throw VaultExchangeError.conflict }
    guard receipt == Receipt(version: 1, id: job.id, token: job.token, contentSHA256: job.manifest.contentSHA256) else {
      throw VaultExchangeError.conflict
    }
    return true
  }
  private func status(_ id: UUID) throws -> PendingVaultImport {
    let bytes = (try? ExchangeIO.measure(jobFolder(id), within: root)) ?? 0
    guard let job = try? readJob(id) else {
      return PendingVaultImport(id: id, sourceName: "Interrupted import", manifest: nil, phase: .unreadable, byteCount: bytes, token: nil)
    }
    let phase: PendingVaultImport.Phase
    if (try? hasReceipt(job)) == true { phase = .published }
    else if let snapshot = try? ExchangeIO.loadV1(jobFolder(id).appendingPathComponent("vault")),
      snapshot.manifest.contentSHA256 == job.manifest.contentSHA256,
      (try? validateStagedTree(jobFolder(id).appendingPathComponent("vault"), manifest: job.manifest)) != nil,
      (try? NotebookStore.validateExchangeProjection(snapshot)) != nil { phase = .ready }
    else { phase = .needsSource }
    return PendingVaultImport(id: id, sourceName: job.sourceName, manifest: job.manifest, phase: phase, byteCount: bytes, token: job.token)
  }
  private func jobIDs() throws -> [UUID] {
    let entries = try fm.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)
    guard entries.count <= 32 else { throw VaultExchangeError.full }
    return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }.sorted { $0.uuidString < $1.uuidString }
  }
  private func locked<T>(_ body: () throws -> T) throws -> T {
    try ExchangeIO.safe(jobs, within: root)
    try fm.createDirectory(at: jobs, withIntermediateDirectories: true)
    var location = jobs, values = URLResourceValues()
    values.isExcludedFromBackup = true
    try location.setResourceValues(values)
    let descriptor = open(jobs.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw VaultExchangeError.invalid }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      flock(descriptor, LOCK_EX) == 0 else { throw VaultExchangeError.invalid }
    defer { flock(descriptor, LOCK_UN) }
    try ExchangeIO.safe(jobs, within: root)
    return try body()
  }
}

enum ExchangeIO {
  static func safe(_ url: URL, within root: URL) throws {
    let base = root.standardizedFileURL, candidate = url.standardizedFileURL
    let basePath = NotebookPath.canonicalPath(base), path = NotebookPath.canonicalPath(candidate)
    guard path == basePath || path.hasPrefix(basePath + "/") else { throw VaultExchangeError.invalid }
    var cursor = candidate
    while true {
      if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path),
        attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw VaultExchangeError.invalid }
      // Creation can make Foundation standardize an existing /private/tmp
      // root to /tmp while a missing child keeps its original spelling.
      // Inspect links on the original walk, using canonical identity only to
      // determine containment and when that walk has reached the owner root.
      let current = NotebookPath.canonicalPath(cursor)
      if current == basePath { break }
      guard current.hasPrefix(basePath + "/") else { throw VaultExchangeError.invalid }
      cursor.deleteLastPathComponent()
    }
  }
  static func read(_ url: URL, within root: URL, maximum: Int) throws -> Data {
    try Task.checkCancellation()
    guard maximum >= 0 else { throw VaultExchangeError.limit }
    try safe(url, within: root)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw VaultExchangeError.invalid }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      info.st_size <= maximum else { throw VaultExchangeError.limit }
    var data = Data()
    while true {
      try Task.checkCancellation()
      let chunk = try handle.read(upToCount: min(64 * 1024, maximum - data.count + 1)) ?? Data()
      if chunk.isEmpty { break }
      guard chunk.count <= maximum - data.count else { throw VaultExchangeError.limit }
      data.append(chunk)
    }
    return data
  }
  /// Enumerate one level incrementally; contentsOfDirectory would first allocate
  /// an arbitrarily large URL array even when almost all entries are ignored.
  static func children(_ directory: URL, within root: URL, maximum: Int) throws -> [URL] {
    try Task.checkCancellation()
    guard maximum >= 0 else { throw VaultExchangeError.limit }
    try safe(directory, within: root)
    guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw VaultExchangeError.invalid }
    var failure: Error?
    guard let enumerator = FileManager.default.enumerator(at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsSubdirectoryDescendants],
      errorHandler: { _, error in failure = error; return false }) else { throw VaultExchangeError.invalid }
    var children: [URL] = []
    for case let child as URL in enumerator {
      try Task.checkCancellation()
      guard children.count < maximum else { throw VaultExchangeError.limit }
      children.append(child)
    }
    if let failure { throw failure }
    return children
  }
  static func loadV1(_ source: URL) throws -> VaultExchangeSnapshot {
    try safe(source, within: source)
    let manifest = try VaultExchangeManifest.decode(read(source.appendingPathComponent("daypage-exchange.json"),
      within: source, maximum: VaultExchangeLimits.manifest))
    var files: [String: Data] = [:]
    for file in manifest.files {
      let data = try read(source.appendingPathComponent(file.path), within: source, maximum: file.bytes)
      guard data.count == file.bytes, ReplicaDigest.hash(data) == file.sha256 else { throw VaultExchangeError.changed }
      files[file.path] = data
    }
    guard let data = files["records.json"] else { throw VaultExchangeError.invalid }
    let snapshot = VaultExchangeSnapshot(manifest: manifest, records: try ExchangeRecords.decode(data), files: files)
    try snapshot.validated()
    return snapshot
  }
  static func measure(_ root: URL, within owner: URL) throws -> Int {
    try safe(root, within: owner)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
    var total = 0, count = 0
    for case let file as URL in enumerator {
      try safe(file, within: owner)
      count += 1
      guard count <= 4000 else { throw VaultExchangeError.full }
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true { total += values.fileSize ?? 0 }
      guard total <= 101 * 1024 * 1024 else { throw VaultExchangeError.full }
    }
    return total
  }
}
