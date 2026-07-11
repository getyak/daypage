import Foundation
import CryptoKit
import DayPageModels
import DayPageStorage

// MARK: - CompileOutcome

/// Result of a compile request. `skippedUnchanged` means the source hash of
/// the day's memos matches the `source_hash` recorded in the existing daily
/// page frontmatter — no LLM call was made (issue #814 cost guard).
public enum CompileOutcome: Equatable {
    case compiled
    case skippedUnchanged
}

// MARK: - CompilationStage

/// Progress stages published during a compile run.
public enum CompilationStage: String, CaseIterable, Equatable {
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
public final class CompilationService: ObservableObject {

    // MARK: Singleton

    public static let shared = CompilationService()
    private init() {}

    // MARK: - Published Stage

    @Published public var stage: CompilationStage = .extracting
    @Published public var compilationProgress: CompilationStage = .extracting

    /// Number of memo back-fill updates that failed during the last
    /// compilation run. Published so the BG service / UI can surface
    /// partial-success state instead of silently misreporting success.
    /// Reset to 0 at the start of every compile.
    @Published public var lastMemoUpdateFailures: Int = 0

    // MARK: - Compile

    /// 将给定日期的原始备忘录编译为每日页面。
    /// - Parameter date: 要编译的日期，默认为今天。
    /// - Parameter trigger: 编译触发方式（"manual" | "auto"）。
    /// - Parameter force: 为 true 时跳过 source_hash 去重守卫，强制重新编译
    ///   （DailyPageView「重新编译」的显式意图）。
    /// - Parameter onRetry: 每次重试前调用，参数为 (当前次数, 最大次数)。
    /// - Returns: `.compiled` 或 `.skippedUnchanged`（内容未变，未调 LLM）。
    /// - Throws: 当 API、解析或文件系统失败时抛出 `CompilationError`。
    @discardableResult
    public func compile(
        for date: Date = Date(),
        trigger: String = "manual",
        force: Bool = false,
        onRetry: ((Int, Int) -> Void)? = nil
    ) async throws -> CompileOutcome {
        let startTime = Date()
        let dateString = dateFormatter.string(from: date)

        // Reset partial-failure tracking at the start of every run so the
        // BG service / UI can observe the latest result without stale data.
        lastMemoUpdateFailures = 0

        // Step 1: Collect memos.
        // Disk reads + YAML parse + SHA256 hop off the main actor: compile()
        // itself is @MainActor, and on a 20-memo day this prep block held the
        // main thread for tens of ms right as the user tapped 编译.
        stage = .extracting
        compilationProgress = .extracting
        let dailyURL = dailyPageURL(for: dateString)
        let (memos, rawContent, sourceHash, storedHash) =
            try await Task.detached(priority: .userInitiated) {
                let memos: [Memo]
                do {
                    memos = try RawStorage.read(for: date)
                } catch {
                    throw CompilationError.parseFailure("读取原始备忘录失败：\(error.localizedDescription)")
                }
                guard !memos.isEmpty else {
                    throw CompilationError.emptyInput
                }
                let rawContent = (try? String(contentsOf: RawStorage.fileURL(for: date), encoding: .utf8)) ?? ""
                let hash = Self.sourceHash(of: memos)
                let stored = (try? String(contentsOf: dailyURL, encoding: .utf8))
                    .flatMap { Self.extractSourceHash(from: $0) }
                return (memos, rawContent, hash, stored)
            }.value

        // Issue #814 cost guard: when the substantive memo content is
        // unchanged since the last compile, skip the LLM round-trip
        // entirely. Checked BEFORE the network/AI guards so an offline
        // no-op request resolves quietly instead of throwing.
        if !force,
           let storedHash,
           storedHash == sourceHash {
            appendLog(
                timestamp: iso8601Now(),
                trigger: trigger,
                durationSeconds: Date().timeIntervalSince(startTime),
                memoCount: memos.count,
                status: "skipped"
            )
            stage = .done
            compilationProgress = .done
            return .skippedUnchanged
        }

        // C4 fix: respect the master AI toggle. When the user has opted into
        // local-only mode, refuse the call rather than silently shipping memo
        // text to a third-party LLM even though a key is configured.
        guard AppSettings.aiFeaturesEnabled else {
            throw CompilationError.aiDisabled
        }
        guard NetworkMonitor.shared.isOnline else {
            throw CompilationError.offline
        }

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
        try saveResults(
            parsed,
            dateString: dateString,
            trigger: trigger,
            startTime: startTime,
            memoCount: memos.count,
            sourceHash: sourceHash
        )

        stage = .done
        compilationProgress = .done
        return .compiled
    }

    // MARK: - Source Hash (issue #814)

    /// Deterministic SHA-256 over the *substantive* memo content: id + body
    /// + attachment file names / transcripts. Deliberately EXCLUDES mood and
    /// entityMentions — `applyMemoUpdates` writes those two fields back into
    /// the raw file right after a successful compile, so hashing them would
    /// mark every freshly compiled day as stale (infinite recompile loop).
    /// Sorted by memo id so pin-reordering / file rewrites don't change it.
    nonisolated public static func sourceHash(of memos: [Memo]) -> String {
        let canonical = memos
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { memo -> String in
                let attachments = memo.attachments
                    .map { "\($0.file)|\($0.transcript ?? "")" }
                    .joined(separator: ",")
                return "\(memo.id.uuidString)\n\(memo.body)\n\(attachments)"
            }
            .joined(separator: "\n--\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads `source_hash:` out of a daily page's YAML frontmatter.
    /// Returns nil for legacy pages compiled before #814 (treated as fresh
    /// by callers so backfill never mass-recompiles history).
    nonisolated public static func extractSourceHash(from dailyContent: String) -> String? {
        let lines = dailyContent.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil } // frontmatter closed, key absent
            if trimmed.hasPrefix("source_hash:") {
                let value = trimmed.dropFirst("source_hash:".count)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Inserts `source_hash: <hash>` as the last frontmatter line of the
    /// LLM-generated daily page. If the text has no leading frontmatter
    /// block the input is returned unchanged (dedup simply stays inactive
    /// for that day rather than corrupting the document).
    nonisolated public static func injectSourceHash(_ hash: String, into dailyText: String) -> String {
        var lines = dailyText.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return dailyText }
        for index in 1 ..< lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("source_hash:") {
                lines[index] = "source_hash: \(hash)"
                return lines.joined(separator: "\n")
            }
            if trimmed == "---" {
                lines.insert("source_hash: \(hash)", at: index)
                return lines.joined(separator: "\n")
            }
        }
        return dailyText
    }

    // MARK: - Step 3: Call AI

    /// System prompt for the compilation engine. Kept on the class so it can be
    /// reused without rebuilding the string.
    private static let compilationSystemPrompt = "You are DayPage's AI compilation engine. Output only a single valid JSON object as specified in the user prompt. No extra commentary outside the JSON."

    /// Calls the LLM API via the shared ``LLMClient`` (transport + retry +
    /// Sentry span). This layer only translates ``LLMError`` into
    /// ``CompilationError`` so existing UX copy / error paths stay intact.
    private func callAI(prompt: String, onRetry: ((Int, Int) -> Void)?) async throws -> String {
        let client = LLMClient(
            config: .deepSeek(maxTokens: 4096, temperature: 0.7, timeout: 120),
            spanName: "compile.daily"
        )
        do {
            return try await client.complete(
                messages: [
                    .system(Self.compilationSystemPrompt),
                    .user(prompt)
                ],
                onRetry: onRetry
            )
        } catch let llm as LLMError {
            throw Self.mapLLMError(llm)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            throw CompilationError.networkTimeout
        } catch {
            throw CompilationError.unknown(error)
        }
    }

    /// Map ``LLMError`` to ``CompilationError`` so callers of the compilation
    /// pipeline keep their existing error vocabulary and UX copy.
    private static func mapLLMError(_ error: LLMError) -> CompilationError {
        switch error {
        case .missingApiKey:
            return .missingApiKey
        case .invalidURL:
            return .invalidURL
        case .offline:
            return .offline
        case .networkTimeout:
            return .networkTimeout
        case .rateLimited:
            return .apiRateLimited
        case .apiError(let code, let body):
            return .apiError(statusCode: code, body: body)
        case .emptyResponse:
            return .parseError("Unexpected response structure")
        case .unknown(let err):
            return .unknown(err)
        }
    }

    // MARK: - Step 4: Parse Response

    /// Per-memo annotation extracted from the LLM response.
    public struct MemoUpdateInstruction {
        let memoID: UUID
        let mood: String?
        let entityMentions: [String]
        let dateReferences: [String]
    }

    /// Parsed output from the LLM response.
    public struct ParsedCompilationOutput {
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
    ///
    /// A missing `memo_updates` key is a valid response (the LLM just had
    /// nothing to backfill), but a JSON parse failure on the surrounding
    /// payload is a genuine engine-side error and used to vanish silently
    /// behind `try?`. We now do-catch around `JSONSerialization` so the
    /// failure shows up in Sentry instead of degrading the compilation to
    /// "success with zero memo updates".
    private func extractMemoUpdates(_ rawLLMResponse: String) -> [MemoUpdateInstruction] {
        guard let jsonBlock = Self.extractJSONBlockStatic(from: rawLLMResponse),
              let data = jsonBlock.data(using: .utf8) else { return [] }

        let parsed: [String: Any]?
        do {
            parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            SentryReporter.breadcrumb(
                category: "compilation",
                level: .error,
                message: "extractMemoUpdates: JSON parse failed: \(error)"
            )
            return []
        }
        guard let json = parsed,
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
        memoCount: Int,
        sourceHash: String
    ) throws {
        let dailyURL = dailyPageURL(for: dateString)
        // Issue #814: stamp the source hash into the frontmatter so the next
        // compile request can prove "nothing changed" without an LLM call.
        let dailyText = Self.injectSourceHash(sourceHash, into: parsed.dailyPageText)
        do {
            try backupIfExists(at: dailyURL, dateString: dateString)
            try writeFile(content: dailyText, to: dailyURL)
        } catch let err as CompilationError {
            throw err
        } catch {
            throw CompilationError.fileSystemError(error.localizedDescription)
        }

        try EntityPageService.shared.apply(instructions: parsed.entityInstructions, date: dateString)
        let memoUpdateResult = applyMemoUpdates(parsed.memoUpdates, dateString: dateString)
        if memoUpdateResult.failed > 0 {
            lastMemoUpdateFailures = memoUpdateResult.failed
        }
        updateHotCache(summary: parsed.hotCacheText, compiledDate: dateString)

        let elapsed = Date().timeIntervalSince(startTime)
        appendLog(
            timestamp: iso8601Now(),
            trigger: trigger,
            durationSeconds: elapsed,
            memoCount: memoCount,
            status: "success"
        )

        // Issue #814 (karpathy LLM-wiki pattern): keep vault/wiki/index.md —
        // the wiki's table of contents — in sync after every compile. Pure
        // local file scan, zero LLM cost; failures are logged, never thrown.
        WikiIndexService.shared.rebuild()
    }

    /// Back-fills mood and entityMentions into the raw memo file for each
    /// MemoUpdateInstruction.
    ///
    /// Returns `(updated, failed)`:
    /// - `updated`: number of memos whose mood/entityMentions were merged
    ///   in-memory and (on a successful write) persisted to disk.
    /// - `failed`: number of memo updates that could not be persisted,
    ///   either because the day-file failed to read or because the atomic
    ///   write threw. When > 0, a warning-level breadcrumb is recorded so
    ///   we can track partial-success rate in production rather than
    ///   reporting full success in the UI.
    private func applyMemoUpdates(
        _ updates: [MemoUpdateInstruction],
        dateString: String
    ) -> (updated: Int, failed: Int) {
        guard !updates.isEmpty else { return (0, 0) }
        guard let date = ISO8601DateFormatter.dayOnly.date(from: dateString) else {
            return (0, 0)
        }

        let rawURL = RawStorage.fileURL(for: date)
        var failedUpdates: [URL] = []

        var memos: [Memo]
        do { memos = try RawStorage.read(for: date) }
        catch {
            DayPageLogger.shared.error("applyMemoUpdates: read failed: \(error)")
            // Read failure makes every requested update fail; surface the
            // raw URL so the breadcrumb shows the affected day-file.
            failedUpdates = Array(repeating: rawURL, count: updates.count)
            SentryReporter.breadcrumb(
                category: "compilation",
                level: .warning,
                message: "applyMemoUpdates partial failure (read): count=\(failedUpdates.count) files=\(failedUpdates.map(\.lastPathComponent))"
            )
            return (0, failedUpdates.count)
        }
        guard !memos.isEmpty else { return (0, 0) }

        var changedCount = 0
        for update in updates {
            guard let idx = memos.firstIndex(where: { $0.id == update.memoID }) else { continue }
            var memo = memos[idx]
            var thisMemoChanged = false
            if let mood = update.mood, !mood.isEmpty {
                memo.mood = mood
                thisMemoChanged = true
            }
            if !update.entityMentions.isEmpty {
                let merged = Array(Set(memo.entityMentions + update.entityMentions)).sorted()
                if merged != memo.entityMentions {
                    memo.entityMentions = merged
                    thisMemoChanged = true
                }
            }
            memos[idx] = memo
            if thisMemoChanged { changedCount += 1 }
        }

        guard changedCount > 0 else { return (0, 0) }
        let newContent = memos.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
        do {
            try RawStorage.atomicWrite(string: newContent, to: rawURL)
        } catch {
            DayPageLogger.shared.error("applyMemoUpdates: failed to write raw file: \(error)")
            // The batched write covers every changed memo, so on failure
            // every "changed" memo is also failed. Record one URL per
            // failed memo so the count in the breadcrumb matches.
            failedUpdates = Array(repeating: rawURL, count: changedCount)
        }

        if !failedUpdates.isEmpty {
            SentryReporter.breadcrumb(
                category: "compilation",
                level: .warning,
                message: "applyMemoUpdates partial failure (write): count=\(failedUpdates.count) files=\(failedUpdates.map(\.lastPathComponent))"
            )
            return (updated: 0, failed: failedUpdates.count)
        }

        return (updated: changedCount, failed: 0)
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

        // Issue #13 (2026-07-03): 今日焦点. The user may have tagged the day
        // via TodayView's chip row; those tags become an explicit steering
        // clause so the LLM leans toward that lens without discarding
        // off-lens material. Empty tag list == baseline behavior.
        let focusClause = buildFocusClause(dateString: dateString)

        return """
        You are DayPage's AI compilation engine. Compile today's raw memos into a structured Daily Page and identify entities (places, people, themes) for the wiki.

        ## Date
        \(dateString)
        \(dateContextNote(for: dateString))
        \(focusClause)

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
        <narrative paragraph synthesizing morning memos>[^m:<memo-uuid>][^m:<memo-uuid>]

        ## AFTERNOON
        <narrative paragraph synthesizing afternoon memos>[^m:<memo-uuid>]

        ## EVENING
        <narrative paragraph synthesizing evening memos>[^m:<memo-uuid>]

        ## LOCATIONS TODAY
        - [[location-slug]]: Brief note

        ## AI FOLLOW-UP
        > Question 1: <thoughtful follow-up question>
        > Question 2: <second follow-up question>
        > Question 3: <third follow-up question>

        ---
        *Compiled from \(memoCount) raw entries*

        ### Evidence footnote rules (Issue #4 · 证据链):
        - Every narrative paragraph (MORNING/AFTERNOON/EVENING) MUST end with one
          or more `[^m:<memo-uuid>]` footnote markers, one per memo_id whose
          content contributed to that paragraph.
        - `<memo-uuid>` is the exact UUID from the memo's `id:` YAML field.
        - Do NOT emit human-readable footnote body definitions at the end of the
          document — the DayPage viewer resolves `[^m:<uuid>]` to a chip inline
          that jumps to the original memo. Keep the marker cluster tight (no
          spaces between markers).
        - If a paragraph legitimately synthesizes from zero memos (rare),
          omit the marker rather than inventing a UUID.

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

        ### Chinese-quote rules (Issue #19 · 中文语境, 2026-07-03):
        - 引用用户原话时**逐字**保留，包括标点与断句，不要改写为更通顺的说法。
        - 中英混合的原文引用保留原语言，不要机翻。
        - 引用格式使用 `>` 引用块，一段一行，行末标注时间：
            > <原句> — <时段（如"上午 09:00"）>
        - 转述/概括必须放在引用块之外，让读者一眼分得清"这是我说过的原话"
          还是"这是 AI 的归纳"。
        """
    }

    // MARK: - Date Context

    /// Returns a short natural-language note about the day type so the LLM can
    /// tone the narrative appropriately (weekend vs. weekday vs. public holiday).
    /// Issue #13 (2026-07-03): assemble the "user-declared focus" prompt
    /// section from `TodayFocusStore`. Runs on the main actor because
    /// TodayFocusStore is `@MainActor`; `buildPrompt` is already invoked
    /// from a main-actor context (BackgroundCompilationService), so the
    /// hop is a no-op in the common path.
    private func buildFocusClause(dateString: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        guard let date = df.date(from: dateString) else { return "" }

        let focuses = MainActor.assumeIsolated {
            TodayFocusStore.shared.focuses(on: date)
        }
        guard !focuses.isEmpty else { return "" }
        let names = focuses.map { $0.displayName }.joined(separator: "、")
        let hints = focuses.map { "  · \($0.displayName)：\($0.promptHint)" }.joined(separator: "\n")
        return """

        ## User-declared focus for today (Issue #13)
        用户今天选择了以下焦点：\(names)
        请让 daily_page 的叙事在保留全部素材的前提下偏向这些角度：
        \(hints)
        """
    }

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

public enum CompilationError: LocalizedError {
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
    // C4 fix: user has disabled AI features in Settings — local-only mode.
    case aiDisabled

    public var errorDescription: String? {
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
        case .aiDisabled:
            return NSLocalizedString("compile.error.ai_disabled",
                                     comment: "Error shown when the master AI toggle is off")
        }
    }
}
