import Foundation

/// Transient lexical matching only: bounded words, CJK bigrams and body hashtags.
enum NoteDiscovery {
  static let maximumCandidates = 500
  static let maximumCharacters = 6000
  static let maximumPairs = 5000
  struct Match {
    let entry: NotebookEntry
    let score: Double
    let terms: [String]
    let tags: [String]
  }
  static func tokens(_ text: String) -> Set<String> {
    let folded = String(text.prefix(maximumCharacters)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "are", "was", "have", "has", "into", "a", "an", "of", "to", "in", "on", "is", "it"]
    var terms = Set<String>()
    var word = "", cjk = ""
    func flushWord() {
      if word.count >= 2, !stop.contains(word) { terms.insert(word) }
      word = ""
    }
    func flushCJK() {
      let chars = Array(cjk)
      if chars.count >= 2 { for i in 0..<(chars.count - 1) { terms.insert(String(chars[i...i + 1])) } }
      cjk = ""
    }
    for scalar in folded.unicodeScalars {
      if (0x3400...0x9FFF).contains(scalar.value) {
        flushWord(); cjk.unicodeScalars.append(scalar)
      } else if CharacterSet.alphanumerics.contains(scalar) {
        flushCJK(); word.unicodeScalars.append(scalar)
      } else { flushWord(); flushCJK() }
    }
    flushWord(); flushCJK()
    return terms
  }
  static func sorted(_ entries: [NotebookEntry]) -> [NotebookEntry] {
    entries.sorted {
      if $0.day != $1.day { return $0.day > $1.day }
      if $0.memo.created != $1.memo.created { return $0.memo.created > $1.memo.created }
      return $0.id < $1.id
    }
  }
  static func similar(query: String, excluding: String?, entries: [NotebookEntry]) -> [Match] {
    let queryTokens = tokens(query), queryTags = Set(NotebookCatalog.tags(in: String(query.prefix(maximumCharacters))))
    return sorted(entries).prefix(maximumCandidates).compactMap { entry -> Match? in
      guard entry.id != excluding else { return nil }
      let body = String(entry.memo.body.prefix(maximumCharacters))
      let bodyTokens = tokens(body)
      let common = queryTokens.intersection(bodyTokens)
      let tags = queryTags.intersection(NotebookCatalog.tags(in: body))
      guard !common.isEmpty || !tags.isEmpty else { return nil }
      let score = Double(common.count) / Double(max(1, queryTokens.union(bodyTokens).count)) + Double(tags.count) * 0.25
      return Match(entry: entry, score: score, terms: common.sorted(), tags: tags.sorted())
    }.sorted { $0.score == $1.score ? $0.entry.id < $1.entry.id : $0.score > $1.score }
  }
  static func normalized(_ body: String) -> String {
    String(body.prefix(maximumCharacters)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }
}
