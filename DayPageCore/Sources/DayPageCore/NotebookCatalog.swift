import Foundation

public enum NotebookEntryKind: String, CaseIterable, Identifiable, Sendable {
  case all, pinned, photos, voice, files
  public var id: Self { self }
}

public struct NotebookDaySection: Identifiable, Sendable {
  public let day: String
  public let entries: [NotebookEntry]
  public var id: String { day }
}

public struct NotebookSearchResult: Sendable {
  public let sections: [NotebookDaySection]
  public let count: Int
}

public struct NotebookMonthSummary: Identifiable, Sendable {
  public let id: String
  public let latestDay: String
  public let noteCount: Int
  public let dayCount: Int
}

/// A transient index rebuilt after a file refresh. No second persistence store.
/// Each query visits every record once, independent of the number of day sections.
public struct NotebookCatalog: Sendable {
  private struct Record: Sendable {
    let entry: NotebookEntry
    let searchable: String
    let tags: Set<String>
  }
  private let records: [Record]
  private let unfiltered: NotebookSearchResult
  private let diarySections: [NotebookDaySection]
  private static let tagExpression = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_-]+)"#)
  public let dayCounts: [String: Int]
  public let entriesByDay: [String: [NotebookEntry]]
  public let tags: [String]
  public let months: [NotebookMonthSummary]

  public init(entries: [NotebookEntry]) {
    records = entries.map { entry in
      Record(entry: entry,
             searchable: entry.memo.body + "\n" + entry.day + "\n"
               + entry.memo.attachments.compactMap(\.transcript).joined(separator: "\n"),
             tags: Set(Self.tags(in: entry.memo.body)))
    }
    let grouped = Dictionary(grouping: entries, by: \.day)
    entriesByDay = grouped
    dayCounts = entriesByDay.mapValues(\.count)
    tags = Array(Set(records.flatMap(\.tags))).sorted()
    unfiltered = NotebookSearchResult(sections: grouped.keys.sorted(by: >).map {
      NotebookDaySection(day: $0, entries: grouped[$0, default: []])
    }, count: entries.count)
    diarySections = grouped.keys.sorted(by: >).map { day in
      NotebookDaySection(day: day, entries: grouped[day, default: []].sorted {
        if ($0.memo.pinnedAt != nil) != ($1.memo.pinnedAt != nil) { return $0.memo.pinnedAt != nil }
        if $0.memo.created != $1.memo.created { return $0.memo.created > $1.memo.created }
        return $0.id < $1.id
      })
    }
    let monthDays = Dictionary(grouping: grouped.keys, by: { String($0.prefix(7)) })
    months = monthDays.keys.sorted(by: >).compactMap { month in
      let days = monthDays[month, default: []]
      guard let latest = days.max() else { return nil }
      return NotebookMonthSummary(id: month, latestDay: latest,
        noteCount: days.reduce(0) { $0 + grouped[$1, default: []].count }, dayCount: days.count)
    }
  }

  /// Date choices are positions in the diary, never filters. Empty destinations
  /// get an anchor without hiding any of the notebook's real records.
  public func diary(including days: [String]) -> [NotebookDaySection] {
    let missing = Set(days).subtracting(entriesByDay.keys)
    guard !missing.isEmpty else { return diarySections }
    return (diarySections + missing.map { NotebookDaySection(day: $0, entries: []) })
      .sorted { $0.day > $1.day }
  }

  public func search(text: String = "", kind: NotebookEntryKind = .all, tag: String? = nil,
                     day: String? = nil) -> NotebookSearchResult {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty, kind == .all, tag == nil, day == nil { return unfiltered }
    var groups: [String: [NotebookEntry]] = [:]
    var count = 0
    for record in records {
      let entry = record.entry
      guard query.isEmpty || record.searchable.localizedCaseInsensitiveContains(query),
            tag.map({ record.tags.contains($0) }) ?? true,
            day.map({ entry.day == $0 }) ?? true else { continue }
      let matches: Bool
      switch kind {
      case .all: matches = true
      case .pinned: matches = entry.memo.pinnedAt != nil
      case .photos: matches = entry.memo.attachments.contains { $0.kind == "photo" }
      case .voice: matches = entry.memo.attachments.contains { $0.kind == "audio" }
      case .files: matches = entry.memo.attachments.contains { $0.kind == "file" }
      }
      guard matches else { continue }
      groups[entry.day, default: []].append(entry)
      count += 1
    }
    return NotebookSearchResult(sections: groups.keys.sorted(by: >).map {
      NotebookDaySection(day: $0, entries: groups[$0, default: []])
    }, count: count)
  }

  public static func tags(in text: String) -> [String] {
    guard let regex = tagExpression else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Array(Set(regex.matches(in: text, range: range).compactMap { result in
      Range(result.range(at: 1), in: text).map { String(text[$0]) }
    })).sorted()
  }
}
