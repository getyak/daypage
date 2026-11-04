import CoreFoundation
import Foundation

/// All entries must already be filtered by the host's explicit conversation scope.
/// Attachment access is by a validated card identity and index, never a model-supplied path.
public struct NoteToolContext: Sendable {
  public typealias AttachmentReader = @Sendable (String, Int) async throws -> String
  public typealias ProposalWriter = @Sendable (NoteActionProposal) async throws -> Void
  public let entries: [NotebookEntry]
  public let attachmentReader: AttachmentReader?
  public let relations: [NoteRelation]
  public let proposalWriter: ProposalWriter?
  public let proposalNamespace: UUID
  public let proposalCreatedAt: Date
  public init(entries: [NotebookEntry], attachmentReader: AttachmentReader? = nil,
              relations: [NoteRelation] = [], proposalWriter: ProposalWriter? = nil,
              proposalNamespace: UUID = UUID(), proposalCreatedAt: Date = Date()) {
    self.entries = entries
    self.attachmentReader = attachmentReader
    self.relations = relations; self.proposalWriter = proposalWriter
    self.proposalNamespace = proposalNamespace
    self.proposalCreatedAt = proposalCreatedAt
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
  public let proposals: [NoteActionProposal]
  public init(content: String, sources: [NoteToolSource] = [], isError: Bool = false,
              proposals: [NoteActionProposal] = []) {
    self.content = content; self.sources = sources; self.isError = isError; self.proposals = proposals
  }
}

/// Bounded reads and reviewable proposals. It has no capability to commit raw changes.
public enum NoteToolExecutor {
  public static let names = ["notes_search", "notes_read", "notes_list", "notes_stats", "notes_tags", "assets_read",
    "notes_create", "notes_append", "notes_propose_patch", "notes_similar", "notes_neighbors",
    "notes_find_duplicates", "relations_suggest", "relations_list", "relations_link", "relations_unlink",
    "notes_set_tags", "notes_set_pin"]
  private static let maximumText = 6000

  public static func execute(name: String, arguments: String, context: NoteToolContext) async throws -> NoteToolResult {
    try Task.checkCancellation()
    guard names.contains(name) else { return try failure("unknown_tool") }
    guard arguments.utf8.count <= 16 * 1024,
      let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
    else { return try failure("invalid_arguments") }
    do {
      if names.dropFirst(6).contains(name) { return try await extended(name, args: args, context: context) }
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
  private static func result(_ object: [String: Any], sources: [NoteToolSource] = [], isError: Bool = false,
                             proposals: [NoteActionProposal] = []) throws -> NoteToolResult {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard data.count <= 128 * 1024 else { throw AIError.tooLarge }
    return NoteToolResult(content: String(decoding: data, as: UTF8.self), sources: sources, isError: isError, proposals: proposals)
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
    ] + authoringDefinitions
  }
}

extension NoteToolExecutor {
  private static func extended(_ name: String, args: [String: Any], context: NoteToolContext) async throws -> NoteToolResult {
    let keys: Set<String>
    switch name {
    case "notes_create": keys = ["body"]
    case "notes_append": keys = ["card_ref", "body"]
    case "notes_propose_patch": keys = ["card_ref", "before", "after"]
    case "notes_set_tags": keys = ["card_ref", "tags"]
    case "notes_set_pin": keys = ["card_ref", "pinned"]
    case "notes_similar": keys = ["card_ref", "query", "limit"]
    case "notes_neighbors", "notes_find_duplicates", "relations_suggest", "relations_list": keys = ["card_ref", "limit"]
    case "relations_link": keys = ["from_card_ref", "to_card_ref", "type", "reason"]
    case "relations_unlink": keys = ["relation_id"]
    default: throw ArgumentError.invalid
    }
    guard Set(args.keys).isSubset(of: keys) else { throw ArgumentError.invalid }
    func entry(_ key: String) throws -> NotebookEntry {
      let ref = try string(key, in: args, required: true, maximum: 1024)
      let matches = context.entries.filter { $0.id == ref }
      guard matches.count == 1, let match = matches.first else { throw NoteActionError.outOfScope }
      return match
    }
    func text(_ key: String, allowEmpty: Bool = false, maximum: Int = 6000) throws -> String {
      guard let value = args[key] as? String, value.count <= maximum,
        !value.contains("\n\n<!-- daypage-memo-separator -->\n\n"),
        allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw ArgumentError.invalid }
      return value
    }
    func proposed(_ kind: NoteActionKind, target: NotebookEntry? = nil, body: String? = nil,
                  before: String? = nil, after: String? = nil, tags: [String]? = nil,
                  pinned: Bool? = nil, relation: NoteRelation? = nil) throws -> NoteActionProposal {
      let canonical = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes])
      let identity = context.proposalNamespace.uuidString + "\n" + name + "\n" + String(decoding: canonical, as: UTF8.self)
        + "\n" + (target?.revision ?? "") + "\n" + (relation?.fromRevision ?? "") + "\n" + (relation?.toRevision ?? "")
      return NoteActionProposal(id: NoteActionIdentity.uuid(identity), kind: kind, createdAt: context.proposalCreatedAt,
        target: target.map { source($0) }, expectedRevision: target?.revision,
        body: body, before: before, after: after, tags: tags, pinned: pinned, relation: relation)
    }
    func pending(_ proposal: NoteActionProposal) async throws -> NoteToolResult {
      try Task.checkCancellation()
      if let writer = context.proposalWriter {
        do { try await writer(proposal) }
        catch is CancellationError { throw CancellationError() }
        catch { return try failure("proposal_storage_unavailable") }
      }
      try Task.checkCancellation()
      let data = try JSONEncoder().encode(proposal)
      let object = try JSONSerialization.jsonObject(with: data)
      return try result(["status": "pending_confirmation", "proposal": object],
        sources: proposal.relation.map { [$0.from, $0.to] } ?? proposal.target.map { [$0] } ?? [], proposals: [proposal])
    }
    do {
      switch name {
      case "notes_create": return try await pending(proposed(.create, body: text("body")))
      case "notes_append": return try await pending(proposed(.append, target: entry("card_ref"), body: text("body")))
      case "notes_propose_patch":
        let target = try entry("card_ref"), before = try text("before"), after = try text("after", allowEmpty: true)
        guard target.memo.body.components(separatedBy: before).count == 2 else { return try failure("patch_not_unambiguous") }
        return try await pending(proposed(.patch, target: target, before: before, after: after))
      case "notes_set_tags":
        let target = try entry("card_ref")
        guard let tags = args["tags"] as? [String], tags.count <= 20,
          tags.allSatisfy({ $0.range(of: #"^[\p{L}\p{N}_-]{1,64}$"#, options: .regularExpression) != nil })
        else { throw ArgumentError.invalid }
        return try await pending(proposed(.setTags, target: target, tags: Array(Set(tags)).sorted()))
      case "notes_set_pin":
        guard let number = args["pinned"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ArgumentError.invalid }
        return try await pending(proposed(.setPin, target: entry("card_ref"), pinned: number.boolValue))
      case "relations_link":
        let from = try entry("from_card_ref"), to = try entry("to_card_ref")
        guard from.id != to.id,
          let type = NoteRelationType(rawValue: try text("type", maximum: 32)) else { throw ArgumentError.invalid }
        let reason = try text("reason", maximum: 1000)
        let edgeID = NoteActionIdentity.uuid(context.proposalNamespace.uuidString + "\n" + from.id + "\n" + to.id + "\n" + type.rawValue)
        let relation = NoteRelation(id: edgeID, from: source(from), to: source(to), type: type, reason: reason,
          createdAt: context.proposalCreatedAt, fromRevision: from.revision, toRevision: to.revision)
        return try await pending(proposed(.link, relation: relation))
      case "relations_unlink":
        guard let id = UUID(uuidString: try text("relation_id", maximum: 36)),
          var relation = context.relations.first(where: { $0.id == id }),
          context.entries.contains(where: { $0.id == relation.from.cardRef }),
          context.entries.contains(where: { $0.id == relation.to.cardRef }) else { throw NoteActionError.outOfScope }
        relation.isStale = false // Read-time stale indication is not persisted edge identity.
        return try await pending(proposed(.unlink, relation: relation))
      case "notes_similar", "relations_suggest":
        let anchor = args["card_ref"] != nil ? try entry("card_ref") : nil
        if name == "relations_suggest", anchor == nil { throw ArgumentError.invalid }
        guard !(anchor != nil && args["query"] != nil) else { throw ArgumentError.invalid }
        let query: String
        if let anchor { query = anchor.memo.body } else { query = try text("query", maximum: 256) }
        let limit = try integer("limit", in: args, fallback: 10, range: 1...20)
        let matches = NoteDiscovery.similar(query: query, excluding: anchor?.id, entries: context.entries)
        let selected = Array(matches.prefix(limit))
        let cards: [[String: Any]] = selected.map { match in
          var item: [String: Any] = ["card_ref": match.entry.id, "day": match.entry.day,
            "snippet": source(match.entry).snippet, "score": match.score,
            "matching_terms": Array(match.terms.prefix(30)), "matching_tags": Array(match.tags.prefix(20))]
          if let anchor, name == "relations_suggest" {
            item["from_card_ref"] = anchor.id; item["to_card_ref"] = match.entry.id
            item["type"] = "related"; item["reason"] = "Shared local words or hashtags; review both excerpts before saving."
            item["from_excerpt"] = source(anchor).snippet; item["to_excerpt"] = source(match.entry).snippet
            item["status"] = "suggestion_only"
          }
          return item
        }
        return try result([name == "relations_suggest" ? "suggestions" : "cards": cards,
          "method": "local_lexical_words_cjk_bigrams_tags", "total": matches.count,
          "truncated": matches.count > selected.count || context.entries.count > NoteDiscovery.maximumCandidates,
          "candidate_limit": NoteDiscovery.maximumCandidates, "text_character_limit": NoteDiscovery.maximumCharacters],
          sources: selected.map { source($0.entry) })
      case "notes_neighbors":
        let anchor = try entry("card_ref"), limit = try integer("limit", in: args, fallback: 10, range: 1...20)
        let ordered = NoteDiscovery.sorted(context.entries).reversed().map { $0 }
        guard let index = ordered.firstIndex(where: { $0.id == anchor.id }) else { throw NoteActionError.outOfScope }
        let nearest = ordered.indices.filter { $0 != index }.sorted {
          abs($0 - index) == abs($1 - index) ? $0 < $1 : abs($0 - index) < abs($1 - index)
        }.prefix(limit).sorted().map { ordered[$0] }
        return try result(["cards": nearest.map { ["card_ref": $0.id, "day": $0.day, "snippet": source($0).snippet] },
          "order": "chronological", "truncated": ordered.count > nearest.count + 1], sources: nearest.map { source($0) })
      case "notes_find_duplicates":
        let anchor = args["card_ref"] != nil ? try entry("card_ref") : nil
        let limit = try integer("limit", in: args, fallback: 10, range: 1...20)
        let candidates = Array(NoteDiscovery.sorted(context.entries).prefix(NoteDiscovery.maximumCandidates))
        let left = anchor.map { [$0] } ?? candidates
        var pairs: [[String: Any]] = [], sources: [NoteToolSource] = [], inspected = 0
        outer: for a in left {
          let aText = NoteDiscovery.normalized(a.memo.body), aTokens = NoteDiscovery.tokens(a.memo.body)
          guard aText.count >= 24, aTokens.count >= 3 else { continue }
          for b in candidates where a.id != b.id && (anchor != nil || a.id < b.id) {
            if inspected >= NoteDiscovery.maximumPairs { break outer }; inspected += 1
            let bText = NoteDiscovery.normalized(b.memo.body), bTokens = NoteDiscovery.tokens(b.memo.body)
            guard bText.count >= 24, bTokens.count >= 3 else { continue }
            let score = Double(aTokens.intersection(bTokens).count) / Double(max(1, aTokens.union(bTokens).count))
            // An exact claim requires complete bounded bodies, never equal prefixes.
            let exact = a.memo.body.count <= NoteDiscovery.maximumCharacters && b.memo.body.count <= NoteDiscovery.maximumCharacters && aText == bText
            guard exact || score >= 0.8 else { continue }
            if pairs.count < limit {
              pairs.append(["from_card_ref": a.id, "to_card_ref": b.id,
                "match": exact ? "exact_normalized" : "near_lexical", "score": score,
                "from_excerpt": source(a).snippet, "to_excerpt": source(b).snippet])
              sources += [source(a), source(b)]
            }
          }
        }
        var seen = Set<String>()
        return try result(["pairs": pairs, "method": "local_lexical_normalization", "never_merges": true,
          "pairs_inspected": inspected, "pair_limit": NoteDiscovery.maximumPairs,
          "candidate_limit": NoteDiscovery.maximumCandidates, "text_character_limit": NoteDiscovery.maximumCharacters,
          "truncated": inspected >= NoteDiscovery.maximumPairs || candidates.count < context.entries.count || pairs.count == limit],
          sources: sources.filter { seen.insert($0.cardRef).inserted })
      case "relations_list":
        let anchor = args["card_ref"] != nil ? try entry("card_ref") : nil
        let limit = try integer("limit", in: args, fallback: 10, range: 1...20)
        let scope = Set(context.entries.map(\.id))
        let visible = context.relations.filter {
          scope.contains($0.from.cardRef) && scope.contains($0.to.cardRef)
        }.filter { edge in anchor.map { edge.from.cardRef == $0.id || edge.to.cardRef == $0.id } ?? true }
        let selected = Array(visible.prefix(limit))
        let data = try JSONEncoder().encode(selected)
        return try result(["relations": try JSONSerialization.jsonObject(with: data), "total": visible.count,
          "truncated": visible.count > selected.count], sources: selected.flatMap { [$0.from, $0.to] })
      default: throw ArgumentError.invalid
      }
    } catch is NoteActionError { return try failure("card_not_in_scope") }
  }

  private static var authoringDefinitions: [(name: String, description: String, schema: [String: Any])] {
    let ref: [String: Any] = ["type": "string", "maxLength": 1024, "description": "Complete authorized card_ref, never a path"]
    let text: [String: Any] = ["type": "string", "maxLength": 6000]
    let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 20]
    func schema(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
      ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    return [
      ("notes_create", "Propose a new ordinary note. Pending native review and Save; this never saves a note itself.", schema(["body": text], ["body"])),
      ("notes_append", "Propose appending text to one authorized note at its exact current revision. Requires native confirmation.", schema(["card_ref": ref, "body": text], ["card_ref", "body"])),
      ("notes_propose_patch", "Propose one unambiguous before/after replacement in a note body. No file paths or arbitrary patch language. Requires native confirmation.", schema(["card_ref": ref, "before": text, "after": text], ["card_ref", "before", "after"])),
      ("notes_similar", "Find local lexical matches using words, Chinese bigrams and hashtags; supply card_ref OR query. Excludes anchor. Empty is no match; not embedding semantic search.", schema(["card_ref": ref, "query": ["type": "string", "maxLength": 256], "limit": limit], [])),
      ("notes_neighbors", "Find chronological neighbors around one complete authorized card_ref.", schema(["card_ref": ref, "limit": limit], ["card_ref"])),
      ("notes_find_duplicates", "Report bounded normalized exact or near lexical duplicate candidates. Excludes short boilerplate and never merges or deletes.", schema(["card_ref": ref, "limit": limit], [])),
      ("relations_suggest", "Suggest related candidates with original excerpts using local lexical matching. Suggestions are not saved. User selects a suggestion before relations_link and native confirmation.", schema(["card_ref": ref, "limit": limit], ["card_ref"])),
      ("relations_list", "List saved directed incoming and outgoing relations visible at both authorized endpoints, with original evidence and stale indication.", schema(["card_ref": ref, "limit": limit], [])),
      ("relations_link", "Propose saving a user-selected directed relation with exact source excerpts and revisions. Native confirmation required; never claim a saved relation from a suggestion.", schema(["from_card_ref": ref, "to_card_ref": ref, "type": ["type": "string", "enum": NoteRelationType.allCases.map(\.rawValue)], "reason": ["type": "string", "maxLength": 1000]], ["from_card_ref", "to_card_ref", "type", "reason"])),
      ("relations_unlink", "Propose removing only one selected saved edge by relation_id, with both endpoints in scope. Requires native confirmation.", schema(["relation_id": ["type": "string", "maxLength": 36]], ["relation_id"])),
      ("notes_set_tags", "Propose replacing body hashtags on one authorized note while preserving its other text and metadata. Empty tags removes existing hashtags. Native confirmation required.", schema(["card_ref": ref, "tags": ["type": "array", "maxItems": 20, "items": ["type": "string", "maxLength": 64]]], ["card_ref", "tags"])),
      ("notes_set_pin", "Propose changing pinned_at on one authorized note. Requires native confirmation.", schema(["card_ref": ref, "pinned": ["type": "boolean"]], ["card_ref", "pinned"]))
    ]
  }
}
