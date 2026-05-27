import Foundation
import Network
import Sentry

// MARK: - CompilationStage

/// Progress stages published during a compile run.
enum CompilationStage: String, CaseIterable, Equatable {
    case extracting
    case compiling
    case formatting
    case done
}

// MARK: - CompilationService

/// 通过 DeepSeek LLM API 将今天的原始备忘录编译为结构化的每日页面。
///
/// 职责：
///   1. 读取 vault/raw/YYYY-MM-DD.md（所有备忘录）+ vault/wiki/hot.md（上下文）
///   2. 调用 DeepSeek 聊天补全接口（兼容 OpenAI 格式）
///   3. 将编译结果写入 vault/wiki/daily/YYYY-MM-DD.md
///      （覆盖前会备份现有文件）
///   4. 在 vault/wiki/log.md 中追加一行日志
///
/// 使用方式：
///   let service = CompilationService.shared
///   try await service.compile(for: Date())
///
@MainActor
final class CompilationService: ObservableObject {

    // MARK: Singleton

    static let shared = CompilationService()
    private init() {}

    // MARK: - Published Stage

    @Published var stage: CompilationStage = .extracting
    @Published var compilationProgress: CompilationStage = .extracting

    // MARK: - Compile

    /// 将给定日期的原始备忘录编译为每日页面。
    /// - Parameter date: 要编译的日期，默认为今天。
    /// - Parameter trigger: 编译触发方式（"manual" | "auto"）。
    /// - Parameter onRetry: 每次重试前调用，参数为 (当前次数, 最大次数)。
    /// - Throws: 当 API、解析或文件系统失败时抛出 `CompilationError`。
    func compile(
        for date: Date = Date(),
        trigger: String = "manual",
        onRetry: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard NetworkMonitor.shared.isOnline else {
            throw CompilationError.offline
        }

        let startTime = Date()
        let dateString = dateFormatter.string(from: date)

        // Step 1: Collect memos
        stage = .extracting
        compilationProgress = .extracting
        let (memos, rawContent) = try collectMemos(for: date)
        let hotContent = loadHotContent()

        // Step 2: Build prompt
        let prompt = buildPrompt(
            dateString: dateString,
            rawContent: rawContent,
            hotContent: hotContent,
            memoCount: memos.count
        )

        // Step 3: Call AI
        stage = .compiling
        compilationProgress = .compiling
        let compiledText = try await callAI(prompt: prompt, onRetry: onRetry)

        // Step 4: Parse response
        stage = .formatting
        compilationProgress = .formatting
        let parsed = try parseResponse(compiledText)

        // Step 5: Save results
        try saveResults(parsed, dateString: dateString, trigger: trigger, startTime: startTime, memoCount: memos.count)

        stage = .done
        compilationProgress = .done
    }

    // MARK: - Step 1: Collect Memos

    /// Reads today's raw memos and the raw file content string.
    /// - Returns: `(memos, rawFileContent)`
    private func collectMemos(for date: Date) throws -> ([Memo], String) {
        let memos: [Memo]
        do {
            memos = try RawStorage.read(for: date)
        } catch {
            throw CompilationError.parseFailure("读取原始备忘录失败：\(error.localizedDescription)")
        }
        guard !memos.isEmpty else {
            throw CompilationError.emptyInput
        }
        let rawContent = rawFileContent(for: date)
        return (memos, rawContent)
    }

    // MARK: - Step 3: Call AI

    /// Calls the AI API with retry, returning the raw LLM response string.
    private func callAI(prompt: String, onRetry: ((Int, Int) -> Void)?) async throws -> String {
        let apiKey = Secrets.resolvedDeepSeekApiKey
        guard !apiKey.isEmpty else {
            throw CompilationError.missingApiKey
        }
        do {
            return try await callDeepSeekWithRetry(prompt: prompt, apiKey: apiKey, onRetry: onRetry)
        } catch let err as CompilationError {
            throw err
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            throw CompilationError.networkTimeout
        } catch {
            throw CompilationError.unknown(error)
        }
    }

    // MARK: - Step 4: Parse Response

    /// Per-memo annotation extracted from the LLM response.
    struct MemoUpdateInstruction {
        let memoID: UUID
        let mood: String?
        let entityMentions: [String]
        let dateReferences: [String]
    }

    /// Parsed output from the LLM response.
    struct ParsedCompilationOutput {
        let dailyPageText: String
        let entityInstructions: [EntityUpdateInstruction]
        let memoUpdates: [MemoUpdateInstruction]
        let hotCacheText: String
    }

    /// Parses the LLM response into structured components.
    private func parseResponse(_ rawLLMResponse: String) throws -> ParsedCompilationOutput {
        let (dailyPageText, entityInstructions, hotCacheText): (String, [EntityUpdateInstruction], String)
        do {
            (dailyPageText, entityInstructions, hotCacheText) = try parseStructuredOutputWithHot(rawLLMResponse)
        } catch let err as CompilationError {
            throw err
        } catch {
            throw CompilationError.parseFailure(error.localizedDescription)
        }
        let memoUpdates = extractMemoUpdates(rawLLMResponse)
        return ParsedCompilationOutput(
            dailyPageText: dailyPageText,
            entityInstructions: entityInstructions,
            memoUpdates: memoUpdates,
            hotCacheText: hotCacheText
        )
    }

    /// Extracts per-memo mood + entity mention + date reference annotations from
    /// the `memo_updates` array in the LLM JSON response.
    private func extractMemoUpdates(_ rawLLMResponse: String) -> [MemoUpdateInstruction] {
        guard let jsonBlock = Self.extractJSONBlockStatic(from: rawLLMResponse),
              let data = jsonBlock.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updates = json["memo_updates"] as? [[String: Any]] else { return [] }

        var results: [MemoUpdateInstruction] = []
        for update in updates {
            guard let idStr = update["memo_id"] as? String,
                  let uuid = UUID(uuidString: idStr) else { continue }
            let mood = (update["mood"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let entityMentions = (update["entity_mentions"] as? [String]) ?? []
            let dateReferences = (update["date_references"] as? [String]) ?? []
            guard mood != nil || !entityMentions.isEmpty || !dateReferences.isEmpty else { continue }
            results.append(MemoUpdateInstruction(
                memoID: uuid,
                mood: mood,
                entityMentions: entityMentions,
                dateReferences: dateReferences
            ))
        }
        return results
    }

    private static func extractJSONBlockStatic(from text: String) -> String? {
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

    // MARK: - Step 5: Save Results

    /// Persists the compiled daily page, entity updates, hot cache, and log entry.
    private func saveResults(
        _ parsed: ParsedCompilationOutput,
        dateString: String,
        trigger: String,
        startTime: Date,
        memoCount: Int
    ) throws {
        let dailyURL = dailyPageURL(for: dateString)
        do {
            try backupIfExists(at: dailyURL, dateString: dateString)
            try writeFile(content: parsed.dailyPageText, to: dailyURL)
        } catch let err as CompilationError {
            throw err
        } catch {
            throw CompilationError.fileSystemError(error.localizedDescription)
        }

        try EntityPageService.shared.apply(instructions: parsed.entityInstructions, date: dateString)
        applyMemoUpdates(parsed.memoUpdates, dateString: dateString)
        updateHotCache(summary: parsed.hotCacheText, compiledDate: dateString)

        let elapsed = Date().timeIntervalSince(startTime)
        appendLog(
            timestamp: iso8601Now(),
            trigger: trigger,
            durationSeconds: elapsed,
            memoCount: memoCount,
            status: "success"
        )
    }

    /// Back-fills mood and entityMentions into the raw memo file for each MemoUpdateInstruction.
    /// Non-fatal: failures are logged but do not abort compilation.
    private func applyMemoUpdates(_ updates: [MemoUpdateInstruction], dateString: String) {
        guard !updates.isEmpty else { return }
        guard let date = ISO8601DateFormatter.dayOnly.date(from: dateString) else { return }

        let rawURL = RawStorage.fileURL(for: date)

        var memos: [Memo]
        do { memos = try RawStorage.read(for: date) }
        catch { DayPageLogger.shared.error("applyMemoUpdates: read failed: \(error)"); return }
        guard !memos.isEmpty else { return }

        var changed = false
        for update in updates {
            guard let idx = memos.firstIndex(where: { $0.id == update.memoID }) else { continue }
            var memo = memos[idx]
            if let mood = update.mood, !mood.isEmpty {
                memo.mood = mood
                changed = true
            }
            if !update.entityMentions.isEmpty {
                let merged = Array(Set(memo.entityMentions + update.entityMentions)).sorted()
                if merged != memo.entityMentions {
                    memo.entityMentions = merged
                    changed = true
                }
            }
            memos[idx] = memo
        }

        guard changed else { return }
        let newContent = memos.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
        do {
            try RawStorage.atomicWrite(string: newContent, to: rawURL)
        } catch {
            DayPageLogger.shared.error("applyMemoUpdates: failed to write raw file: \(error)")
        }
    }

    // MARK: - URL Helpers

    private func dailyPageURL(for dateString: String) -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")
    }

    private func trashURL(for dateString: String, timestamp: String) -> URL {
        let trashDir = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent(".trash")
        return trashDir.appendingPathComponent("\(dateString)_\(timestamp).md")
    }

    private func hotURL() -> URL {
        VaultInitializer.vaultURL.appendingPathComponent("wiki").appendingPathComponent("hot.md")
    }

    private func logURL() -> URL {
        VaultInitializer.vaultURL.appendingPathComponent("wiki").appendingPathComponent("log.md")
    }

    // MARK: - File Helpers

    private func rawFileContent(for date: Date) -> String {
        let url = RawStorage.fileURL(for: date)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            DayPageLogger.shared.error("rawFileContent: \(error)")
            return ""
        }
    }

    private func loadHotContent() -> String {
        let url = hotURL()
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            DayPageLogger.shared.info("loadHotContent: no hot cache yet")
            return ""
        }
    }

    private func backupIfExists(at url: URL, dateString: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Create .trash directory if needed
        let trashDir = url.deletingLastPathComponent().appendingPathComponent(".trash")
        if !FileManager.default.fileExists(atPath: trashDir.path) {
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        }

        // Build a compact timestamp: YYYYMMDDHHmmss
        let ts = backupTimestampFormatter.string(from: Date())
        let backup = trashURL(for: dateString, timestamp: ts)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private func writeFile(content: String, to url: URL) throws {
        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try RawStorage.atomicWrite(string: content, to: url)
    }

    // MARK: - Log

    private func appendLog(
        timestamp: String,
        trigger: String,
        durationSeconds: TimeInterval,
        memoCount: Int,
        status: String
    ) {
        let url = logURL()
        let durationStr = String(format: "%.1f", durationSeconds)
        let row = "| \(timestamp) | \(trigger) | \(durationStr) | \(memoCount) | \(status) |\n"

        let existing: String?
        do {
            existing = try String(contentsOf: url, encoding: .utf8)
        } catch {
            existing = nil // 文件可能尚不存在 — 不是错误
        }
        if let prev = existing {
            let updated = prev + row
            do {
                try RawStorage.atomicWrite(string: updated, to: url)
            } catch {
                DayPageLogger.shared.error("appendLog: failed to write compilation log: \(error)")
            }
        } else {
            let header = "---\ntype: compilation_log\ncreated: \(timestamp)\n---\n\n# Compilation Log\n\n| timestamp | trigger | duration_s | memo_count | status |\n|-----------|---------|-----------|------------|--------|\n\(row)"
            do {
                try RawStorage.atomicWrite(string: header, to: url)
            } catch {
                DayPageLogger.shared.error("appendLog: failed to create compilation log: \(error)")
            }
        }
    }

    // MARK: - Prompt Builder

    private func buildPrompt(
        dateString: String,
        rawContent: String,
        hotContent: String,
        memoCount: Int
    ) -> String {
        let maxRawChars = 28_000
        let truncatedRaw = rawContent.count > maxRawChars
            ? "...[earlier memos truncated]\n" + String(rawContent.suffix(maxRawChars))
            : rawContent
        return """
        You are DayPage's AI compilation engine. Compile today's raw memos into a structured Daily Page and identify entities (places, people, themes) for the wiki.

        ## Date
        \(dateString)
        \(dateContextNote(for: dateString))

        ## Short-term memory context (hot.md)
        <hot_cache>
        \(hotContent.isEmpty ? "(no hot cache yet)" : hotContent)
        </hot_cache>

        ## Today's raw memos (\(memoCount) entries)
        <user_memos>
        \(truncatedRaw.isEmpty ? "(no memos today)" : truncatedRaw)
        </user_memos>

        ## Output Requirements

        Respond with a single JSON object (no extra text outside the JSON):

        ```json
        {
          "daily_page": "<full Markdown Daily Page as a string>",
          "entity_updates": [
            {
              "entity_type": "places",
              "entity_slug": "joma-coffee",
              "display_name": "Joma Coffee",
              "section": "## Visits",
              "content": "- \(dateString): <brief note>"
            }
          ],
          "memo_updates": [
            {
              "memo_id": "<UUID from the memo's id: field>",
              "mood": "<one-word mood in Chinese, e.g. 愉快>",
              "entity_mentions": ["slug-one", "slug-two"],
              "date_references": ["2026-01-10", "last week"]
            }
          ],
          "hot_cache": "<short-term memory summary in Chinese, ~500 chars>"
        }
        ```

        ### daily_page format (inside the JSON string, use \\n for newlines):

        ---
        type: daily
        date: \(dateString)
        location_primary: <primary location name or "Unknown">
        mood: <one-word mood in Chinese inferred from overall day tone, e.g. 平静、焦虑、愉快、疲惫、充实、迷茫、兴奋>
        entries_count: \(memoCount)
        summary: "<one-sentence summary in Chinese, max 50 chars>"
        cover: <optional: vault-relative path of the best photo attachment from today's memos, e.g. "raw/assets/photo_20260414_093000.jpg"; omit the line entirely if no photos exist>
        ---

        # \(dateString.uppercased())

        <one-sentence summary>

        ## MORNING
        <narrative paragraph synthesizing morning memos>

        ## AFTERNOON
        <narrative paragraph synthesizing afternoon memos>

        ## EVENING
        <narrative paragraph synthesizing evening memos>

        ## LOCATIONS TODAY
        - [[location-slug]]: Brief note

        ## AI FOLLOW-UP
        > Question 1: <thoughtful follow-up question>
        > Question 2: <second follow-up question>
        > Question 3: <third follow-up question>

        ---
        *Compiled from \(memoCount) raw entries*

        ### entity_updates rules:
        - entity_type must be one of: "places", "people", "themes"
        - entity_slug: lowercase, hyphens only, no spaces (e.g. "joma-coffee")
        - display_name: human-readable name (e.g. "Joma Coffee")
        - section: Markdown heading for the content block (e.g. "## Visits", "## Mentions", "## Notes")
        - content: Markdown content to append under that section
        - Include all notable places, people, and themes mentioned in the memos
        - Entity references in daily_page use [[slug]] format

        ### memo_updates rules:
        - memo_id: the exact UUID from the memo's `id:` YAML field
        - mood: one Chinese word capturing this memo's emotional tone (e.g. 愉快、焦虑、平静、兴奋)
        - entity_mentions: list of entity slugs (lowercase-hyphenated) explicitly or implicitly referenced in this memo
        - date_references: any explicit date strings or relative date expressions found in the memo body (e.g. "2026-01-10", "上周", "明天")
        - Only include entries for memos where at least one field is non-empty
        - Omit memo_updates entirely if no memos have extractable mood or date references

        ### hot_cache format (inside the JSON string, use \\n for newlines):
        Write ~500 Chinese characters covering:
        1. 当前所在城市或地区
        2. 最近 3-5 天的情绪基调与状态
        3. 活跃中的主题线索或项目进展
        4. 值得关注的行为模式或规律
        This text will be stored in wiki/hot.md and fed back to the AI compiler next time.

        ### General rules:
        - Write daily_page and hot_cache entirely in Chinese
        - Output ONLY the JSON object, no additional commentary
        - Ensure the JSON is valid (escape quotes and newlines properly inside strings)
        """
    }

    // MARK: - Date Context

    /// Returns a short natural-language note about the day type so the LLM can
    /// tone the narrative appropriately (weekend vs. weekday vs. public holiday).
    private func dateContextNote(for dateString: String) -> String {
        guard let date = ISO8601DateFormatter.dayOnly.date(from: dateString) else { return "" }
        var cal = Calendar.current
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekday = cal.component(.weekday, from: date)
        // weekday: 1=Sun, 7=Sat
        switch weekday {
        case 1: return "Day type: Sunday (weekend — relaxed tone expected)"
        case 7: return "Day type: Saturday (weekend — relaxed tone expected)"
        default:
            let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "Day type: \(dayNames[weekday]) (weekday — may involve work/routine context)"
        }
    }

    // MARK: - DeepSeek API (with retry)

    private func callDeepSeekWithRetry(
        prompt: String,
        apiKey: String,
        onRetry: ((Int, Int) -> Void)?
    ) async throws -> String {
        let maxAttempts = 3
        let backoffSeconds: [Double] = [0, 2, 6]
        var lastError: Error = CompilationError.networkError("Unknown")

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                onRetry?(attempt, maxAttempts)
                let delay = backoffSeconds[min(attempt - 1, backoffSeconds.count - 1)]
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            do {
                return try await callDeepSeek(prompt: prompt, apiKey: apiKey)
            } catch let error as CompilationError {
                switch error {
                case .apiError(let code, _) where code == 429:
                    lastError = CompilationError.apiRateLimited
                case .apiError(let code, _) where code == 401 || code == 403 || code == 400:
                    throw error // 不重试认证/请求格式错误
                case .parseError(let msg):
                    throw CompilationError.parseFailure(msg) // 不重试解析错误
                case .parseFailure:
                    throw error
                case .missingApiKey, .invalidURL:
                    throw error
                default:
                    lastError = error
                }
            } catch let urlError as URLError {
                switch urlError.code {
                case .timedOut:
                    lastError = CompilationError.networkTimeout
                case .notConnectedToInternet, .networkConnectionLost:
                    lastError = urlError
                default:
                    throw urlError
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func callDeepSeek(prompt: String, apiKey: String) async throws -> String {
        let baseURL = Secrets.deepSeekBaseURL.isEmpty
            ? "https://api.deepseek.com/v1"
            : Secrets.deepSeekBaseURL
        let model = Secrets.deepSeekModel.isEmpty ? "deepseek-v4-pro" : Secrets.deepSeekModel

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw CompilationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are DayPage's AI compilation engine. Output only a single valid JSON object as specified in the user prompt. No extra commentary outside the JSON."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 4096,
            "temperature": 0.7
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let span = Secrets.sentryDSN.isEmpty ? nil
            : SentrySDK.startTransaction(name: "compilation.deepseek", operation: "http.client")
        defer { span?.finish() }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            DayPageLogger.shared.error("[DeepSeek] status=- body=No HTTP response")
            throw CompilationError.networkError("No HTTP response")
        }

        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "(empty)"
            let snippet = String(bodyStr.prefix(500))
            DayPageLogger.shared.error("[DeepSeek] status=\(http.statusCode) body=\(snippet)")
            throw CompilationError.apiError(statusCode: http.statusCode, body: bodyStr)
        }

        return try parseCompletionContent(from: data)
    }

    private func parseCompletionContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CompilationError.parseError("Unexpected response structure")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Hot Cache

    /// 解析 LLM 结构化输出，提取每日页面、实体指令和热缓存。
    /// 当响应中无有效 JSON 或缺少 `daily_page` 时抛出 `parseError`。
    private func parseStructuredOutputWithHot(
        _ rawLLMResponse: String
    ) throws -> (dailyPage: String, instructions: [EntityUpdateInstruction], hotCache: String) {
        let (dailyPage, instructions) = EntityPageService.parseStructuredOutput(rawLLMResponse)
        guard !dailyPage.isEmpty else {
            throw CompilationError.parseError("LLM 响应中未找到有效 JSON 或缺少 daily_page 字段")
        }
        let hotCache = extractHotCacheFromJSON(rawLLMResponse) ?? ""
        return (dailyPage, instructions, hotCache)
    }

    /// 从 LLM 响应中的 JSON 块里提取 "hot_cache" 字符串。
    private func extractHotCacheFromJSON(_ text: String) -> String? {
        // 查找 JSON 块（逻辑与 EntityPageService 相同）
        let jsonBlock: String?
        if let fenceStart = text.range(of: "```json\n"),
           let fenceEnd = text.range(of: "\n```", range: fenceStart.upperBound ..< text.endIndex) {
            jsonBlock = String(text[fenceStart.upperBound ..< fenceEnd.lowerBound])
        } else if let braceStart = text.firstIndex(of: "{"),
                  let braceEnd = text.lastIndex(of: "}") {
            jsonBlock = String(text[braceStart ... braceEnd])
        } else {
            jsonBlock = nil
        }

        guard let block = jsonBlock,
              let data = block.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hotCache = json["hot_cache"] as? String,
              !hotCache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return hotCache.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用新的热缓存摘要覆盖 vault/wiki/hot.md。
    /// 保留 frontmatter 结构（updated_at、covers_dates）。
    /// 防止低质量覆盖：若新摘要字符数不足现有内容的 50%，跳过写入并记录警告。
    /// 覆盖前将现有文件备份至 .trash/（策略与每日页面一致）。
    private func updateHotCache(summary: String, compiledDate: String) {
        guard !summary.isEmpty else { return }

        let url = hotURL()
        let now = iso8601Now()

        // 构建 covers_dates：尽可能读取已有内容，然后追加 compiledDate
        var coveredDates: [String] = []
        var existingCharCount = 0
        do {
            let existing = try String(contentsOf: url, encoding: .utf8)
            coveredDates = parseCoversDates(from: existing)
            existingCharCount = existing.count
        } catch {
            // 首次编译时 hot.md 可能尚不存在
        }

        // 保护：若新摘要异常短（不足已有的 50%），跳过覆盖
        if existingCharCount > 0 && summary.count < existingCharCount / 2 {
            DayPageLogger.shared.warn("updateHotCache: new summary (\(summary.count) chars) is less than 50% of existing (\(existingCharCount) chars) — skipping overwrite to protect context")
            return
        }

        // 覆盖前备份现有 hot.md
        if FileManager.default.fileExists(atPath: url.path) {
            let trashDir = url.deletingLastPathComponent().appendingPathComponent(".trash")
            if !FileManager.default.fileExists(atPath: trashDir.path) {
                try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            }
            let ts = backupTimestampFormatter.string(from: Date())
            let backupURL = trashDir.appendingPathComponent("hot_\(ts).md")
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }

        if !coveredDates.contains(compiledDate) {
            coveredDates.append(compiledDate)
        }
        // 仅保留最近 7 个日期，防止无限增长
        if coveredDates.count > 7 {
            coveredDates = Array(coveredDates.suffix(7))
        }
        let coversYAML = coveredDates.map { "  - \($0)" }.joined(separator: "\n")

        let newContent = """
        ---
        type: hot_cache
        updated_at: \(now)
        covers_dates:
        \(coversYAML)
        ---

        # Hot Cache

        \(summary)
        """

        do {
            try RawStorage.atomicWrite(string: newContent, to: url)
        } catch {
            DayPageLogger.shared.error("updateHotCache: failed to write hot cache: \(error)")
        }
    }

    /// 解析 hot.md frontmatter 中的 covers_dates YAML 序列。
    private func parseCoversDates(from content: String) -> [String] {
        var dates: [String] = []
        var inFrontmatter = false
        var inCoversDates = false
        var closingFound = false

        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 && trimmed == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter && !closingFound && trimmed == "---" {
                closingFound = true
                break
            }
            if inFrontmatter {
                if trimmed.hasPrefix("covers_dates:") {
                    inCoversDates = true
                    continue
                }
                if inCoversDates {
                    if trimmed.hasPrefix("- ") {
                        dates.append(String(trimmed.dropFirst(2)))
                    } else if !trimmed.isEmpty {
                        // 新字段 — 停止收集日期
                        inCoversDates = false
                    }
                }
            }
        }
        return dates
    }

    // MARK: - Date Formatters

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f
    }()

    private let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f
    }()

    private func iso8601Now() -> String {
        ISO8601DateFormatter.memo.string(from: Date())
    }
}

// MARK: - CompilationError

enum CompilationError: LocalizedError {
    case missingApiKey
    case invalidURL
    case networkError(String)
    case apiError(statusCode: Int, body: String)
    case parseError(String)
    case fileSystemError(String)
    case offline
    // US-019 additions
    case networkTimeout
    case apiRateLimited
    case emptyInput
    case parseFailure(String)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "DeepSeek API Key 未配置，请检查 .env 文件"
        case .invalidURL:
            return "DeepSeek API URL 无效"
        case .networkError(let msg):
            return "网络错误：\(msg)"
        case .apiError(let code, let body):
            if code == 401 {
                return "API Key 无效或已过期（401）"
            } else if code == 429 {
                return "请求频率超限，请稍后重试（429）"
            }
            return "API 错误 \(code)：\(body.prefix(200))"
        case .parseError(let msg):
            return "LLM 返回格式错误：\(msg)"
        case .fileSystemError(let msg):
            return "文件写入失败：\(msg)"
        case .offline:
            return "当前离线，已加入队列，联网后自动编译"
        case .networkTimeout:
            return "网络请求超时，请检查网络后重试"
        case .apiRateLimited:
            return "API 请求频率超限（429），请稍后重试"
        case .emptyInput:
            return "今日暂无记录，无法编译"
        case .parseFailure(let msg):
            return "AI 返回解析失败：\(msg)"
        case .unknown(let err):
            return "未知错误：\(err.localizedDescription)"
        }
    }
}
