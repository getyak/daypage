import Foundation

// MARK: - SearchResult

/// A single hit returned by ``SearchService``.
struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    let dateString: String              // "yyyy-MM-dd"
    let snippet: String                 // matched memo body (trimmed, <=120 chars)
    let matchKind: MatchKind
    let isDailyPageCompiled: Bool

    enum MatchKind: Equatable {
        case memoBody
        case location
        case date
    }
}

// MARK: - SearchService

/// In-memory search over the local vault.
/// MVP: scan all ``vault/raw/*.md`` files and the compiled daily pages, case-insensitive ``contains``.
/// Results are grouped by date and capped at 100 to keep the UI responsive.
enum SearchService {

    // MARK: - Public API

    /// Searches raw memos + compiled daily pages for ``keyword``.
    /// Returns results sorted by date descending (newest first).
    /// Empty keyword returns an empty array.
    static func search(keyword rawKeyword: String) -> [SearchResult] {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }

        let lowered = keyword.lowercased()
        var results: [SearchResult] = []

        let fm = FileManager.default
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")

        guard let files = try? fm.contentsOfDirectory(at: rawDir,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }

        // Sort newest first by filename (yyyy-MM-dd sorts lexicographically).
        let mdFiles = files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for url in mdFiles {
            let dateString = url.deletingPathExtension().lastPathComponent
            guard isValidDateString(dateString) else { continue }

            let dailyURL = dailyDir.appendingPathComponent("\(dateString).md")
            let isDailyCompiled = fm.fileExists(atPath: dailyURL.path)

            // Date string match (e.g. "2026-04" or "04-14").
            if dateString.lowercased().contains(lowered) {
                results.append(SearchResult(
                    dateString: dateString,
                    snippet: dateString,
                    matchKind: .date,
                    isDailyPageCompiled: isDailyCompiled
                ))
            }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let memos = RawStorage.parse(fileContent: content)

            for memo in memos {
                if memo.body.lowercased().contains(lowered) {
                    results.append(SearchResult(
                        dateString: dateString,
                        snippet: makeSnippet(memo.body, around: lowered),
                        matchKind: .memoBody,
                        isDailyPageCompiled: isDailyCompiled
                    ))
                    continue
                }
                if let transcript = firstMatchingTranscript(in: memo, keyword: lowered) {
                    results.append(SearchResult(
                        dateString: dateString,
                        snippet: makeSnippet(transcript, around: lowered),
                        matchKind: .memoBody,
                        isDailyPageCompiled: isDailyCompiled
                    ))
                    continue
                }
                if let name = memo.location?.name,
                   name.lowercased().contains(lowered) {
                    results.append(SearchResult(
                        dateString: dateString,
                        snippet: name,
                        matchKind: .location,
                        isDailyPageCompiled: isDailyCompiled
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
