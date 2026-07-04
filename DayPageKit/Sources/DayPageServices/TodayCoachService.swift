import Foundation
import DayPageStorage
import DayPageModels

// MARK: - CoachTurn

/// 一轮 Coach 对话消息。与 `ChatTurn`（MemoryChatService）刻意分开——
/// 两者的语义完全不同：
/// - `ChatTurn` 是 RAG 问答，assistant 回复挂 `RetrievedContext`；
/// - `CoachTurn` 是引导式对话，assistant 回复挂 `memoDraft`（一段可直接存入
///   今日日记的候选文本）。
///
/// UI 层不需要跨这两种类型渲染同一列表，所以类型分家比塞进一个联合更清晰。
public struct CoachTurn: Identifiable, Equatable {
    public enum Role: String, Equatable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    public let createdAt: Date
    /// 仅 assistant：一句可选的「候选 memo 草稿」。UI 层把它渲染成
    /// 「存入今日日记」按钮上方的引用块，让用户明白：这段对话可以变成
    /// 一条 raw memo。
    public var memoDraft: String?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        memoDraft: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.memoDraft = memoDraft
    }
}

// MARK: - TodayCoachContext

/// Coach system prompt 需要的当天上下文快照。刻意保持纯值类型——service 里
/// 不直接摸 `TimelineIndex.shared`，而是让调用方（TodayCoachView）在打开
/// sheet 时抓一次快照传进来。这样：
/// 1. 单元测试可以直接构造上下文；
/// 2. 一次 Coach 会话里的 prompt 稳定，不会因为期间又写了一条 memo 就漂移。
public struct TodayCoachContext: Equatable {
    public let localDate: String        // yyyy-MM-dd（用户所在时区）
    public let timeOfDay: String        // "morning" / "afternoon" / "evening" / "late_night"
    /// 今日已写 memo 的 body 摘要——每条最多截 80 字，最多 5 条。
    /// 用途：让 Coach 反问时能引用「你上午写到 XX」，避免空谈。
    public let todayMemoSnippets: [String]
    /// 今日 memo 里出现的 hashtag/主题（如 `#工作`、`#睡眠`）。
    public let todayTags: [String]

    public init(
        localDate: String,
        timeOfDay: String,
        todayMemoSnippets: [String] = [],
        todayTags: [String] = []
    ) {
        self.localDate = localDate
        self.timeOfDay = timeOfDay
        self.todayMemoSnippets = todayMemoSnippets
        self.todayTags = todayTags
    }

    /// 从 `TimelineIndex` + `RawStorage` 抓当天上下文。**仅主线程调用**——
    /// 内部读磁盘做 YAML 解析，但每天至多一次，Coach sheet 打开时命中一次
    /// 即可缓存到会话结束。
    @MainActor
    public static func snapshotForToday(now: Date = Date()) -> TodayCoachContext {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let band: String
        switch hour {
        case 5..<12: band = "morning"
        case 12..<18: band = "afternoon"
        case 18..<23: band = "evening"
        default: band = "late_night"
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let dateStr = f.string(from: now)

        // 从 TimelineIndex 找到今天的 entry；命中就用 TimelineService.memos
        // 读出原文，否则返回空（今天还没写过）。
        var snippets: [String] = []
        var tags: [String] = []
        if let todayEntry = TimelineIndex.shared.entries().first(where: { $0.dateString == dateStr }) {
            let memos = TimelineService.memos(for: todayEntry)
            for memo in memos.prefix(5) {
                let body = memo.body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if body.isEmpty { continue }
                let capped = body.count > 80 ? String(body.prefix(80)) + "…" : body
                snippets.append(capped)
                tags.append(contentsOf: Self.extractHashtags(body))
            }
        }
        var seen = Set<String>()
        let uniqTags = tags.filter { seen.insert($0).inserted }
        return TodayCoachContext(
            localDate: dateStr,
            timeOfDay: band,
            todayMemoSnippets: snippets,
            todayTags: Array(uniqTags.prefix(6))
        )
    }

    /// 从一段文本里抽 `#xxx` 风格 tag。中英混杂——支持字母/数字/中日韩字符。
    static func extractHashtags(_ text: String) -> [String] {
        var out: [String] = []
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "#" {
                var j = i + 1
                while j < scalars.count, isTagChar(scalars[j]) { j += 1 }
                if j > i + 1 {
                    out.append(String(scalars[i..<j]))
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    private static func isTagChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        return c == "_" || c == "-"
    }
}

// MARK: - CoachResponse

/// LLM 返回的 JSON 结构。Coach prompt 要求模型必须回 JSON——纯自由文本
/// 无法可靠拿到「一句反问 + 一段可存入的 memo 草稿」两件事。
public struct CoachResponse: Equatable {
    public let reply: String
    public let memoDraft: String?

    public init(reply: String, memoDraft: String? = nil) {
        self.reply = reply
        self.memoDraft = memoDraft
    }
}

// MARK: - TodayCoachService

/// 「今日引导」AI —— 与 MemoryChatService 完全独立的服务，负责让「不知道
/// 写什么」的用户多写一条 memo（issue #804）。
///
/// 核心差异：
/// - **不做 RAG**：不检索历史，避免「没找到过去相关记录」的失败态；
/// - **必产 memoDraft**：assistant 每条回复都尝试给一段可存入的 memo 草稿，
///   哪怕只是把用户原话稍作整理；
/// - **一次一问**：system prompt 明令「只问一个问题」，避免连环 quiz；
/// - **上下文注入**：拿今日已有 memo + 时间段作为语料，避免空反问。
///
/// 与 `MemoryChatService` 共享 `LLMClient` 这一层传输，用不同 spanName
/// 让 Sentry usage 能分桶。
@MainActor
public final class TodayCoachService: ObservableObject {

    // MARK: Published state

    @Published public var turns: [CoachTurn] = []
    @Published public var isResponding = false
    @Published public var errorMessage: String?

    // MARK: Dependencies

    /// 注入式 LLM 调用（便于测试替身）。默认走云端 DeepSeek。
    private let send: ([LLMMessage]) async throws -> String
    /// 会话打开时抓的一次上下文。UI 用同一个 service 实例的话，重置
    /// 会话（`reset()`）会顺便清空上下文，需要下一次 `configure` 注入。
    private var context: TodayCoachContext

    public init(
        context: TodayCoachContext,
        send: (([LLMMessage]) async throws -> String)? = nil
    ) {
        self.context = context
        if let send {
            self.send = send
        } else {
            self.send = { messages in
                let client = LLMClient(
                    config: .deepSeek(maxTokens: 800, temperature: 0.7),
                    spanName: "chat.today_coach"
                )
                return try await client.complete(messages: messages)
            }
        }
    }

    /// 会话中途更新上下文（例如用户先存了一条草稿再继续聊）。
    public func updateContext(_ newContext: TodayCoachContext) {
        context = newContext
    }

    // MARK: - System prompt

    /// 系统提示——与 MemoryChatService 的 systemPrompt 语气完全不同：
    /// 前者是「记忆助手」（RAG），这里是「陪写助手」（Coaching）。
    public static let systemPrompt = """
    你是 DayPage 用户的「今日陪写助手」——不是搜索引擎，不是心理医生。你的
    唯一目标：帮用户此刻多写下一条日记片段。

    规则（不可违反）：
    1. **只问一个问题**。不要连问三件事；不要给建议清单；不要说教。
    2. **短**——回复不超过两行文字，任何情况下都不用列表和标题。
    3. **不检索历史**。你没有过去记录的访问权限。绝不要说「让我查一下」
       「你之前提到过」这类话——那是另一个助手的职责。
    4. **不要空反问**。如果用户提到了具体的人/事/情绪，反问就围绕它；用户
       只写了一句「不知道」，就把追问缩到最小切入口（比如：「更像是身体累、
       脑子乱，还是事情太多？」）。
    5. **必须给 memoDraft**——把用户原文整理成一段可直接存入日记的短句，
       第一人称，保留原意，不加装饰，20-60 字为宜。用户话已经很完整时，
       memoDraft 可以只是轻微 trim；用户说得很短时，你可以补一句「此刻
       XXX」的钩子。绝不替用户"美化"或杜撰事实。
    6. **返回严格 JSON**：`{"reply": "…", "memoDraft": "…"}`。没有其他文字，
       没有 markdown 代码块。若真的想不出 memoDraft，用空字符串。
    """

    // MARK: - Ask

    /// 处理一条用户消息：拼 prompt → LLM → 解析 JSON → append。
    public func ask(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }

        errorMessage = nil
        let userTurn = CoachTurn(role: .user, text: text)
        turns.append(userTurn)
        isResponding = true
        defer { isResponding = false }

        let messages = buildMessages(userText: text)
        do {
            let raw = try await send(messages)
            let parsed = Self.parseResponse(raw, userFallback: text)
            let assistantTurn = CoachTurn(
                role: .assistant,
                text: parsed.reply,
                memoDraft: parsed.memoDraft
            )
            turns.append(assistantTurn)
        } catch {
            let msg = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            errorMessage = msg
        }
    }

    public func reset() {
        turns.removeAll()
        errorMessage = nil
    }

    // MARK: - Pin to diary

    /// 把一条 assistant 回复的 memoDraft 存进今日 raw memo。
    /// 前缀 `📝 陪写 ·` 让 raw 浏览时能一眼分辨来源（对齐 AskPast 的
    /// `✨ AI ·` 前缀，两个来源前缀不同便于日后统计）。
    @discardableResult
    public func pinDraftToDiary(_ turn: CoachTurn) -> Bool {
        guard turn.role == .assistant else { return false }
        guard let draft = turn.memoDraft?.trimmingCharacters(in: .whitespacesAndNewlines),
              !draft.isEmpty else { return false }
        let body = "📝 陪写 · \(draft)"
        let memo = Memo(type: .text, created: Date(), body: body)
        do {
            try RawStorage.append(memo)
            return true
        } catch {
            errorMessage = "存入日记失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Message assembly

    /// 构造发给 LLM 的 messages。
    public func buildMessages(userText: String, historyLimit: Int = 4) -> [LLMMessage] {
        var messages: [LLMMessage] = [.system(Self.systemPrompt)]
        // 上下文块——放在 system 里更稳，模型不会当成用户新指令。
        messages.append(.system(contextBlock()))

        let priorTurns = turns.dropLast().suffix(historyLimit)
        for t in priorTurns {
            switch t.role {
            case .user: messages.append(.user(t.text))
            case .assistant: messages.append(.assistant(t.text))
            }
        }
        messages.append(.user(userText))
        return messages
    }

    private func contextBlock() -> String {
        var lines: [String] = []
        lines.append("## 今日上下文")
        lines.append("- 日期：\(context.localDate)")
        lines.append("- 时段：\(context.timeOfDay)")
        if context.todayMemoSnippets.isEmpty {
            lines.append("- 今日已写：（还没有 memo）")
        } else {
            lines.append("- 今日已写（用于反问参考，不要复述给用户）：")
            for (i, snip) in context.todayMemoSnippets.enumerated() {
                lines.append("  \(i + 1). \(snip)")
            }
        }
        if !context.todayTags.isEmpty {
            lines.append("- 今日标签：\(context.todayTags.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse

    /// 解析 LLM 返回。要求严格 JSON，但真实模型偶尔会加代码围栏，容错处理。
    /// 完全解析失败时用 raw 作为 reply、userFallback 作为 memoDraft——
    /// 保证「回复动作化」这条产品承诺永远成立。
    ///
    /// `nonisolated` 声明让测试和后台 detached task 都能直接调这个纯函数——
    /// 服务本身是 `@MainActor`，但解析没有主线程依赖。
    public nonisolated static func parseResponse(_ raw: String, userFallback: String) -> CoachResponse {
        let cleaned = stripCodeFence(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reply = (obj["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let draft = (obj["memoDraft"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalReply = reply.isEmpty ? cleaned : reply
            let finalDraft = draft.isEmpty ? nil : draft
            return CoachResponse(reply: finalReply, memoDraft: finalDraft)
        }
        return CoachResponse(reply: cleaned.isEmpty ? "嗯，我在。" : cleaned, memoDraft: userFallback)
    }

    private nonisolated static func stripCodeFence(_ s: String) -> String {
        var t = s
        if t.hasPrefix("```") {
            if let firstNL = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNL)...])
            }
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t
    }
}
