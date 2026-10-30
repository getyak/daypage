import Foundation

struct CaptureDraftSnapshot: Codable, Sendable {
  var version = 1
  var revision: UInt64 = 0
  var memoID: UUID
  var body: String
  var assets: [PendingNoteAsset]

  init(memoID: UUID = UUID(), body: String = "", assets: [PendingNoteAsset] = []) {
    self.memoID = memoID
    self.body = body
    self.assets = assets
  }

  private enum CodingKeys: String, CodingKey { case version, revision, memoID, body, assets }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    memoID = try values.decode(UUID.self, forKey: .memoID)
    body = try values.decode(String.self, forKey: .body)
    assets = try values.decode([PendingNoteAsset].self, forKey: .assets)
  }
}

private struct CaptureDraftBody: Codable {
  var version = 1
  let memoID: UUID
  let revision: UInt64
  let body: String
}

/// A separate draft snapshot keeps photo/file/audio bytes across editor collapse
/// and relaunch. It never writes raw note files. All I/O runs outside MainActor.
actor CaptureDraftStore {
  let root: URL
  private var revision: UInt64 = 0
  private var persistedMemoID: UUID?
  init(root: URL) { self.root = root }
  private var file: URL { root.appendingPathComponent(".daypage/capture-draft.json") }
  private var bodyFile: URL { root.appendingPathComponent(".daypage/capture-body.json") }

  func load(committedMemoIDs: Set<UUID> = []) throws -> CaptureDraftSnapshot {
    try validatePath()
    var snapshot: CaptureDraftSnapshot
    var hasEnvelope = false
    if FileManager.default.fileExists(atPath: file.path) {
      let data = try read(file, maximumBytes: 72 * 1024 * 1024)
      let decoder = JSONDecoder()
      if let envelope = try? decoder.decode(CaptureDraftSnapshot.self, from: data) {
        snapshot = envelope
        hasEnvelope = true
      } else {
        // Upgrade the original attachment-only array without discarding its
        // separate text draft. The next successful save writes the envelope.
        snapshot = CaptureDraftSnapshot(
          body: try legacyBody(), assets: try decoder.decode([PendingNoteAsset].self, from: data))
      }
    } else {
      snapshot = CaptureDraftSnapshot(body: try legacyBody())
    }
    try validate(snapshot)
    if hasEnvelope, FileManager.default.fileExists(atPath: bodyFile.path) {
      let body = try JSONDecoder().decode(
        CaptureDraftBody.self, from: read(bodyFile, maximumBytes: 24 * 1024 * 1024 + 4096))
      guard body.version == 1, body.revision <= UInt64.max / 2 else {
        throw CaptureDraftError.invalidSnapshot
      }
      guard body.body.utf8.count <= 4 * 1024 * 1024 else { throw CaptureDraftError.tooLarge }
      if body.memoID == snapshot.memoID, body.revision > snapshot.revision {
        snapshot.body = body.body
        snapshot.revision = body.revision
      }
    }
    persistedMemoID = hasEnvelope ? snapshot.memoID : nil
    revision = max(revision, snapshot.revision)
    // Raw publication is the commit point. A failed best-effort cleanup must
    // not replay the committed draft, even while .daypage remains read-only.
    if committedMemoIDs.contains(snapshot.memoID) {
      var next = CaptureDraftSnapshot()
      next.revision = snapshot.revision
      return next
    }
    return snapshot
  }

  func save(_ snapshot: CaptureDraftSnapshot, revision proposed: UInt64) throws {
    guard proposed >= revision else { return }
    var snapshot = snapshot
    snapshot.revision = proposed
    try validate(snapshot)
    try validatePath()
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoded = try JSONEncoder().encode(snapshot)
    guard encoded.count <= 72 * 1024 * 1024 else { throw CaptureDraftError.tooLarge }
    try encoded.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    revision = proposed
    persistedMemoID = snapshot.memoID
  }

  /// Typing changes only a bounded text sidecar. Full asset envelopes are
  /// written on identity/attachment changes and synchronously before raw commit.
  func saveBody(_ snapshot: CaptureDraftSnapshot, revision proposed: UInt64) throws {
    guard proposed >= revision else { return }
    guard persistedMemoID == snapshot.memoID else {
      try save(snapshot, revision: proposed)
      return
    }
    var snapshot = snapshot
    snapshot.revision = proposed
    try validate(snapshot)
    try validatePath()
    let body = CaptureDraftBody(memoID: snapshot.memoID, revision: proposed, body: snapshot.body)
    try JSONEncoder().encode(body).write(
      to: bodyFile, options: [.atomic, .completeFileProtectionUnlessOpen])
    revision = proposed
  }

  private func validate(_ snapshot: CaptureDraftSnapshot) throws {
    guard snapshot.version == 1, snapshot.revision <= UInt64.max / 2 else {
      throw CaptureDraftError.invalidSnapshot
    }
    let assets = snapshot.assets
    guard snapshot.body.utf8.count <= 4 * 1024 * 1024,
      assets.count <= 10, Set(assets.map(\.id)).count == assets.count,
      assets.reduce(0, { $0 + $1.data.count }) <= 50 * 1024 * 1024,
      assets.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 25 * 1024 * 1024 })
    else {
      throw CaptureDraftError.tooLarge
    }
  }
  private func legacyBody() throws -> String {
    let legacy = file.deletingLastPathComponent().appendingPathComponent("draft.txt")
    guard FileManager.default.fileExists(atPath: legacy.path) else { return "" }
    guard (try legacy.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
      throw CaptureDraftError.invalidPath
    }
    let data = try read(legacy, maximumBytes: 4 * 1024 * 1024)
    guard let text = String(data: data, encoding: .utf8) else {
      throw CaptureDraftError.invalidSnapshot
    }
    return text
  }
  private func read(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw CaptureDraftError.invalidPath }
    guard (values.fileSize ?? 0) <= maximumBytes else { throw CaptureDraftError.tooLarge }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(1024 * 1024, maximumBytes + 1 - data.count)),
      !chunk.isEmpty
    {
      data.append(chunk)
      guard data.count <= maximumBytes else { throw CaptureDraftError.tooLarge }
    }
    return data
  }
  private func validatePath() throws {
    for candidate in [root, file.deletingLastPathComponent(), file, bodyFile] {
      if FileManager.default.fileExists(atPath: candidate.path),
        (try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true
      {
        throw CaptureDraftError.invalidPath
      }
    }
    let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(realRoot + "/") else {
      throw CaptureDraftError.invalidPath
    }
  }
}

enum CaptureDraftError: LocalizedError {
  case tooLarge, invalidPath, invalidSnapshot
  var errorDescription: String? {
    switch self {
    case .tooLarge: return "Use up to 10 attachments, 25 MB each and 50 MB in total."
    case .invalidPath:
      return "The draft folder needs attention. Existing files have been preserved."
    case .invalidSnapshot:
      return "This draft could not be read. Its original file has been preserved."
    }
  }
}
