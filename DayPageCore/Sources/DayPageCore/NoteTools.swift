import CoreFoundation
import Foundation

/// All entries must already be filtered by the host's explicit conversation scope.
/// Attachment access is by a validated card identity and index, never a model-supplied path.
public struct NoteToolContext: Sendable {
  public typealias AttachmentReader = @Sendable (String, Int) async throws -> String
  public let entries: [NotebookEntry]
  public let attachmentReader: AttachmentReader?
  public init(entries: [NotebookEntry], attachmentReader: AttachmentReader? = nil) {
    self.entries = entries
    self.attachmentReader = attachmentReader
  }
}

public struct NoteToolSource: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let cardRef: String
  public let day: String
  public let snippet: String
  public var id: String { cardRef }
  public init(cardRef: String, day: String, snippet: String) {
    self.cardRef = cardRef
    self.day = day
    self.snippet = String(snippet.prefix(360))
  }
}

public struct NoteToolResult: Equatable, Sendable {
  public let content: String
  public let sources: [NoteToolSource]
  public let isError: Bool
}

/// A closed set of bounded read-only operations. It holds no file or vault capability.
public enum NoteToolExecutor {
  public static let names = ["notes_search", "notes_read", "notes_list", "notes_stats", "notes_tags", "assets_read"]
  private static let maximumText = 6000

  public static func execute(name: String, arguments: String, context: NoteToolContext) async throws -> NoteToolResult {
    try Task.checkCancellation()
    guard names.contains(name) else { return try failure("unknown_tool") }
    guard arguments.utf8.count <= 16 * 1024,
      let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
    else { return try failure("invalid_arguments") }
    do {
      let allowed: Set<String>
      switch name {
      case "notes_search": allowed = ["query", "from_day", "to_day", "tag", "limit"]
      case "notes_read": allowed = ["card_ref", "max_characters"]
      case "assets_read": allowed = ["card_ref", "attachment_index", "max_characters"]
      case "notes_stats": allowed = ["from_day", "to_day", "tag"]
      case "notes_tags": allowed = ["from_day", "to_day", "limit"]
      default: allowed = ["from_day", "to_day", "tag", "limit"]
      }
      guard Set(args.keys).isSubset(of: allowed) else { throw ArgumentError.invalid }
      if name == "notes_read" || name == "assets_read" {
        let ref = try string("card_ref", in: args, required: true, maximum: 1024)
        let matches = context.entries.filter { $0.id == ref }
        guard matches.count == 1, let entry = matches.first else { return try failure("card_not_in_scope") }
        let limit = try integer("max_characters", in: args, fallback: maximumText, range: 1...maximumText)
        if name == "notes_read" {
          let body = String(entry.memo.body.prefix(limit))
          let assets: [[String: Any]] = entry.memo.attachments.enumerated().prefix(10).map { index, asset in
            ["index": index, "kind": String(asset.kind.prefix(32)), "has_transcript": asset.transcript?.isEmpty == false]
          }
          return try result(["card_ref": entry.id, "day": entry.day, "body": body,
            "truncated": entry.memo.body.count > body.count, "attachments": assets,
            "attachment_count": entry.memo.attachments.count], sources: [source(entry)])
        }
        let index = try integer("attachment_index", in: args, range: 0...9)
        guard entry.memo.attachments.indices.contains(index) else { return try failure("attachment_not_in_scope") }
        guard let reader = context.attachmentReader else { return try failure("attachment_reading_unavailable") }
        try Task.checkCancellation()
        let extracted: String
        do { extracted = try await reader(entry.id, index) }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return try failure("attachment_unreadable") }
        try Task.checkCancellation()
        let text = String(extracted.prefix(limit))
        return try result(["card_ref": entry.id, "day": entry.day, "attachment_index": index,
          "text": text, "truncated": extracted.count > text.count],
          sources: [NoteToolSource(cardRef: entry.id, day: entry.day, snippet: text)])
      }

      let from = try day("from_day", in: args)
      let to = try day("to_day", in: args)
      guard from == nil || to == nil || (from ?? "") <= (to ?? "") else { throw ArgumentError.invalid }
      let tag = try string("tag", in: args, maximum: 256)
      let entries = context.entries.filter { entry in
        (from.map { entry.day >= $0 } ?? true) && (to.map { entry.day <= $0 } ?? true)
          && (tag.map { NotebookCatalog.tags(in: entry.memo.body).contains($0) } ?? true)
      }.sorted { a, b in
        if a.day != b.day { return a.day > b.day }
        if a.memo.created != b.memo.created { return a.memo.created > b.memo.created }
        return a.id < b.id
      }
      try Task.checkCancellation()
      switch name {
      case "notes_stats":
        return try result(["card_count": entries.count, "day_count": Set(entries.map(\.day)).count,
          "attachment_count": entries.reduce(0) { $0 + $1.memo.attachments.count },
          "character_count": entries.reduce(0) { $0 + $1.memo.body.count },
          "first_day": entries.last?.day as Any? ?? NSNull(), "last_day": entries.first?.day as Any? ?? NSNull()])
      case "notes_tags":
        let limit = try integer("limit", in: args, fallback: 20, range: 1...100)
        var counts: [String: Int] = [:]
        for entry in entries {
          for tag in NotebookCatalog.tags(in: entry.memo.body) { counts[tag, default: 0] += 1 }
        }
        let ranked = counts.keys.sorted { a, b in counts[a] == counts[b] ? a < b : counts[a, default: 0] > counts[b, default: 0] }
        // Long tag names are quoted with an explicit truncation marker; counts remain exact.
        let tags: [[String: Any]] = ranked.prefix(limit).map {
          ["tag": String($0.prefix(256)), "tag_truncated": $0.count > 256, "card_count": counts[$0, default: 0]]
        }
        return try result(["tags": tags, "total": counts.count, "truncated": counts.count > tags.count])
      default:
        let limit = try integer("limit", in: args, fallback: 10, range: 1...20)
        let query = name == "notes_search" ? try string("query", in: args, required: true, maximum: 256) : nil
        let matches = entries.filter { entry in
          guard let query else { return true }
          return entry.memo.body.localizedCaseInsensitiveContains(query)
            || entry.memo.attachments.contains { $0.transcript?.localizedCaseInsensitiveContains(query) == true }
        }
        let selected = Array(matches.prefix(limit))
        let sources = selected.map { source($0, query: query) }
        let cards: [[String: Any]] = zip(selected, sources).map { entry, source in
          ["card_ref": entry.id, "day": entry.day, "snippet": source.snippet,
            "attachment_count": entry.memo.attachments.count]
        }
        return try result(["cards": cards, "total": matches.count, "truncated": matches.count > selected.count], sources: sources)
      }
    } catch is ArgumentError { return try failure("invalid_arguments") }
  }

  private enum ArgumentError: Error { case invalid }
  private static func string(_ key: String, in args: [String: Any], required: Bool = false, maximum: Int) throws -> String? {
    guard let value = args[key] else {
      if required { throw ArgumentError.invalid }; return nil
    }
    guard let raw = value as? String else { throw ArgumentError.invalid }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= maximum else { throw ArgumentError.invalid }
    return text
  }
  private static func integer(_ key: String, in args: [String: Any], fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int {
    guard let value = args[key] else {
      guard let fallback else { throw ArgumentError.invalid }; return fallback
    }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound)
    else { throw ArgumentError.invalid }
    return number.intValue
  }
  private static func day(_ key: String, in args: [String: Any]) throws -> String? {
    guard let text = try string(key, in: args, maximum: 10) else { return nil }
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw ArgumentError.invalid }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    guard let date = formatter.date(from: text), formatter.string(from: date) == text else { throw ArgumentError.invalid }
    return text
  }
  private static func source(_ entry: NotebookEntry, query: String? = nil) -> NoteToolSource {
    var text = entry.memo.body
    if let query {
      if !text.localizedCaseInsensitiveContains(query), let transcript = entry.memo.attachments.compactMap(\.transcript).first(where: { $0.localizedCaseInsensitiveContains(query) }) {
        text = transcript
      }
      if let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        let start = text.index(match.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        text = String(text[start...].prefix(360))
      }
    }
    return NoteToolSource(cardRef: entry.id, day: entry.day, snippet: text)
  }
  private static func failure(_ code: String) throws -> NoteToolResult {
    try result(["error": code], isError: true)
  }
  private static func result(_ object: [String: Any], sources: [NoteToolSource] = [], isError: Bool = false) throws -> NoteToolResult {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard data.count <= 128 * 1024 else { throw AIError.tooLarge }
    return NoteToolResult(content: String(decoding: data, as: UTF8.self), sources: sources, isError: isError)
  }

  /// Schema is shared by the three wire dialects; runtime validation remains authoritative.
  static var definitions: [(name: String, description: String, schema: [String: Any])] {
    let day: [String: Any] = ["type": "string", "description": "Inclusive date in YYYY-MM-DD format", "pattern": #"^\d{4}-\d{2}-\d{2}$"#]
    let ref: [String: Any] = ["type": "string", "description": "Exact complete card_ref returned by search/list; includes namespace, day and UUID. Never a filesystem path.", "maxLength": 1024]
    let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 20]
    let characters: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 6000]
    let filter: [String: Any] = ["from_day": day, "to_day": day, "tag": ["type": "string", "maxLength": 256]]
    func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
      ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    var search = filter; search["query"] = ["type": "string", "minLength": 1, "maxLength": 256]; search["limit"] = limit
    var list = filter; list["limit"] = limit
    return [
      ("notes_search", "Search only authorized cards and their existing transcripts by a nonempty phrase. No matches returns an empty cards array, never unrelated cards. Results include complete card_ref and snippets; use notes_read for more text.", schema(search, required: ["query"])),
      ("notes_read", "Read bounded text and attachment metadata from one authorized card, using its complete card_ref.", schema(["card_ref": ref, "max_characters": characters], required: ["card_ref"])),
      ("notes_list", "List authorized cards newest day first, optionally within an inclusive date range or exact hashtag. total is the exact count before the result limit.", schema(list)),
      ("notes_stats", "Count all authorized matching cards, distinct days, attachments and body characters exactly. Counts apply before any presentation limit. No dates means the full authorized scope, not the whole vault.", schema(filter)),
      ("notes_tags", "List hashtags with exact distinct-card counts across authorized cards, optionally within a date range. Repeated hashtags in one card count once. Results are bounded.", schema(["from_day": day, "to_day": day, "limit": ["type": "integer", "minimum": 1, "maximum": 100]])),
      ("assets_read", "Read bounded extracted text from one attachment of an authorized card. Use a complete card_ref and zero-based attachment_index, never a path. Unsupported or unavailable extraction returns an error.", schema(["card_ref": ref, "attachment_index": ["type": "integer", "minimum": 0, "maximum": 9], "max_characters": characters], required: ["card_ref", "attachment_index"]))
    ]
  }
}
