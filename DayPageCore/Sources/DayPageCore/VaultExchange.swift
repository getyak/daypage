import DayPageCapture
import Foundation

public enum VaultExchangeError: LocalizedError {
  case invalid, limit, changed, conflict, missingSource, full
  public var errorDescription: String? {
    switch self {
    case .invalid: return "This exchange could not be verified. Original files were preserved."
    case .limit: return "Choose fewer notes or a smaller exchange. The limit is 50 MB and 500 notes."
    case .changed: return "The selected files changed. Preview the exchange again."
    case .conflict: return "A different import already occupies this namespace. Nothing was replaced."
    case .missingSource: return "Select the same source folder again to resume this import."
    case .full: return "Review or discard pending imports before adding another exchange."
    }
  }
}

public enum VaultExchangeLimits {
  public static let total = 50 * 1024 * 1024
  public static let records = 16 * 1024 * 1024
  public static let manifest = 256 * 1024
}

public struct ExchangeFile: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case records, raw, asset, review }
  public let path: String
  public let bytes: Int
  public let sha256: String
  public let kind: Kind
}

public struct VaultExchangeManifest: Codable, Equatable, Sendable {
  public let version: Int
  public let format: String
  public let exportID: UUID
  public let createdAt: String
  public let notesCount: Int
  public let reviewsCount: Int
  public let files: [ExchangeFile]
  public let contentSHA256: String
  enum CodingKeys: String, CodingKey {
    case version, format, files
    case exportID = "export_id", createdAt = "created_at", notesCount = "notes_count"
    case reviewsCount = "reviews_count", contentSHA256 = "content_sha256"
  }
  init(notes: Int, reviews: Int, files: [ExchangeFile]) {
    version = 1; format = "daypage-file-exchange-v1"; exportID = UUID()
    createdAt = ExchangeTimestamp.string(Date()); notesCount = notes; reviewsCount = reviews
    self.files = files.sorted(by: Self.fileOrder)
    contentSHA256 = Self.digest(notes: notes, reviews: reviews, files: files)
  }
  public var byteCount: Int { files.reduce(0) { $0 + $1.bytes } }
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= VaultExchangeLimits.manifest else { throw VaultExchangeError.limit }
    try ExchangeStrictJSON.manifest(data)
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate()
    return value
  }
  static func fileOrder(_ a: ExchangeFile, _ b: ExchangeFile) -> Bool {
    a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
  }
  static func digest(notes: Int, reviews: Int, files: [ExchangeFile]) -> String {
    let rows = files.sorted(by: fileOrder).map { "\($0.path)\0\($0.kind.rawValue)\0\($0.bytes)\0\($0.sha256)" }
    return ReplicaDigest.hash(Data(("daypage-file-exchange-v1\n\(notes)\0\(reviews)\n" + rows.joined(separator: "\n")).utf8))
  }
  public func validate() throws {
    guard version == 1, format == "daypage-file-exchange-v1", ExchangeTimestamp.date(createdAt) != nil,
      (0...500).contains(notesCount), (0...100).contains(reviewsCount), notesCount + reviewsCount > 0,
      !files.isEmpty, files.count <= 1000, Set(files.map(\.path)).count == files.count else { throw VaultExchangeError.invalid }
    guard Set(files.map { $0.path.lowercased() }).count == files.count else { throw VaultExchangeError.invalid }
    var total = 0
    for file in files {
      guard file.bytes >= 0, file.bytes <= VaultExchangeLimits.total, ReplicaDigest.valid(file.sha256),
        try ExchangePath.kind(file.path) == file.kind else { throw VaultExchangeError.invalid }
      total += file.bytes
      guard total <= VaultExchangeLimits.total else { throw VaultExchangeError.limit }
      if file.kind == .asset, file.bytes > 25 * 1024 * 1024 { throw VaultExchangeError.limit }
      if file.kind == .records, file.bytes > VaultExchangeLimits.records { throw VaultExchangeError.limit }
      if file.kind == .review, file.bytes > 96 * 1024 { throw VaultExchangeError.limit }
    }
    guard files.filter({ $0.kind == .records }).map(\.path) == ["records.json"],
      contentSHA256 == Self.digest(notes: notesCount, reviews: reviewsCount, files: files) else { throw VaultExchangeError.invalid }
  }
}

public struct ExchangeAttachment: Codable, Equatable, Sendable {
  public let file: String
  public let kind: String
  public let sha256: String
  public let bytes: Int
  public let duration: Double?
  public let transcript: String?
  public let transcriptionStatus: String?
  enum CodingKeys: String, CodingKey {
    case file, kind, sha256, bytes, duration, transcript
    case transcriptionStatus = "transcription_status"
  }
}

public struct ExchangeNote: Codable, Equatable, Sendable {
  public let originalID: UUID
  public let namespace: String
  public let day: String
  public let revision: String
  public let type: String
  public let body: String
  public let createdAt: String
  public let location: Memo.Location?
  public let weather: String?
  public let device: String?
  public let mood: String?
  public let marginNote: String?
  public let pinnedAt: String?
  public let entityMentions: [String]
  public let attachments: [ExchangeAttachment]
  enum CodingKeys: String, CodingKey {
    case namespace, day, revision, type, body, location, weather, device, mood, attachments
    case originalID = "original_id", createdAt = "created_at", marginNote = "margin_note"
    case pinnedAt = "pinned_at", entityMentions = "entity_mentions"
  }
  var identity: String { namespace + "/" + originalID.uuidString }
  init(entry: NotebookEntry, attachments: [ExchangeAttachment]) throws {
    let memo = entry.memo
    originalID = memo.id; namespace = try ExchangeNamespace.path(entry.namespace); day = entry.day; revision = entry.revision
    type = memo.type.rawValue; body = memo.body; createdAt = ExchangeTimestamp.string(memo.created)
    location = memo.location; weather = memo.weather; device = memo.device; mood = memo.mood
    marginNote = memo.marginNote; pinnedAt = memo.pinnedAt.map(ExchangeTimestamp.string)
    entityMentions = memo.entityMentions; self.attachments = attachments
  }
  func equivalent(to other: Self) -> Bool {
    originalID == other.originalID && namespace == other.namespace && day == other.day && revision == other.revision
      && type == other.type && body == other.body && location == other.location && weather == other.weather
      && device == other.device && mood == other.mood && marginNote == other.marginNote
      && entityMentions == other.entityMentions && attachments == other.attachments
      && ExchangeTimestamp.date(createdAt) == ExchangeTimestamp.date(other.createdAt)
      && pinnedAt.flatMap(ExchangeTimestamp.date) == other.pinnedAt.flatMap(ExchangeTimestamp.date)
  }
}

public struct ExchangeReview: Codable, Equatable, Sendable {
  public let generationID: UUID
  public let namespace: String
  public let file: String
  public let periodKind: String
  public let start: String
  public let end: String
  public let timeZone: String
  public let createdAt: String
  public let sourceDigest: String
  public let sources: [ReviewCitation]
  public let body: String
  enum CodingKeys: String, CodingKey {
    case namespace, file, start, end, sources, body
    case generationID = "generation_id", periodKind = "period_kind", timeZone = "time_zone"
    case createdAt = "created_at", sourceDigest = "source_digest"
  }
  init(_ record: SavedManualReview, file: String) throws {
    let page = record.page
    generationID = page.id; namespace = try ExchangeNamespace.path(record.namespace); self.file = file
    periodKind = page.period.kind.rawValue; start = ExchangeTimestamp.string(page.period.start)
    end = ExchangeTimestamp.string(page.period.end); timeZone = page.period.timeZoneID
    createdAt = ExchangeTimestamp.string(page.created); sourceDigest = page.sourceDigest
    sources = try page.citations.map { source in
      let logical = record.namespace.isEmpty ? source.namespace
        : record.namespace + (source.namespace.isEmpty ? "" : "/" + source.namespace)
      let namespace = try ExchangeNamespace.path(logical)
      return ReviewCitation(id: "\(namespace)/\(source.day)/\(source.memoID.uuidString)", namespace: namespace,
        memoID: source.memoID, day: source.day, revision: source.revision)
    }
    body = page.body
  }
  var identity: String { namespace + "/" + generationID.uuidString }
}

public struct ExchangeRecords: Codable, Equatable, Sendable {
  public let version: Int
  public let notes: [ExchangeNote]
  public let reviews: [ExchangeReview]
  public init(notes: [ExchangeNote], reviews: [ExchangeReview]) { version = 1; self.notes = notes; self.reviews = reviews }
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= VaultExchangeLimits.records else { throw VaultExchangeError.limit }
    try ExchangeStrictJSON.records(data)
    return try JSONDecoder().decode(Self.self, from: data)
  }
}

public struct VaultExchangeSnapshot: Sendable {
  public let manifest: VaultExchangeManifest
  public let records: ExchangeRecords
  public let files: [String: Data]
  public func validated() throws {
    try manifest.validate()
    guard records.version == 1, records.notes.count == manifest.notesCount, records.reviews.count == manifest.reviewsCount,
      Set(records.notes.map(\.identity)).count == records.notes.count,
      Set(records.reviews.map(\.identity)).count == records.reviews.count,
      Set(files.keys) == Set(manifest.files.map(\.path)) else { throw VaultExchangeError.invalid }
    for file in manifest.files {
      guard let data = files[file.path], data.count == file.bytes, ReplicaDigest.hash(data) == file.sha256 else { throw VaultExchangeError.changed }
    }
    guard let data = files["records.json"], try ExchangeRecords.decode(data) == records else { throw VaultExchangeError.invalid }
    let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
    let referencedAssets = Set(records.notes.flatMap { $0.attachments.map(\.file) })
    let referencedRaw = Set(records.notes.map { ($0.namespace.isEmpty ? "" : $0.namespace + "/") + "raw/\($0.day).md" })
    guard Set(manifest.files.filter { $0.kind == .asset }.map(\.path)) == referencedAssets,
      Set(manifest.files.filter { $0.kind == .raw }.map(\.path)) == referencedRaw,
      Set(manifest.files.filter { $0.kind == .review }.map(\.path)) == Set(records.reviews.map(\.file)) else {
      throw VaultExchangeError.invalid
    }
    for note in records.notes {
      let logical = try ExchangeNamespace.logical(note.namespace)
      let citation = ReviewCitation(id: "\(logical)/\(note.day)/\(note.originalID.uuidString)", namespace: logical,
        memoID: note.originalID, day: note.day, revision: note.revision)
      try citation.validate()
      let prefix = note.namespace.isEmpty ? "" : note.namespace + "/"
      guard byPath[prefix + "raw/\(note.day).md"]?.kind == .raw,
        Memo.MemoType(rawValue: note.type) != nil, ExchangeTimestamp.date(note.createdAt) != nil,
        note.pinnedAt.map({ ExchangeTimestamp.date($0) != nil }) ?? true,
        note.body.utf8.count <= 4 * 1024 * 1024, note.attachments.count <= 10,
        note.entityMentions.count <= 1000, note.entityMentions.allSatisfy({ $0.count <= 1000 }) else { throw VaultExchangeError.invalid }
      if let location = note.location {
        guard ((location.lat == nil && location.lng == nil) || location.hasValidCoordinates),
          (location.name?.count ?? 0) <= 1000 else { throw VaultExchangeError.invalid }
      }
      for attachment in note.attachments {
        guard ["photo", "audio", "file"].contains(attachment.kind),
          let asset = byPath[attachment.file], asset.kind == .asset, asset.bytes == attachment.bytes,
          asset.sha256 == attachment.sha256, attachment.bytes > 0,
          attachment.file.hasPrefix(prefix + "raw/assets/"),
          attachment.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
          (attachment.transcript?.utf8.count ?? 0) <= 4 * 1024 * 1024,
          attachment.transcriptionStatus.map({ ["pending", "done", "failed"].contains($0) }) ?? true else { throw VaultExchangeError.invalid }
      }
    }
    for review in records.reviews {
      guard byPath[review.file]?.kind == .review, let data = files[review.file] else { throw VaultExchangeError.invalid }
      guard review.file.split(separator: "/").dropLast(3).joined(separator: "/") == review.namespace else { throw VaultExchangeError.invalid }
      let page = try ManualReviewPage.decode(data)
      guard try ExchangeReview(SavedManualReview(namespace: ExchangeNamespace.logical(review.namespace), page: page), file: review.file) == review else { throw VaultExchangeError.invalid }
    }
  }
}

enum ExchangeTimestamp {
  static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
  static func date(_ text: String) -> Date? {
    guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: text)
  }
}

private enum ExchangeStrictJSON {
  static func object(_ value: Any, allowed: Set<String>, required: Set<String>) throws -> [String: Any] {
    guard let value = value as? [String: Any], Set(value.keys).isSubset(of: allowed),
      Set(value.keys).isSuperset(of: required) else { throw VaultExchangeError.invalid }
    return value
  }
  static func root(_ data: Data) throws -> Any {
    let value = try JSONSerialization.jsonObject(with: data)
    func rejectNull(_ value: Any) throws {
      if value is NSNull { throw VaultExchangeError.invalid }
      if let object = value as? [String: Any] { for item in object.values { try rejectNull(item) } }
      if let array = value as? [Any] { for item in array { try rejectNull(item) } }
    }
    try rejectNull(value)
    return value
  }
  static func manifest(_ data: Data) throws {
    let keys: Set<String> = ["version", "format", "export_id", "created_at", "notes_count", "reviews_count", "files", "content_sha256"]
    let value = try object(root(data), allowed: keys, required: keys)
    guard let files = value["files"] as? [Any], files.count <= 1000 else { throw VaultExchangeError.invalid }
    for file in files {
      let keys: Set<String> = ["path", "bytes", "sha256", "kind"]
      _ = try object(file, allowed: keys, required: keys)
    }
  }
  static func records(_ data: Data) throws {
    let value = try object(root(data), allowed: ["version", "notes", "reviews"], required: ["version", "notes", "reviews"])
    guard let notes = value["notes"] as? [Any], let reviews = value["reviews"] as? [Any],
      notes.count <= 500, reviews.count <= 100 else { throw VaultExchangeError.invalid }
    for note in notes {
      let required: Set<String> = ["original_id", "namespace", "day", "revision", "type", "body", "created_at", "entity_mentions", "attachments"]
      let note = try object(note, allowed: required.union(["location", "weather", "device", "mood", "margin_note", "pinned_at"]), required: required)
      if let location = note["location"] { _ = try object(location, allowed: ["name", "lat", "lng"], required: []) }
      guard let assets = note["attachments"] as? [Any], assets.count <= 10 else { throw VaultExchangeError.invalid }
      for asset in assets {
        _ = try object(asset, allowed: ["file", "kind", "sha256", "bytes", "duration", "transcript", "transcription_status"],
          required: ["file", "kind", "sha256", "bytes"])
      }
    }
    for review in reviews {
      let keys: Set<String> = ["generation_id", "namespace", "file", "period_kind", "start", "end", "time_zone", "created_at", "source_digest", "sources", "body"]
      let review = try object(review, allowed: keys, required: keys)
      guard let sources = review["sources"] as? [Any], sources.count <= 12 else { throw VaultExchangeError.invalid }
      for source in sources {
        let keys: Set<String> = ["id", "namespace", "memo_id", "day", "revision"]
        _ = try object(source, allowed: keys, required: keys)
      }
    }
  }
}

enum ExchangePath {
  static func kind(_ path: String) throws -> ExchangeFile.Kind {
    guard path.utf8.count <= 512, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VaultExchangeError.invalid }
    var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw VaultExchangeError.invalid }
    if path == "records.json" { return .records }
    var depth = 0
    while parts.first == "imports" {
      guard parts.count > 2, UUID(uuidString: parts[1]) != nil, depth < 16 else { throw VaultExchangeError.invalid }
      parts.removeFirst(2); depth += 1
    }
    if parts.count == 2, parts[0] == "raw",
      parts[1].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}\\.md$", options: .regularExpression) != nil { return .raw }
    if parts.count >= 3, parts[0] == "raw", parts[1] == "assets" { return .asset }
    if parts.count == 3, parts[0] == "wiki", parts[1] == "manual-reviews", parts[2].hasSuffix(".md"),
      UUID(uuidString: String(parts[2].dropLast(3))) != nil { return .review }
    throw VaultExchangeError.invalid
  }
}

enum ExchangeNamespace {
  static func path(_ logical: String) throws -> String {
    guard !logical.isEmpty else { return "" }
    let parts = logical.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 16, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else { throw VaultExchangeError.invalid }
    let path = parts.map { "imports/" + String($0) }.joined(separator: "/")
    guard path.utf8.count <= 400 else { throw VaultExchangeError.limit }
    return path
  }
  static func logical(_ physical: String) throws -> String {
    guard !physical.isEmpty else { return "" }
    guard physical.utf8.count <= 400 else { throw VaultExchangeError.limit }
    let parts = physical.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count.isMultiple(of: 2), parts.count <= 32 else { throw VaultExchangeError.invalid }
    var logical: [String] = []
    for index in stride(from: 0, to: parts.count, by: 2) {
      guard parts[index] == "imports", UUID(uuidString: String(parts[index + 1])) != nil else { throw VaultExchangeError.invalid }
      logical.append(String(parts[index + 1]))
    }
    return logical.joined(separator: "/")
  }
}
