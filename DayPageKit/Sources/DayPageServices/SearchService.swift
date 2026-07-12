import Foundation
import DayPageModels
import DayPageStorage

// MARK: - SearchResult

/// ``SearchService`` 返回的单个命中结果。
public struct SearchResult: Identifiable, Equatable {
    public let id = UUID()
    public let dateString: String              // "yyyy-MM-dd"
    public let snippet: String                 // 匹配的 memo 正文（修剪后 <=120 字符）
    public let matchKind: MatchKind
    public let isDailyPageCompiled: Bool
    public let memoType: Memo.MemoType?        // matchKind == .date 时为 nil

    public enum MatchKind: Equatable, Hashable {
        case memoBody
        case location
        case date
    }
}

// MARK: - SearchFilters

public struct SearchFilters: Equatable {
    public var startDate: Date?
    public var endDate: Date?
    public var types: Set<Memo.MemoType>       // 空集 = 所有类型
    public var locationQuery: String           // 空字符串 = 无位置过滤

    public static let empty = SearchFilters(startDate: Date?.none, endDate: Date?.none, types: Set<Memo.MemoType>(), locationQuery: "")

    public var isActive: Bool {
        startDate != nil || endDate != nil || !types.isEmpty || !locationQuery.isEmpty
    }
}

// MARK: - SearchService

/// 本地 vault 的内存搜索。
/// MVP：扫描所有 ``vault/raw/*.md`` 文件和编译的日记页面，大小写不敏感的 ``contains``。
/// 结果按日期分组，上限 100 以保持 UI 响应。
public enum SearchService {

    // MARK: - Public API

    /// 搜索原始 memo + 编译的日记页面，匹配 ``keyword`` 并应用可选的 ``filters``。
    /// 返回按日期降序排列的结果（最新优先）。
    /// 空关键字 + 无活跃过滤器时返回空数组。
    public nonisolated static func search(keyword rawKeyword: String,
                                   filters: SearchFilters = .empty) -> [SearchResult] {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = foldForSearch(keyword)
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

        // 按文件名从新到旧排序（yyyy-MM-dd 按字典序排列）。
        let mdFiles = files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for url in mdFiles {
            let dateString = url.deletingPathExtension().lastPathComponent
            guard isValidDateString(dateString) else { continue }

            // 日期范围过滤
            if let start = filters.startDate, let date = dateValidator.date(from: dateString) {
                if date < Calendar.current.startOfDay(for: start) { continue }
            }
            if let end = filters.endDate, let date = dateValidator.date(from: dateString) {
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!
                if date >= endOfDay { continue }
            }

            let dailyURL = dailyDir.appendingPathComponent("\(dateString).md")
            let isDailyCompiled = fm.fileExists(atPath: dailyURL.path)

            // 日期字符串匹配（如 "2026-04" 或 "04-14"）—— 仅当有关键字且无类型过滤时
            if hasKeyword && filters.types.isEmpty && foldForSearch(dateString).contains(folded) {
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
                // 类型过滤
                if !filters.types.isEmpty && !filters.types.contains(memo.type) { continue }

                // 位置查询过滤
                if !filters.locationQuery.isEmpty {
                    let foldedLoc = foldForSearch(filters.locationQuery)
                    guard let name = memo.location?.name,
                          foldForSearch(name).contains(foldedLoc) else { continue }
                }

                if hasKeyword {
                    if foldForSearch(memo.body).contains(folded) {
                        results.append(SearchResult(
                            dateString: dateString,
                            snippet: makeSnippet(memo.body, around: folded),
                            matchKind: SearchResult.MatchKind.memoBody,
                            isDailyPageCompiled: isDailyCompiled,
                            memoType: memo.type
                        ))
                        continue
                    }
                    if let transcript = firstMatchingTranscript(in: memo, keyword: folded) {
                        results.append(SearchResult(
                            dateString: dateString,
                            snippet: makeSnippet(transcript, around: folded),
                            matchKind: SearchResult.MatchKind.memoBody,
                            isDailyPageCompiled: isDailyCompiled,
                            memoType: memo.type
                        ))
                        continue
                    }
                    if let name = memo.location?.name,
                       foldForSearch(name).contains(folded) {
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
                    // 仅过滤器 —— 包含所有通过过滤检查的 memo
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

    // MARK: - Indexed fast path (#827)

    /// Index-backed variant of ``search(keyword:filters:)`` — identical match
    /// semantics (date → body → transcript → location priority, filters-only
    /// mode, 100-result cap, newest-first) over pre-folded in-memory
    /// documents instead of a full-vault disk scan. Pure function over the
    /// value-type snapshot, so callers may run it off the main actor.
    ///
    /// `isDailyPageCompiled` is resolved with a per-matched-day `stat()`
    /// (≤100 by the cap) because compilation writes `wiki/daily/` and can't
    /// invalidate the raw-file index — see `SearchIndex`'s doc comment.
    public nonisolated static func search(
        keyword rawKeyword: String,
        filters: SearchFilters = .empty,
        in docs: [SearchIndex.DayDocument]
    ) -> [SearchResult] {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = foldForSearch(keyword)
        let hasKeyword = !keyword.isEmpty
        guard hasKeyword || filters.isActive else { return [] }

        let fm = FileManager.default
        let dailyDir = VaultInitializer.vaultURL.appendingPathComponent("wiki/daily")
        // Per-day compiled flags are memoized so multiple matches inside one
        // day cost a single stat().
        var compiledByDate: [String: Bool] = [:]
        func isDailyCompiled(_ dateString: String) -> Bool {
            if let cached = compiledByDate[dateString] { return cached }
            let exists = fm.fileExists(
                atPath: dailyDir.appendingPathComponent("\(dateString).md").path
            )
            compiledByDate[dateString] = exists
            return exists
        }

        var results: [SearchResult] = []

        for day in docs {
            // 日期范围过滤 — same start-of-day / end-of-day rules as legacy.
            if let start = filters.startDate, let date = dateValidator.date(from: day.dateString) {
                if date < Calendar.current.startOfDay(for: start) { continue }
            }
            if let end = filters.endDate, let date = dateValidator.date(from: day.dateString) {
                let endOfDay = Calendar.current.date(
                    byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)
                )!
                if date >= endOfDay { continue }
            }

            // 日期字符串匹配 —— 仅当有关键字且无类型过滤时。
            if hasKeyword && filters.types.isEmpty && day.foldedDateString.contains(folded) {
                results.append(SearchResult(
                    dateString: day.dateString,
                    snippet: day.dateString,
                    matchKind: SearchResult.MatchKind.date,
                    isDailyPageCompiled: isDailyCompiled(day.dateString),
                    memoType: Memo.MemoType?.none
                ))
            }

            for memo in day.memos {
                if !filters.types.isEmpty && !filters.types.contains(memo.type) { continue }

                if !filters.locationQuery.isEmpty {
                    let foldedLoc = foldForSearch(filters.locationQuery)
                    guard let name = memo.foldedLocationName,
                          name.contains(foldedLoc) else { continue }
                }

                if hasKeyword {
                    if memo.foldedBody.contains(folded) {
                        results.append(SearchResult(
                            dateString: day.dateString,
                            snippet: makeSnippet(memo.body, around: folded),
                            matchKind: SearchResult.MatchKind.memoBody,
                            isDailyPageCompiled: isDailyCompiled(day.dateString),
                            memoType: memo.type
                        ))
                        continue
                    }
                    if let hit = memo.transcripts.first(where: { $0.folded.contains(folded) }) {
                        results.append(SearchResult(
                            dateString: day.dateString,
                            snippet: makeSnippet(hit.raw, around: folded),
                            matchKind: SearchResult.MatchKind.memoBody,
                            isDailyPageCompiled: isDailyCompiled(day.dateString),
                            memoType: memo.type
                        ))
                        continue
                    }
                    if let name = memo.foldedLocationName, name.contains(folded) {
                        results.append(SearchResult(
                            dateString: day.dateString,
                            snippet: memo.locationName ?? "",
                            matchKind: SearchResult.MatchKind.location,
                            isDailyPageCompiled: isDailyCompiled(day.dateString),
                            memoType: memo.type
                        ))
                        continue
                    }
                } else {
                    let snippet = memo.body.isEmpty
                        ? (memo.locationName ?? day.dateString)
                        : String(memo.body.prefix(120))
                    results.append(SearchResult(
                        dateString: day.dateString,
                        snippet: snippet,
                        matchKind: SearchResult.MatchKind.memoBody,
                        isDailyPageCompiled: isDailyCompiled(day.dateString),
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
            if let t = att.transcript, foldForSearch(t).contains(keyword) {
                return t
            }
        }
        return nil
    }

    /// 提取第一个匹配位置周围短上下文窗口（<=120 字符），
    /// 回退到文本开头。匹配范围在折叠文本上定位，切片在原始文本上执行，
    /// 以保留显示时的重音符号。
    private static func makeSnippet(_ text: String, around foldedKeyword: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let foldedNormalized = foldForSearch(normalized)
        guard let range = foldedNormalized.range(of: foldedKeyword) else {
            return String(normalized.prefix(120))
        }
        // Convert offsets from the folded string to the original normalized string.
        // Since folding may change character widths, use UTF-16 offset mapping.
        let startOffset = foldedNormalized.utf16.distance(from: foldedNormalized.utf16.startIndex,
                                                          to: range.lowerBound)
        let endOffset   = foldedNormalized.utf16.distance(from: foldedNormalized.utf16.startIndex,
                                                          to: range.upperBound)
        let normStart = normalized.utf16.index(normalized.utf16.startIndex,
                                               offsetBy: min(startOffset, normalized.utf16.count))
        let normEnd   = normalized.utf16.index(normalized.utf16.startIndex,
                                               offsetBy: min(endOffset, normalized.utf16.count))
        let matchLower = normStart.samePosition(in: normalized) ?? normalized.startIndex
        let matchUpper = normEnd.samePosition(in: normalized) ?? normalized.endIndex
        let windowStart = normalized.index(matchLower,
                                           offsetBy: -30,
                                           limitedBy: normalized.startIndex) ?? normalized.startIndex
        let windowEnd = normalized.index(matchUpper,
                                         offsetBy: 90,
                                         limitedBy: normalized.endIndex) ?? normalized.endIndex
        var snippet = String(normalized[windowStart..<windowEnd])
        if windowStart != normalized.startIndex { snippet = "…" + snippet }
        if windowEnd != normalized.endIndex { snippet += "…" }
        return snippet
    }

    /// The single folding rule shared by live queries and `SearchIndex`'s
    /// precomputed documents — the two MUST stay identical or index hits and
    /// legacy hits diverge. Public for the index; treat as sealed.
    public nonisolated static func foldForSearch(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
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
