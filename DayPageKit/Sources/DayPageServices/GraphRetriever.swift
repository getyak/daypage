import Foundation
import DayPageModels
import DayPageStorage

// MARK: - RetrievedContext

/// `GraphRetriever` 的产物：为一次查询组装的、带来源标注的检索上下文。
///
/// 这是 D2「图谱增强检索」的输出契约——既能直接喂给 LLM（`MemoryChatService`），
/// 也能在 UI 上把"引用了哪些 memo / 实体页"显式呈现给用户。
public struct RetrievedContext: Equatable {

    /// 命中的原始 memo 片段。
    public struct MemoHit: Equatable {
        public let dateString: String       // "yyyy-MM-dd"
        public let snippet: String          // 修剪后的正文片段
        public let mood: String?
        public let entityMentions: [String] // 该 memo 引用的实体 slug

        public init(dateString: String, snippet: String, mood: String?, entityMentions: [String]) {
            self.dateString = dateString
            self.snippet = snippet
            self.mood = mood
            self.entityMentions = entityMentions
        }
    }

    /// 沿 entityMentions 扩展出的一跳邻居实体页摘要。
    public struct EntityHit: Equatable {
        public let slug: String
        public let displayName: String
        public let type: String             // "places" | "people" | "themes"
        public let occurrenceCount: Int
        public let summary: String          // 实体页正文摘要（截断）

        public init(slug: String, displayName: String, type: String, occurrenceCount: Int, summary: String) {
            self.slug = slug
            self.displayName = displayName
            self.type = type
            self.occurrenceCount = occurrenceCount
            self.summary = summary
        }
    }

    public let query: String
    public let memoHits: [MemoHit]
    public let entityHits: [EntityHit]

    public var isEmpty: Bool { memoHits.isEmpty && entityHits.isEmpty }

    /// 把检索上下文渲染为给 LLM 的 prompt 片段（带来源标注，便于模型引用）。
    public func toPromptContext() -> String {
        var blocks: [String] = []

        if !memoHits.isEmpty {
            let memoLines = memoHits.map { hit -> String in
                let moodPart = hit.mood.map { "（情绪：\($0)）" } ?? ""
                return "- [\(hit.dateString)]\(moodPart) \(hit.snippet)"
            }
            blocks.append("## 相关原始记录\n" + memoLines.joined(separator: "\n"))
        }

        if !entityHits.isEmpty {
            let entityLines = entityHits.map { hit -> String in
                "### \(hit.displayName)（\(entityTypeLabel(hit.type)) · 出现 \(hit.occurrenceCount) 次）\n\(hit.summary)"
            }
            blocks.append("## 相关实体（来自知识网络）\n" + entityLines.joined(separator: "\n\n"))
        }

        return blocks.isEmpty ? "(未检索到相关内容)" : blocks.joined(separator: "\n\n")
    }

    private func entityTypeLabel(_ type: String) -> String {
        switch type {
        case "places": return "地点"
        case "people": return "人物"
        case "themes": return "主题"
        default: return type
        }
    }
}

// MARK: - GraphRetriever

/// 图谱增强检索引擎（D2，研究文档 §3 D2）。
///
/// 核心思路（OmniQuery「先连后查」arXiv 2409.08250）：朴素关键词检索只能
/// 捞出孤立的 memo 片段；本检索器在命中 memo 之后，**沿 `entityMentions` 扩展
/// 一跳邻居实体页**，把"原始记录 + 知识网络上下文"一起返回。这比把每条 memo
/// 当孤立文本检索，对"我对 X 的看法怎么变的""去年这个时候我在哪"这类需要
/// 跨记忆推断的查询效果显著更好。
///
/// 数据来源（均为现成基质，无需新基础设施）：
///   - 种子命中：`SearchService.search`（关键词 + 可选过滤）
///   - 邻居扩展：`vault/wiki/{places,people,themes}/{slug}.md` 实体页
///
/// 纯本地、零 token 成本、零网络——这是 D1 对话 Agent 的检索层。
public enum GraphRetriever {

    // MARK: - Public API

    /// 为 `query` 组装图谱增强检索上下文。
    /// - Parameters:
    ///   - query: 用户的自然语言查询或关键词。
    ///   - maxMemoHits: 保留的种子 memo 命中上限（按日期降序，最新优先）。
    ///   - maxEntityHits: 扩展的邻居实体上限（按出现次数降序，最相关优先）。
    public nonisolated static func retrieve(
        query rawQuery: String,
        maxMemoHits: Int = 8,
        maxEntityHits: Int = 6
    ) -> RetrievedContext {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return RetrievedContext(query: query, memoHits: [], entityHits: [])
        }

        // Step 1: 种子命中——复用现有关键词检索。
        let searchResults = SearchService.search(keyword: query)

        // Step 2: 把命中结果重新读成带 entityMentions 的 MemoHit。
        // SearchResult 只给了 snippet + dateString，要拿 entityMentions
        // 必须回读 raw 文件并匹配。按日期去重后回读。
        let hitDates = orderedUniqueDates(from: searchResults)
        var memoHits: [RetrievedContext.MemoHit] = []
        var entitySlugs = Set<String>()
        let folded = foldedForSearch(query)

        for dateString in hitDates {
            guard memoHits.count < maxMemoHits else { break }
            guard let date = DateFormatters.isoDate.date(from: dateString) else { continue }
            let memos: [Memo]
            do {
                memos = try RawStorage.read(for: date)
            } catch {
                // I/O 失败不应让整次检索黑屏。逐天降级为空集，但记录到 logger，
                // 让 Sentry 看得到磁盘/权限/iCloud 冲突这类信号，不再 silent fail.
                DayPageLogger.log(
                    level: "WARN",
                    message: "[GraphRetriever] read \(dateString) failed: \(error.localizedDescription)"
                )
                continue
            }
            for memo in memos where memoMatches(memo, foldedQuery: folded) {
                guard memoHits.count < maxMemoHits else { break }
                memoHits.append(RetrievedContext.MemoHit(
                    dateString: dateString,
                    snippet: snippet(from: memo),
                    mood: memo.mood,
                    entityMentions: memo.entityMentions
                ))
                entitySlugs.formUnion(memo.entityMentions)
            }
        }

        // Step 3: 图谱扩展——沿 entityMentions 读邻居实体页。
        // 同时把 query 本身当作可能的实体 slug 直接命中（用户可能在问某地/某人）。
        entitySlugs.formUnion(slugCandidates(from: query))
        let entityHits = expandEntities(slugs: entitySlugs, limit: maxEntityHits)

        return RetrievedContext(query: query, memoHits: memoHits, entityHits: entityHits)
    }

    // MARK: - Step 2 helpers

    /// 从搜索结果中提取去重后的日期，保持原有降序（最新优先）。
    private static func orderedUniqueDates(from results: [SearchResult]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for r in results where !seen.contains(r.dateString) {
            seen.insert(r.dateString)
            ordered.append(r.dateString)
        }
        return ordered
    }

    private static func memoMatches(_ memo: Memo, foldedQuery: String) -> Bool {
        if foldedForSearch(memo.body).contains(foldedQuery) { return true }
        if let name = memo.location?.name, foldedForSearch(name).contains(foldedQuery) { return true }
        for att in memo.attachments {
            if let t = att.transcript, foldedForSearch(t).contains(foldedQuery) { return true }
        }
        return false
    }

    private static func snippet(from memo: Memo) -> String {
        let source = memo.body.isEmpty
            ? (memo.location?.name ?? "")
            : memo.body
        let oneLine = source.replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(160))
    }

    // MARK: - Step 3: Entity expansion

    /// 把候选 slug 集合扩展为实体页摘要，按 occurrence_count 降序取前 N。
    ///
    /// 双阶段命中：先 O(1) 走精确 slug；命中不到时再用 ``EntityPageService.isFuzzyMatch``
    /// 扫描同 type 目录。这与 `EntityPageService.resolveSlug` 的写路径策略
    /// 对称，避免 "coffee" 在写时被 canonicalize 成 "coffee-shop"、读时却查不到。
    private static func expandEntities(slugs: Set<String>, limit: Int) -> [RetrievedContext.EntityHit] {
        guard !slugs.isEmpty else { return [] }
        let types = ["places", "people", "themes"]
        var hits: [RetrievedContext.EntityHit] = []
        var resolvedFiles = Set<URL>()  // 防止同一实体被多 slug 候选重复入选

        for slug in slugs {
            var matched = false
            for type in types {
                let url = entityURL(type: type, slug: slug)
                let content: String
                do {
                    content = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    // ENOENT (slug 不在该目录) 是绝大多数情形，刻意静默。其它
                    // 错误（权限、IO）记一条 WARN 便于诊断，但不中断扩展循环。
                    if (error as NSError).code != NSFileReadNoSuchFileError {
                        DayPageLogger.log(
                            level: "WARN",
                            message: "[GraphRetriever] read entity \(type)/\(slug) failed: \(error.localizedDescription)"
                        )
                    }
                    continue
                }
                if resolvedFiles.insert(url).inserted,
                   let hit = parseEntityPage(content, slug: slug, type: type) {
                    hits.append(hit)
                    matched = true
                }
                break // 一个 slug 只会在一种类型目录里
            }
            if !matched {
                // 精确路径没命中——回退到 fuzzy 扫描，复用写侧的同一规则。
                fuzzyResolve(slug: slug, in: types, into: &hits, resolvedFiles: &resolvedFiles)
            }
        }

        return hits
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
            .prefix(limit)
            .map { $0 }
    }

    /// 解析实体页：从 frontmatter 取 name / occurrence_count，从正文取摘要。
    /// frontmatter 字段提取走共用的 `FrontmatterParser.extractFieldInBlock`，
    /// 保证与未来新增的实体字段（如 occurrence_count_zh）解析一致。
    public static func parseEntityPage(_ content: String, slug: String, type: String) -> RetrievedContext.EntityHit? {
        let displayName = FrontmatterParser.extractFieldInBlock("name", from: content) ?? slug
        let occurrence = Int(FrontmatterParser.extractFieldInBlock("occurrence_count", from: content) ?? "") ?? 1
        let summary = bodySummary(from: content)
        return RetrievedContext.EntityHit(
            slug: slug,
            displayName: displayName,
            type: type,
            occurrenceCount: occurrence,
            summary: summary
        )
    }

    /// 取实体页正文（frontmatter 之后）的前若干行非空内容作为摘要。
    public static func bodySummary(from content: String, maxChars: Int = 280) -> String {
        let lines = content.components(separatedBy: "\n")
        var bodyLines: [String] = []
        var dashCount = 0
        var started = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                dashCount += 1
                if dashCount >= 2 { started = true }
                continue
            }
            guard started else { continue }
            // 跳过一级标题与纯元数据行，保留有信息的内容。
            if trimmed.hasPrefix("# ") { continue }
            if trimmed.hasPrefix("**Type**") || trimmed.hasPrefix("**First seen**") { continue }
            if trimmed.isEmpty { continue }
            bodyLines.append(trimmed)
        }
        let joined = bodyLines.joined(separator: " ")
        return String(joined.prefix(maxChars))
    }

    // MARK: - Slug candidates

    /// 把查询切成可能的 slug 候选（用于直接命中实体页，如用户问 "清迈"）。
    /// 简单策略：整体 slug 化 + 按空格分词后各自 slug 化。
    private static func slugCandidates(from query: String) -> Set<String> {
        var out = Set<String>()
        let whole = EntityPageService.sanitizeSlug(query)
        if !whole.isEmpty { out.insert(whole) }
        for token in query.split(whereSeparator: { $0 == " " || $0 == "，" || $0 == "," }) {
            let s = EntityPageService.sanitizeSlug(String(token))
            if s.count >= 2 { out.insert(s) }
        }
        return out
    }

    // MARK: - URL / formatting helpers

    private static func entityURL(type: String, slug: String) -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent(type)
            .appendingPathComponent("\(slug).md")
    }

    private static func foldedForSearch(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Fallback when a candidate slug had no exact entity file: scan each type
    /// directory and pick the first existing slug that passes the same fuzzy
    /// rule the write path uses. Cheap because there are at most a few hundred
    /// entity files in a real vault, and we early-exit on first match per type.
    private static func fuzzyResolve(
        slug: String,
        in types: [String],
        into hits: inout [RetrievedContext.EntityHit],
        resolvedFiles: inout Set<URL>
    ) {
        let fm = FileManager.default
        for type in types {
            let dir = VaultInitializer.vaultURL
                .appendingPathComponent("wiki")
                .appendingPathComponent(type)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for url in entries where url.pathExtension == "md" {
                let candidate = url.deletingPathExtension().lastPathComponent
                guard EntityPageService.isFuzzyMatch(slug, candidate) else { continue }
                guard resolvedFiles.insert(url).inserted else { continue }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let hit = parseEntityPage(content, slug: candidate, type: type) {
                    hits.append(hit)
                }
                return // one fuzzy hit per candidate is enough
            }
        }
    }
}
