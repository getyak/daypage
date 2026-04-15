import Foundation

// MARK: - CompilationService

/// Compiles today's raw memos into a structured Daily Page via DashScope LLM API.
///
/// Responsibilities:
///   1. Read vault/raw/YYYY-MM-DD.md (all memos) + vault/wiki/hot.md (context)
///   2. Call DashScope chat completions (OpenAI-compatible)
///   3. Write compiled output to vault/wiki/daily/YYYY-MM-DD.md
///      (backs up existing file before overwrite)
///   4. Append a row to vault/wiki/log.md
///
/// Usage:
///   let service = CompilationService.shared
///   try await service.compile(for: Date())
///
@MainActor
final class CompilationService {

    // MARK: Singleton

    static let shared = CompilationService()
    private init() {}

    // MARK: - Compile

    /// Compiles the raw memos for the given date into a Daily Page.
    /// - Parameter date: The date to compile. Defaults to today.
    /// - Parameter trigger: How the compilation was triggered ("manual" | "auto").
    /// - Throws: `CompilationError` on API, parsing, or file-system failures.
    func compile(for date: Date = Date(), trigger: String = "manual") async throws {
        let startTime = Date()
        let dateString = dateFormatter.string(from: date)

        // 1. Load raw memos
        let memos = try RawStorage.read(for: date)
        let rawContent = rawFileContent(for: date)

        // 2. Load hot.md context
        let hotContent = loadHotContent()

        // 3. Build prompt
        let prompt = buildPrompt(
            dateString: dateString,
            rawContent: rawContent,
            hotContent: hotContent,
            memoCount: memos.count
        )

        // 4. Call DashScope API
        let apiKey = Secrets.dashScopeApiKey
        guard !apiKey.isEmpty else {
            throw CompilationError.missingApiKey
        }

        let compiledText = try await callDashScope(prompt: prompt, apiKey: apiKey)

        // 5. Parse structured output (Daily Page + Entity update instructions)
        let (dailyPageText, entityInstructions) = EntityPageService.parseStructuredOutput(compiledText)

        // 6. Write Daily Page (backup existing if present)
        let dailyURL = dailyPageURL(for: dateString)
        try backupIfExists(at: dailyURL, dateString: dateString)
        try writeFile(content: dailyPageText, to: dailyURL)

        // 7. Apply entity updates
        try EntityPageService.shared.apply(instructions: entityInstructions, date: dateString)

        // 8. Append to log.md
        let elapsed = Date().timeIntervalSince(startTime)
        appendLog(
            timestamp: iso8601Now(),
            trigger: trigger,
            durationSeconds: elapsed,
            memoCount: memos.count,
            status: "success"
        )
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
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadHotContent() -> String {
        let url = hotURL()
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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

        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let updated = existing + row
            try? RawStorage.atomicWrite(string: updated, to: url)
        } else {
            let header = "---\ntype: compilation_log\ncreated: \(timestamp)\n---\n\n# Compilation Log\n\n| timestamp | trigger | duration_s | memo_count | status |\n|-----------|---------|-----------|------------|--------|\n\(row)"
            try? RawStorage.atomicWrite(string: header, to: url)
        }
    }

    // MARK: - Prompt Builder

    private func buildPrompt(
        dateString: String,
        rawContent: String,
        hotContent: String,
        memoCount: Int
    ) -> String {
        """
        You are DayPage's AI compilation engine. Compile today's raw memos into a structured Daily Page and identify entities (places, people, themes) for the wiki.

        ## Date
        \(dateString)

        ## Short-term memory context (hot.md)
        \(hotContent.isEmpty ? "(no hot cache yet)" : hotContent)

        ## Today's raw memos (\(memoCount) entries)
        \(rawContent.isEmpty ? "(no memos today)" : rawContent)

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
          ]
        }
        ```

        ### daily_page format (inside the JSON string, use \\n for newlines):

        ---
        type: daily
        date: \(dateString)
        location_primary: <primary location name or "Unknown">
        mood: <one-word mood in Chinese>
        entries_count: \(memoCount)
        summary: "<one-sentence summary in Chinese, max 50 chars>"
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

        ### General rules:
        - Write daily_page entirely in Chinese
        - Output ONLY the JSON object, no additional commentary
        - Ensure the JSON is valid (escape quotes and newlines properly inside strings)
        """
    }

    // MARK: - DashScope API

    private func callDashScope(prompt: String, apiKey: String) async throws -> String {
        let baseURL = Secrets.dashScopeBaseURL.isEmpty
            ? "https://coding.dashscope.aliyuncs.com/v1"
            : Secrets.dashScopeBaseURL
        let model = Secrets.dashScopeModel.isEmpty ? "qwen3.5-plus" : Secrets.dashScopeModel

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
                ["role": "system", "content": "You are DayPage, a personal diary AI compiler. Output only valid Markdown, no extra commentary."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 2048,
            "temperature": 0.7
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CompilationError.networkError("No HTTP response")
        }

        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "(empty)"
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

    // MARK: - Date Formatters

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
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

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "DashScope API Key 未配置，请检查 .env 文件"
        case .invalidURL:
            return "DashScope API URL 无效"
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
        }
    }
}
