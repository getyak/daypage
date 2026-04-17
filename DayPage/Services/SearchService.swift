import Foundation

// MARK: - SearchResult

/// A single hit returned by ``SearchService``.
struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    let dateString: String              // "yyyy-MM-dd"
    let snippet: String                 // matched memo body (trimmed, <=120 chars)
    let matchKind: MatchKind
    let isDailyPageCompiled: Bool
    let memoType: Memo.MemoType?        // nil when matchKind == .date

    enum MatchKind: Equatable {
        case memoBody
        case location
        case date
    }
}

// MARK: - SearchFilters

struct SearchFilters: Equatable {
    var startDate: Date?
    var endDate: Date?
    var types: Set<Memo.MemoType>       // empty = all types
    var locationQuery: String           // empty = no location filter

    static let empty = SearchFilters(startDate: Date?.none, endDate: Date?.none, types: Set<Memo.MemoType>(), locationQuery: "")

    var isActive: Bool {
        startDate != nil || endDate != nil || !types.isEmpty || !locationQuery.isEmpty
    }
}

// MARK: - SearchService

/// In-memory search over the local vault.
/// MVP: scan all ``vault/raw/*.md`` files and the compiled daily pages, case-insensitive ``contains``.
/// Results are grouped by date and capped at 100 to keep the UI responsive.
enum SearchService {

    // MARK: - Public API

    /// Searches raw memos + compiled daily pages for ``keyword`` with optional ``filters``.
    /// Returns results sorted by date descending (newest first).
    /// Empty keyword + no active filters returns an empty array.
    static func search(keyword rawKeyword: String,
                       filters: SearchFilters = .empty) -> [SearchResult] {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = keyword.lowercased()
        let hasKeyword = !keyword.isEmpty
        guard hasKeyword || filters.isActive else { return [] }

        var results: [SearchResult] = []

        let fm = FileManager.default
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")

        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            return []
        }

        // Sort newest first by filename (yyyy-MM-dd sorts lexicographically).
        let mdFiles = files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for url in mdFiles {
            let dateString = url.deletingPathExtension().lastPathComponent
            guard isValidDateString(dateString) else { continue }

            // Date range filter
            if let start = filters.startDate, let date = dateValidator.date(from: dateString) {
                if date < Calendar.current.startOfDay(for: start) { continue }
            }
            if let end = filters.endDate, let date = dateValidator.date(from: dateString) {
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!
                if date >= endOfDay { continue }
            }

            let dailyURL = dailyDir.appendingPathComponent("\(dateString).md")
            let isDailyCompiled = fm.fileExists(atPath: dailyURL.path)

            // Date string match (e.g. "2026-04" or "04-14") — only when keyword present and no type filter.
            if hasKeyword && filters.types.isEmpty && dateString.lowercased().contains(lowered) {
                results.append(SearchResult(
                    dateString: dateString,
                    snippet: dateString,
                    matchKind: SearchResult.MatchKind.date,
                    isDailyPageCompiled: isDailyCompiled,
                    memoType: Memo.MemoType?.none
                ))
            }

            let content: String
            do { content = try String(contentsOf: url, encoding: .utf8) }
            catch { continue }
            let memos = RawStorage.parse(fileContent: content)

            for memo in memos {
                // Type filter
                if !filters.types.isEmpty && !filters.types.contains(memo.type) { continue }

                // Location query filter
                if !filters.locationQuery.isEmpty {
                    let locLowered = filters.locationQuery.lowercased()
                    guard let name = memo.location?.name,
                          name.lowercased().contains(locLowered) else { continue }
                }

                if hasKeyword {
                    if memo.body.lowercased().contains(lowered) {
                        results.append(SearchResult(
                            dateString: dateString,
                            snippet: makeSnippet(memo.body, around: lowered),
                            matchKind: SearchResult.MatchKind.memoBody,
                            isDailyPageCompiled: isDailyCompiled,
                            memoType: memo.type
                        ))
                        continue
                    }
                    if let transcript = firstMatchingTranscript(in: memo, keyword: lowered) {
                        results.append(SearchResult(
                            dateString: dateString,
                            snippet: makeSnippet(transcript, around: lowered),
                            matchKind: SearchResult.MatchKind.memoBody,
                            isDailyPageCompiled: isDailyCompiled,
                            memoType: memo.type
                        ))
                        continue
                    }
                    if let name = memo.location?.name,
                       name.lowercased().contains(lowered) {
                        results.append(SearchResult(
                            dateString: dateString,
                            snippet: name,
                            matchKind: SearchResult.MatchKind.location,
                            isDailyPageCompiled: isDailyCompiled,
                            memoType: memo.type
                        ))
                        continue
                    }
                } else {
                    // Filters only — include any memo that passed filter checks
                    let snippet = memo.body.isEmpty
                        ? (memo.location?.name ?? dateString)
                        : String(memo.body.prefix(120))
                    results.append(SearchResult(
                        dateString: dateString,
                        snippet: snippet,
                        matchKind: SearchResult.MatchKind.memoBody,
                        isDailyPageCompiled: isDailyCompiled,
                        memoType: memo.type
                    ))
                }
            }

            if results.count >= 100 { break }
        }

        return results
    }

    // MARK: - Private helpers

    private static func firstMatchingTranscript(in memo: Memo, keyword: String) -> String? {
        for att in memo.attachments {
            if let t = att.transcript, t.lowercased().contains(keyword) {
                return t
            }
        }
        return nil
    }

    /// Extracts a short context window (<=120 chars) around the first match,
    /// falling back to the head of the text.
    private static func makeSnippet(_ text: String, around keyword: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let lowered = normalized.lowercased()
        guard let range = lowered.range(of: keyword) else {
            return String(normalized.prefix(120))
        }
        let windowStart = normalized.index(range.lowerBound,
                                           offsetBy: -30,
                                           limitedBy: normalized.startIndex) ?? normalized.startIndex
        let windowEnd = normalized.index(range.upperBound,
                                         offsetBy: 90,
                                         limitedBy: normalized.endIndex) ?? normalized.endIndex
        var snippet = String(normalized[windowStart..<windowEnd])
        if windowStart != normalized.startIndex { snippet = "…" + snippet }
        if windowEnd != normalized.endIndex { snippet += "…" }
        return snippet
    }

    private static let dateValidator: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func isValidDateString(_ s: String) -> Bool {
        dateValidator.date(from: s) != nil
    }
}
