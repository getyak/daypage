import Foundation
import DayPageModels
import DayPageStorage

// MARK: - WeeklyCompilationError

/// Errors surfaced by ``WeeklyCompilationService``. Kept distinct from
/// ``CompilationError`` so the weekly recap UX can map them to its own copy
/// without inheriting the daily-pipeline's vocabulary.
public enum WeeklyCompilationError: LocalizedError {
    case aiDisabled
    case offline
    case noData
    case missingApiKey
    case networkTimeout
    case apiRateLimited
    case apiError(statusCode: Int, body: String)
    case parseFailed(String)
    case fileSystemError(String)
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .aiDisabled:       return "AI 功能已关闭"
        case .offline:          return "当前离线"
        case .noData:           return "本周尚无可用的 Daily Page"
        case .missingApiKey:    return "API Key 未配置"
        case .networkTimeout:   return "网络请求超时"
        case .apiRateLimited:   return "请求频率超限（429）"
        case .apiError(let code, let body):
            return "API 错误 \(code)：\(body.prefix(200))"
        case .parseFailed(let msg):
            return "AI 返回解析失败：\(msg)"
        case .fileSystemError(let msg):
            return "文件写入失败：\(msg)"
        case .unknown(let err):
            return "未知错误：\(err.localizedDescription)"
        }
    }
}

// MARK: - WeeklyMetadata

/// Aggregated frontmatter metadata for the 7-day ISO week containing the
/// reference date. Serialised into the LLM prompt as JSON.
public struct WeeklyMetadata: Codable, Equatable {
    public let isoWeek: String           // "2026-W26"
    public let weekStart: String         // "2026-06-22"
    public let weekEnd: String           // "2026-06-28"
    public let days: [DayMetadata]
}

/// Per-day metadata harvested from `vault/wiki/daily/{date}.md` frontmatter.
public struct DayMetadata: Codable, Equatable {
    public let date: String              // "2026-06-22"
    public let mood: String?
    public let summary: String?
    public let entities: [String]
    public let locations: [String]
}

// MARK: - WeeklyRecapOutput

/// The structured weekly recap returned by the LLM and persisted in
/// `vault/wiki/weekly/{isoWeek}.md`.
public struct WeeklyRecapOutput: Codable, Equatable {
    public let isoWeek: String
    public let dateRange: String         // "2026-06-22 to 2026-06-28"
    public let compiledAt: Date
    public let keywords: [String]
    public let moodNotes: String
    public let placeNotes: String
    public let highlights: [String]
    /// Issue #9 (2026-07-03): 3-5 personalised reflection questions the
    /// AI derives from the week's material. Rendered by
    /// `WeeklyRecapDetailView` as "本周 5 问"; tapping a question opens a
    /// composer sheet pre-filled with the prompt, and the user's answer
    /// becomes a new memo. Old cached recaps that predate this field
    /// decode as `[]` because of the custom `init(from:)` below — see
    /// tests/WeeklyCompilationServiceTests for the compatibility contract.
    public let reflectionQuestions: [String]
    /// Issue #14 (2026-07-03): 值得回看的孤峰 —— low-frequency, high-signal
    /// moments the ordinary highlight extractor is likely to drop. Each
    /// entry is a short human-readable line ("2026-06-27 凌晨 2:14 · 一段
    /// 500 字的独白") ready for direct display; the ranking is deterministic
    /// so a re-compile of the same week produces the same list.
    public let outliers: [String]

    /// Explicit public memberwise init. `reflectionQuestions` + `outliers`
    /// default to `[]` so existing callers compile unchanged.
    public init(
        isoWeek: String,
        dateRange: String,
        compiledAt: Date,
        keywords: [String],
        moodNotes: String,
        placeNotes: String,
        highlights: [String],
        reflectionQuestions: [String] = [],
        outliers: [String] = []
    ) {
        self.isoWeek = isoWeek
        self.dateRange = dateRange
        self.compiledAt = compiledAt
        self.keywords = keywords
        self.moodNotes = moodNotes
        self.placeNotes = placeNotes
        self.highlights = highlights
        self.reflectionQuestions = reflectionQuestions
        self.outliers = outliers
    }

    /// Custom decode that tolerates cached JSON written before Issues
    /// #9 / #14 (missing `reflectionQuestions` / `outliers`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isoWeek = try c.decode(String.self, forKey: .isoWeek)
        self.dateRange = try c.decode(String.self, forKey: .dateRange)
        self.compiledAt = try c.decode(Date.self, forKey: .compiledAt)
        self.keywords = try c.decode([String].self, forKey: .keywords)
        self.moodNotes = try c.decode(String.self, forKey: .moodNotes)
        self.placeNotes = try c.decode(String.self, forKey: .placeNotes)
        self.highlights = try c.decode([String].self, forKey: .highlights)
        self.reflectionQuestions = (try? c.decode([String].self, forKey: .reflectionQuestions)) ?? []
        self.outliers = (try? c.decode([String].self, forKey: .outliers)) ?? []
    }
}

// MARK: - WeeklyCompilationService

/// Compiles a 7-day weekly recap from already-compiled daily pages using the
/// shared ``LLMClient``. Writes the result to
/// `vault/wiki/weekly/{isoWeek}.md` and supports cache reads via
/// ``loadCached(for:)``.
///
/// Boundaries (mirrors ``CompilationService``):
///   * Only reads `vault/wiki/daily/{date}.md` frontmatter — never raw memos.
///   * Pure-function helpers (``isoWeekKey``, ``parse``) are static so tests
///     can hit them without spinning up the singleton.
///   * No background scheduling — Phase 1 is user-initiated via the Archive
///     entry card. A future BG task can call ``compileWeekly`` directly.
@MainActor
public final class WeeklyCompilationService {

    // MARK: Singleton

    public static let shared = WeeklyCompilationService()
    private init() {}

    // MARK: - Public API

    /// Aggregate frontmatter metadata for the ISO week containing
    /// `referenceDate`. Days without a compiled daily page are silently
    /// skipped; the result is non-empty iff at least one day has a daily
    /// page. Throws ``WeeklyCompilationError/noData`` when zero days are
    /// available — the UI can then prompt the user to compile first.
    public func collectWeekMetadata(for referenceDate: Date) throws -> WeeklyMetadata {
        let calendar = Self.weekCalendar
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
            throw WeeklyCompilationError.noData
        }
        let weekStart = calendar.startOfDay(for: interval.start)
        let dateFormatter = Self.dateFormatter

        let dailyDir = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
        let fm = FileManager.default

        var days: [DayMetadata] = []
        var weekEnd = weekStart
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            weekEnd = date
            let dateStr = dateFormatter.string(from: date)
            let url = dailyDir.appendingPathComponent("\(dateStr).md")
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let mood = FrontmatterParser.extractField("mood", from: content)
            let summary = FrontmatterParser.extractField("summary", from: content)
            let entities = Self.extractList("entities", from: content)
            let locations = Self.extractList("locations", from: content)

            days.append(DayMetadata(
                date: dateStr,
                mood: mood,
                summary: summary,
                entities: entities,
                locations: locations
            ))
        }

        guard !days.isEmpty else { throw WeeklyCompilationError.noData }

        return WeeklyMetadata(
            isoWeek: Self.isoWeekKey(for: weekStart),
            weekStart: dateFormatter.string(from: weekStart),
            weekEnd: dateFormatter.string(from: weekEnd),
            days: days
        )
    }

    /// True compile path. When `forceRefresh == false` and a cached recap
    /// exists for the target ISO week, returns the cache without an LLM
    /// round-trip. Otherwise builds the prompt, calls the LLM, parses the
    /// response, and persists the result.
    public func compileWeekly(
        for referenceDate: Date,
        forceRefresh: Bool = false
    ) async throws -> WeeklyRecapOutput {
        if !forceRefresh, let cached = loadCached(for: referenceDate) {
            return cached
        }

        guard AppSettings.aiFeaturesEnabled else {
            throw WeeklyCompilationError.aiDisabled
        }
        guard NetworkMonitor.shared.isOnline else {
            throw WeeklyCompilationError.offline
        }

        let metadata = try collectWeekMetadata(for: referenceDate)
        let promptJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            promptJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw WeeklyCompilationError.parseFailed(error.localizedDescription)
        }

        let prompt = Self.buildPrompt(metadataJSON: promptJSON)
        let raw: String
        do {
            let client = LLMClient(
                config: .deepSeek(maxTokens: 1024, temperature: 0.6, timeout: 90),
                spanName: "compile.weekly"
            )
            raw = try await client.complete(messages: [
                .system(Self.systemPrompt),
                .user(prompt)
            ])
        } catch let llm as LLMError {
            SentryReporter.breadcrumb(
                category: "weekly",
                level: .error,
                message: "compileWeekly LLM error: \(llm.errorDescription ?? "?")"
            )
            throw Self.mapLLMError(llm)
        } catch {
            SentryReporter.breadcrumb(
                category: "weekly",
                level: .error,
                message: "compileWeekly unknown error: \(error)"
            )
            throw WeeklyCompilationError.unknown(error)
        }

        let llmOutput = try Self.parse(
            llmResponse: raw,
            isoWeek: metadata.isoWeek,
            weekStart: metadata.weekStart,
            weekEnd: metadata.weekEnd,
            compiledAt: Date()
        )

        // Issue #14 (2026-07-03): outlier ranking is deterministic and
        // computed locally from raw memo metadata, not from the LLM
        // output. The AI already selects highlights on frequency signal;
        // we want a complementary "low-frequency, high-signal" list so
        // the user doesn't lose the 500-word midnight monologue among the
        // 30 grocery reminders.
        let outliers = Self.computeWeeklyOutliers(referenceDate: referenceDate)
        let output = WeeklyRecapOutput(
            isoWeek: llmOutput.isoWeek,
            dateRange: llmOutput.dateRange,
            compiledAt: llmOutput.compiledAt,
            keywords: llmOutput.keywords,
            moodNotes: llmOutput.moodNotes,
            placeNotes: llmOutput.placeNotes,
            highlights: llmOutput.highlights,
            reflectionQuestions: llmOutput.reflectionQuestions,
            outliers: outliers
        )

        do {
            try write(output: output)
        } catch let err as WeeklyCompilationError {
            throw err
        } catch {
            throw WeeklyCompilationError.fileSystemError(error.localizedDescription)
        }

        return output
    }

    /// Read the cached recap for the ISO week containing `referenceDate` from
    /// `vault/wiki/weekly/{isoWeek}.md`. Returns nil when the file does not
    /// exist or cannot be parsed.
    public func loadCached(for referenceDate: Date) -> WeeklyRecapOutput? {
        let calendar = Self.weekCalendar
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
            return nil
        }
        let weekStart = calendar.startOfDay(for: interval.start)
        let isoWeek = Self.isoWeekKey(for: weekStart)
        let url = Self.weeklyURL(isoWeek: isoWeek)
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return Self.parseCachedFile(content)
    }

    // MARK: - Prompt

    /// System prompt for the weekly recap engine. Kept narrow so the model
    /// doesn't reach for follow-up text outside the JSON envelope.
    public static let systemPrompt = "你是 DayPage 的周回顾助手。仅输出符合用户 prompt 中 JSON schema 的单个 JSON 对象，使用 ```json``` 包裹，不要任何额外说明。"

    public static func buildPrompt(metadataJSON: String) -> String {
        return """
        基于以下 7 天日记元数据，为本周生成一份温和、简洁的回顾。

        输入数据（JSON）：
        \(metadataJSON)

        请严格按以下 JSON schema 返回（用 ```json``` 代码块包裹）：
        {
          "keywords": ["标签1", "标签2", "标签3"],
          "moodNotes": "1-2 句话，描述本周心情走势",
          "placeNotes": "1-2 句话，描述本周地点足迹",
          "highlights": ["高光1", "高光2", "高光3"],
          "reflectionQuestions": ["问题1", "问题2", "问题3"]
        }

        约束：
        - keywords 3-5 个，提炼本周关键主题
        - highlights 2-4 条，本周值得记住的事
        - reflectionQuestions 3-5 个复盘问句（Issue #9）。要求：
            * 每个 15-30 个汉字
            * 直接由本周材料触发，可以引用具体地点/人/事件
            * 用第二人称，不给答案，只给方向
            * 避免"你觉得如何"这种空问，要具体到"这周你为 X 犹豫了多次，下周想留意什么？"
        - 全部使用第二人称（你），不要客套话
        """
    }

    // MARK: - Parse

    /// Parse the LLM response. Static so tests can call without the singleton.
    public static func parse(
        llmResponse: String,
        isoWeek: String,
        weekStart: String,
        weekEnd: String,
        compiledAt: Date
    ) throws -> WeeklyRecapOutput {
        guard let jsonBlock = extractJSONBlock(from: llmResponse),
              let data = jsonBlock.data(using: .utf8) else {
            throw WeeklyCompilationError.parseFailed("找不到 JSON 块")
        }
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WeeklyCompilationError.parseFailed("JSON 顶层不是对象")
            }
            json = parsed
        } catch let err as WeeklyCompilationError {
            throw err
        } catch {
            throw WeeklyCompilationError.parseFailed(error.localizedDescription)
        }

        let keywords = (json["keywords"] as? [String])?.filter { !$0.isEmpty } ?? []
        let mood = (json["moodNotes"] as? String) ?? ""
        let place = (json["placeNotes"] as? String) ?? ""
        let highlights = (json["highlights"] as? [String])?.filter { !$0.isEmpty } ?? []
        // Issue #9: reflection questions are optional so pre-Issue-9 LLM
        // responses (or a model that decides the week doesn't warrant
        // questions) don't hard-fail parsing.
        let reflectionQuestions = (json["reflectionQuestions"] as? [String])?.filter { !$0.isEmpty } ?? []

        guard !keywords.isEmpty || !mood.isEmpty || !place.isEmpty || !highlights.isEmpty else {
            throw WeeklyCompilationError.parseFailed("响应字段全为空")
        }

        return WeeklyRecapOutput(
            isoWeek: isoWeek,
            dateRange: "\(weekStart) to \(weekEnd)",
            compiledAt: compiledAt,
            keywords: keywords,
            moodNotes: mood,
            placeNotes: place,
            highlights: highlights,
            reflectionQuestions: reflectionQuestions
        )
    }

    /// Parse a previously-written `vault/wiki/weekly/{isoWeek}.md` cache file.
    /// Returns nil when the file is malformed; callers fall through to
    /// recompile in that case.
    public static func parseCachedFile(_ content: String) -> WeeklyRecapOutput? {
        guard let isoWeek = FrontmatterParser.extractFieldInBlock("isoWeek", from: content),
              let dateRange = FrontmatterParser.extractFieldInBlock("dateRange", from: content) else {
            return nil
        }
        let compiledAtStr = FrontmatterParser.extractFieldInBlock("compiledAt", from: content)
        let compiledAt = compiledAtStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        let keywords = extractMarkdownList(section: "本周关键词", from: content)
        let moodNotes = extractMarkdownParagraph(section: "本周心情", from: content)
        let placeNotes = extractMarkdownParagraph(section: "本周地点", from: content)
        let highlights = extractMarkdownList(section: "本周高光", from: content)
        // Issue #9: reflection questions are appended as "## 本周 5 问"
        // (see `buildMarkdown`). Files written before Issue #9 shipped
        // simply return `[]` here.
        let reflectionQuestions = extractMarkdownList(section: "本周 5 问", from: content)
        // Issue #14: same pattern for outliers.
        let outliers = extractMarkdownList(section: "值得回看的孤峰", from: content)

        return WeeklyRecapOutput(
            isoWeek: isoWeek,
            dateRange: dateRange,
            compiledAt: compiledAt,
            keywords: keywords,
            moodNotes: moodNotes,
            placeNotes: placeNotes,
            highlights: highlights,
            reflectionQuestions: reflectionQuestions,
            outliers: outliers
        )
    }

    // MARK: - Persist

    private func write(output: WeeklyRecapOutput) throws {
        let url = Self.weeklyURL(isoWeek: output.isoWeek)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Backup existing file before overwriting — mirrors CompilationService.
        if fm.fileExists(atPath: url.path) {
            let trashDir = dir.appendingPathComponent(".trash")
            if !fm.fileExists(atPath: trashDir.path) {
                try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            }
            let ts = Self.backupTimestampFormatter.string(from: Date())
            let backup = trashDir.appendingPathComponent("\(output.isoWeek)_\(ts).md")
            try fm.copyItem(at: url, to: backup)
        }

        let body = Self.renderMarkdown(output: output)
        try RawStorage.atomicWrite(string: body, to: url)
    }

    public static func renderMarkdown(output: WeeklyRecapOutput) -> String {
        let isoString = ISO8601DateFormatter.memo.string(from: output.compiledAt)
        var lines: [String] = []
        lines.append("---")
        lines.append("type: weekly_recap")
        lines.append("isoWeek: \(output.isoWeek)")
        lines.append("dateRange: \(output.dateRange)")
        lines.append("compiledAt: \(isoString)")
        lines.append("---")
        lines.append("")
        lines.append("# \(output.isoWeek) 周回顾")
        lines.append("")
        lines.append("## 本周关键词")
        for kw in output.keywords { lines.append("- \(kw)") }
        lines.append("")
        lines.append("## 本周心情")
        lines.append(output.moodNotes)
        lines.append("")
        lines.append("## 本周地点")
        lines.append(output.placeNotes)
        lines.append("")
        lines.append("## 本周高光")
        for hl in output.highlights { lines.append("- \(hl)") }
        lines.append("")
        // Issue #9 (2026-07-03): only emit the reflection section when the
        // LLM actually produced questions — an empty header would look
        // like a load failure.
        if !output.reflectionQuestions.isEmpty {
            lines.append("## 本周 5 问")
            for q in output.reflectionQuestions { lines.append("- \(q)") }
            lines.append("")
        }
        // Issue #14 (2026-07-03): 孤峰 section. Only emit when the
        // ranking actually surfaced something so the header doesn't hang
        // over an empty list.
        if !output.outliers.isEmpty {
            lines.append("## 值得回看的孤峰")
            for o in output.outliers { lines.append("- \(o)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Issue #14 · Outlier computation

    /// Ranks raw memos across the 7 days ending at `referenceDate` and
    /// returns up to 3 "孤峰" — low-frequency, high-signal moments that
    /// the LLM's highlight list is likely to skip. The ranking blends:
    ///
    ///   * length: longer than the week's median × 2
    ///   * timing: created between 00:00 and 05:00 local
    ///   * emotional keyword density (approximated by a small Chinese
    ///     mood-word list; deliberately conservative to avoid false
    ///     positives on task-list memos)
    ///
    /// The ranking is deterministic — same inputs, same output — so a
    /// weekly re-compile does not shuffle chips around under the user.
    static func computeWeeklyOutliers(referenceDate: Date) -> [String] {
        let calendar = weekCalendar
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
            return []
        }
        let weekStart = calendar.startOfDay(for: interval.start)

        var candidates: [(memo: Memo, score: Double, date: Date)] = []
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let memos = (try? RawStorage.read(for: date)) ?? []
            candidates.append(contentsOf: memos.map { (memo: $0, score: 0.0, date: date) })
        }
        guard !candidates.isEmpty else { return [] }

        let lengths = candidates.map { $0.memo.body.count }.sorted()
        let median = lengths[lengths.count / 2]
        let moodWords: Set<Character> = ["累", "焦", "喜", "怒", "悲", "怕", "苦", "乐", "烦", "静", "醒", "困"]

        for i in candidates.indices {
            var score: Double = 0
            let m = candidates[i].memo
            let body = m.body
            let charCount = body.count
            if charCount > max(140, median * 2) { score += 2.0 }
            let hour = calendar.component(.hour, from: m.created)
            if hour < 5 { score += 2.0 }
            let moodHits = body.filter { moodWords.contains($0) }.count
            if moodHits >= 3 { score += 1.5 }
            candidates[i].score = score
        }

        let ranked = candidates.filter { $0.score >= 2.0 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.memo.created > $1.memo.created
            }
            .prefix(3)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        return ranked.map { c in
            let snippet = c.memo.body
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(48)
            return "\(df.string(from: c.memo.created)) · \(snippet)"
        }
    }

    // MARK: - Helpers

    /// Canonical ISO-8601 week key, e.g. "2026-W26". Static so tests can pin
    /// boundaries without instantiating the singleton.
    public static func isoWeekKey(for date: Date) -> String {
        let cal = weekCalendar
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard let year = comps.yearForWeekOfYear, let week = comps.weekOfYear else {
            return "0000-W00"
        }
        return String(format: "%04d-W%02d", year, week)
    }

    public static func weeklyURL(isoWeek: String) -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("weekly")
            .appendingPathComponent("\(isoWeek).md")
    }

    /// Calendar used for ISO-8601 week math. firstWeekday=2 (Monday),
    /// minimumDaysInFirstWeek=4 — mirrors `WeeklyRecapService` and ISO
    /// 8601 to keep the boundary identical across the two surfaces.
    public static var weekCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    public static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    public static let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - Frontmatter list extraction

    /// Best-effort list extraction for `entities:` / `locations:` style
    /// frontmatter fields. Supports both inline `entities: [a, b]` and the
    /// block YAML `entities:\n  - a\n  - b` forms.
    public static func extractList(_ key: String, from content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        let prefix = "\(key):"
        var inBlock = false
        var inFrontmatter = false
        var results: [String] = []
        for (idx, raw) in lines.enumerated() {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if idx == 0 {
                guard trimmed == "---" else { return [] }
                inFrontmatter = true
                continue
            }
            if inFrontmatter && trimmed == "---" { break }
            if inBlock {
                if trimmed.hasPrefix("- ") {
                    let v = String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        .trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { results.append(v) }
                    continue
                } else if trimmed.contains(":") {
                    // Hit next key — exit block mode.
                    inBlock = false
                }
            }
            if trimmed.hasPrefix(prefix) {
                let value = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    let inner = value.dropFirst().dropLast()
                    return inner.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                        .filter { !$0.isEmpty }
                }
                if value.isEmpty {
                    inBlock = true
                    continue
                }
                // Single scalar value masquerading as a list.
                let scalar = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return scalar.isEmpty ? [] : [scalar]
            }
        }
        return results
    }

    // MARK: - Markdown parsing for cache file

    private static func extractMarkdownList(section: String, from content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        let header = "## \(section)"
        var inSection = false
        var results: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header { inSection = true; continue }
            if inSection {
                if trimmed.hasPrefix("## ") { break }
                if trimmed.hasPrefix("- ") {
                    let v = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { results.append(v) }
                }
            }
        }
        return results
    }

    private static func extractMarkdownParagraph(section: String, from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let header = "## \(section)"
        var inSection = false
        var buffer: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header { inSection = true; continue }
            if inSection {
                if trimmed.hasPrefix("## ") { break }
                if trimmed.hasPrefix("- ") { continue }
                if !trimmed.isEmpty { buffer.append(trimmed) }
            }
        }
        return buffer.joined(separator: " ")
    }

    // MARK: - JSON extraction

    /// Lifted from ``CompilationService.extractJSONBlockStatic`` so weekly
    /// keeps an identical fence-then-brace strategy without forcing the
    /// daily helper to become public.
    public static func extractJSONBlock(from text: String) -> String? {
        let fencePatterns = ["```json\n", "```json \n", "```JSON\n", "```\n"]
        for pattern in fencePatterns {
            if let fenceStart = text.range(of: pattern, options: .caseInsensitive),
               let fenceEnd = text.range(of: "\n```", range: fenceStart.upperBound ..< text.endIndex) {
                return String(text[fenceStart.upperBound ..< fenceEnd.lowerBound])
            }
        }
        if let braceStart = text.firstIndex(of: "{"),
           let braceEnd = text.lastIndex(of: "}") {
            return String(text[braceStart ... braceEnd])
        }
        return nil
    }

    // MARK: - Error mapping

    private static func mapLLMError(_ error: LLMError) -> WeeklyCompilationError {
        switch error {
        case .missingApiKey:      return .missingApiKey
        case .offline:            return .offline
        case .networkTimeout:     return .networkTimeout
        case .rateLimited:        return .apiRateLimited
        case .apiError(let c, let b): return .apiError(statusCode: c, body: b)
        case .emptyResponse:      return .parseFailed("LLM 返回为空")
        case .invalidURL:         return .parseFailed("LLM URL 无效")
        case .unknown(let err):   return .unknown(err)
        }
    }
}
