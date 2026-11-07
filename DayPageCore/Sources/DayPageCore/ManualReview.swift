import DayPageCapture
import Foundation

public enum ManualReviewError: LocalizedError {
  case range, selection, limit, changed, consent, revoked, page, conflict
  public var errorDescription: String? {
    switch self {
    case .range: return "Choose a valid local day or week."
    case .selection: return "Select the exact notes to use for this review."
    case .limit: return "Use up to 12 notes and 18,000 characters. Nothing was sent."
    case .changed: return "A selected source changed. Preview the sources again before continuing."
    case .consent: return "Enable this review request before generating."
    case .revoked: return "This review was cancelled. Start a new preview to continue."
    case .page: return "This review page could not be read. Its original file was preserved."
    case .conflict: return "A different page already uses this identity. Existing files were preserved."
    }
  }
}

public struct ReviewPeriod: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case day, week }
  public let kind: Kind
  public let timeZoneID: String
  public let start: Date
  public let end: Date
  public init(kind: Kind, anchor: Date, timeZone: TimeZone) throws {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = timeZone
    calendar.firstWeekday = 2
    guard anchor.timeIntervalSince1970.isFinite,
      let interval = calendar.dateInterval(of: kind == .day ? .day : .weekOfYear, for: anchor) else {
      throw ManualReviewError.range
    }
    self.kind = kind; timeZoneID = timeZone.identifier
    start = interval.start; end = interval.end
  }
  public func contains(_ date: Date) -> Bool { date >= start && date < end }
  public var firstDay: String { dayString(start) }
  public var lastDay: String { dayString(end.addingTimeInterval(-1)) }
  public var title: String { kind == .day ? firstDay : firstDay + " – " + lastDay }
  func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: timeZoneID)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
  private func dayString(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: timeZoneID); formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
  func validate() throws {
    guard let zone = TimeZone(identifier: timeZoneID),
      try ReviewPeriod(kind: kind, anchor: start, timeZone: zone) == self else { throw ManualReviewError.range }
  }
}

public struct ReviewCitation: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let namespace: String
  public let memoID: UUID
  public let day: String
  public let revision: String
  enum CodingKeys: String, CodingKey { case id, namespace, day, revision; case memoID = "memo_id" }
  init(id: String, namespace: String, memoID: UUID, day: String, revision: String) {
    self.id = id; self.namespace = namespace; self.memoID = memoID; self.day = day; self.revision = revision
  }
  init(_ entry: NotebookEntry) {
    id = entry.id; namespace = entry.namespace; memoID = entry.memo.id
    day = entry.day; revision = entry.revision
  }
  func validate() throws {
    let parts = namespace.split(separator: "/", omittingEmptySubsequences: false)
    if !namespace.isEmpty {
      guard parts.count <= 16, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else { throw ManualReviewError.page }
    }
    guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
      id == "\(namespace)/\(day)/\(memoID.uuidString)", ReplicaDigest.valid(revision) else { throw ManualReviewError.page }
  }
}

public struct ManualReviewSnapshot: Sendable {
  public let period: ReviewPeriod
  public let entries: [NotebookEntry]
  public let citations: [ReviewCitation]
  public let contextText: String
  public let digest: String
  public static func make(period: ReviewPeriod, entries: [NotebookEntry], selectedIDs: Set<String>) throws -> Self {
    try period.validate()
    guard !selectedIDs.isEmpty, selectedIDs.count <= 12 else { throw ManualReviewError.selection }
    let selected = entries.filter { selectedIDs.contains($0.id) }
      .sorted { $0.memo.created == $1.memo.created ? $0.id < $1.id : $0.memo.created < $1.memo.created }
    guard selected.count == selectedIDs.count, Set(selected.map(\.id)).count == selected.count,
      selected.allSatisfy({ period.contains($0.memo.created) }),
      selected.contains(where: { !$0.memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw ManualReviewError.selection }
    struct Source: Codable { let source: String; let date: String; let note: String }
    let sources = selected.enumerated().map { Source(source: "S\($0.offset + 1)", date: period.timestamp($0.element.memo.created), note: $0.element.memo.body) }
    let data = try ReplicaDigest.encode(sources)
    guard let text = String(data: data, encoding: .utf8), text.count <= 18_000, data.count <= 72 * 1024 else {
      throw ManualReviewError.limit
    }
    let citations = selected.map(ReviewCitation.init)
    for citation in citations { try citation.validate() }
    struct Identity: Codable { let period: ReviewPeriod; let citations: [ReviewCitation]; let text: String }
    let digest = ReplicaDigest.hash(try ReplicaDigest.encode(Identity(period: period, citations: citations, text: text)))
    return Self(period: period, entries: selected, citations: citations, contextText: text, digest: digest)
  }
  public func validate(against entries: [NotebookEntry]) throws {
    guard let current = try? Self.make(period: period, entries: entries, selectedIDs: Set(citations.map(\.id))),
      current.digest == digest else { throw ManualReviewError.changed }
  }
  var context: NoteContext { NoteContext(entries: entries, text: contextText) }
}

public struct ManualReviewPage: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let created: Date
  public let period: ReviewPeriod
  public let citations: [ReviewCitation]
  public let sourceDigest: String
  public let body: String
  init(id: UUID, created: Date, snapshot: ManualReviewSnapshot, body: String) {
    self.id = id; self.created = created; period = snapshot.period
    citations = snapshot.citations; sourceDigest = snapshot.digest; self.body = body
  }
  private struct Metadata: Codable {
    let version: Int; let id: UUID; let created: Date; let period: ReviewPeriod
    let citations: [ReviewCitation]; let sourceDigest: String; let bodyBytes: Int; let bodyDigest: String
  }
  private var footer: String {
    "\n\n## Sources\n" + citations.enumerated().map { index, source in
      let prefix = source.namespace.isEmpty ? "" : source.namespace.split(separator: "/").map { "imports/" + String($0) }.joined(separator: "/") + "/"
      return "- S\(index + 1): [\(source.day)](../../\(prefix)raw/\(source.day).md) · \(source.memoID.uuidString)"
    }.joined(separator: "\n") + "\n"
  }
  public func encoded() throws -> Data {
    try period.validate()
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 64 * 1024,
      created.timeIntervalSince1970.isFinite, citations.count > 0, citations.count <= 12,
      Set(citations.map(\.id)).count == citations.count, ReplicaDigest.valid(sourceDigest) else { throw ManualReviewError.page }
    for citation in citations { try citation.validate() }
    let content = Data(body.utf8)
    let metadata = Metadata(version: 1, id: id, created: created, period: period, citations: citations,
      sourceDigest: sourceDigest, bodyBytes: content.count, bodyDigest: ReplicaDigest.hash(content))
    let header = "---\ntype: manual_\(period.kind.rawValue)_review\ndaypage_review: "
      + (try ReplicaDigest.encode(metadata)).base64EncodedString() + "\n---\n\n"
    let encoded = Data((header + body + footer).utf8)
    guard encoded.count <= 96 * 1024 else { throw ManualReviewError.page }
    return encoded
  }
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= 96 * 1024, let text = String(data: data, encoding: .utf8),
      text.hasPrefix("---\ntype: manual_"), let boundary = text.range(of: "\n---\n\n"),
      boundary.lowerBound < text.index(text.startIndex, offsetBy: min(text.count, 24 * 1024)),
      let line = text[..<boundary.lowerBound].split(separator: "\n").first(where: { $0.hasPrefix("daypage_review: ") }),
      let metadataBytes = Data(base64Encoded: String(line.dropFirst("daypage_review: ".count))),
      let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataBytes), metadata.version == 1,
      metadata.bodyBytes > 0, metadata.bodyBytes <= 64 * 1024 else { throw ManualReviewError.page }
    let payload = Data(text[boundary.upperBound...].utf8)
    guard payload.count >= metadata.bodyBytes,
      let body = String(data: payload.prefix(metadata.bodyBytes), encoding: .utf8),
      ReplicaDigest.hash(Data(body.utf8)) == metadata.bodyDigest else { throw ManualReviewError.page }
    let page = Self(id: metadata.id, created: metadata.created, period: metadata.period,
      citations: metadata.citations, sourceDigest: metadata.sourceDigest, body: body)
    guard try page.encoded() == data else { throw ManualReviewError.page }
    return page
  }
  private init(id: UUID, created: Date, period: ReviewPeriod, citations: [ReviewCitation], sourceDigest: String, body: String) {
    self.id = id; self.created = created; self.period = period; self.citations = citations
    self.sourceDigest = sourceDigest; self.body = body
  }
}

public struct SavedManualReview: Identifiable, Sendable {
  public let namespace: String
  public let page: ManualReviewPage
  public var id: String { namespace + "/" + page.id.uuidString }
  public init(namespace: String, page: ManualReviewPage) { self.namespace = namespace; self.page = page }
}
