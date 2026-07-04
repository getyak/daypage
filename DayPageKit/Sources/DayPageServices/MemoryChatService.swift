import Foundation
import DayPageStorage
import DayPageModels

// MARK: - ChatTurn

/// 对话中的一轮消息（用于 UI 展示与历史回放）。
public struct ChatTurn: Identifiable, Equatable, Codable {
    public enum Role: String, Equatable, Codable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    /// UTC timestamp — persisted so history reads back in chronological order.
    public let createdAt: Date
    /// 仅 assistant 轮：本次回答检索到的上下文（用于在 UI 上展示引用来源）。
    /// Not persisted — chips are recomputable and add JSON weight for no
    /// user-visible benefit after the session ends.
    public var context: RetrievedContext?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        context: RetrievedContext? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.context = context
    }

    enum CodingKeys: String, CodingKey { case id, role, text, createdAt }
}

// MARK: - MemoryChatService

/// D1「和你的过去对话」——记忆增强的日记 Agent（研究文档 §3 D1）。
///
/// 把已编译的知识网络变现为日常交互：用户问「去年这个时候我在清迈做什么」
/// 「我对 X 的看法怎么变的」，Agent 用 `GraphRetriever` 做图谱增强检索（D2），
/// 把"原始记录 + 关联实体"喂给 `LLMClient` 生成有依据的回答。
///
/// 架构合规（研究文档 §5 红线）：本服务**只在前台被用户主动调用**触发，
/// 走云端 LLM——不绑定 `BGTaskScheduler`，因此不踩 iOS 后台 GPU 限制。
/// 未来若接端侧模型，也只在此前台路径替换 `LLMClient`，后台编译不受影响。
///
/// 验证依据：emotion-aware journaling agent (arXiv 2508.20585) `3-0`、
/// OmniQuery (arXiv 2409.08250) `3-0`。
@MainActor
public final class MemoryChatService: ObservableObject {

    // MARK: Published state

    @Published public var turns: [ChatTurn] = []
    @Published public var isResponding = false
    @Published public var errorMessage: String?

    // MARK: Dependencies

    /// 注入式 LLM 调用闭包，便于测试替身。默认走云端 DeepSeek。
    private let send: ([LLMMessage]) async throws -> String
    /// 注入式检索闭包，默认走图谱增强检索。
    /// `@Sendable` 标注让它可以安全地跨 actor 边界传给 detached task —— 真实
    /// 默认值 `GraphRetriever.retrieve` 是 `nonisolated static`，本身无主线程
    /// 依赖；测试桩通常是值语义闭包，也可跨线程调度。
    private let retrieve: @Sendable (String) -> RetrievedContext

    public init(
        send: (([LLMMessage]) async throws -> String)? = nil,
        retrieve: @escaping @Sendable (String) -> RetrievedContext = { GraphRetriever.retrieve(query: $0) }
    ) {
        self.retrieve = retrieve
        if let send {
            self.send = send
        } else {
            self.send = { messages in
                let client = LLMClient(
                    config: .deepSeek(maxTokens: 1500, temperature: 0.5),
                    spanName: "chat.memory"
                )
                return try await client.complete(messages: messages)
            }
        }
    }

    // MARK: - System prompt

    /// 系统提示：约束 Agent 只基于检索到的真实记录回答，避免编造。
    ///
    /// Issue #804 调整：规则 4 不再把「无 context」都统一说成「没找到过去
    /// 记录」——那是当用户明确问历史时才对。若用户问的是当下感受、"不知道
    /// 写什么"这类 dump-意图（被误路由到这里），应引导他们回到「陪你写今天」
    /// 面板，而不是让他们困在检索失败里。
    public static let systemPrompt = """
    你是 DayPage 用户的「记忆助手」。用户会问关于他们过去记录的问题。

    规则：
    1. **只依据下面提供的「检索到的上下文」回答**，不要编造未出现在上下文里的事实。
    2. 回答用中文，简洁、像朋友一样自然，避免机械罗列。
    3. 引用具体记录时带上日期（如「你在 2026-03-14 提到…」），让用户能对照。
    4. 如果上下文里没有相关信息：
       - 若用户明确在问历史（去年/上次/多少次…），**坦诚说明没找到相关记录**，
         并建议换个问法。
       - 若用户其实是在描述当下感受、卡住、不知道写什么，**不要**说「没找到
         过去记录」——那会让人挫败。改为一句短反问 + 建议：「这更像是想
         此刻记录一下吧？先落一句，我陪你继续写。」
    5. 当能观察到时间跨度上的变化或模式（情绪、地点、主题的演变），主动指出来——这是知识网络的价值。
    """

    // MARK: - Ask

    /// 处理一条用户提问：检索 → 组装 prompt → 调 LLM → 追加 assistant 回合。
    public func ask(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        errorMessage = nil
        let userTurn = ChatTurn(role: .user, text: question)
        turns.append(userTurn)
        Self.appendTurn(userTurn)
        isResponding = true
        defer { isResponding = false }

        // Step 1: 图谱增强检索——磁盘 I/O 走 detached task 避免阻塞主线程。
        // GraphRetriever.retrieve 是 nonisolated 静态函数，捕获 question 不可
        // 变副本进入后台，再回到主 actor 装配 messages。
        let retrieveClosure = self.retrieve
        let context = await Task.detached(priority: .userInitiated) { @Sendable in
            retrieveClosure(question)
        }.value

        // Allow caller (e.g. sheet dismissal) to cancel mid-flight.
        if Task.isCancelled { return }

        // Step 2: 组装 messages（system + 检索上下文 + 近几轮历史 + 当前问题）。
        let messages = buildMessages(question: question, context: context)

        // Step 3: 调 LLM。
        do {
            let answer = try await send(messages)
            let assistantTurn = ChatTurn(role: .assistant, text: answer, context: context)
            turns.append(assistantTurn)
            Self.appendTurn(assistantTurn)
        } catch {
            let msg = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            errorMessage = msg
            // 失败时不留空 assistant 回合；错误通过 errorMessage 展示。
        }
    }

    /// 清空对话（开始新会话）。历史记录仍保留在磁盘上；`reset` 只切换
    /// UI session。若想连磁盘一起清，另用未来 API。
    public func reset() {
        turns.removeAll()
        errorMessage = nil
    }

    // MARK: - Persistence (D1 — history across launches)

    /// 从 `vault/wiki/chats/YYYY-MM-DD.jsonl` 追加式加载今天的历史。
    /// 首次进入 AskPastView 时调用；无历史时静默返回。
    public func loadTodayHistory() {
        let url = Self.chatLogURL(for: Date())
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [ChatTurn] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let bytes = Data(line.utf8)
            if let turn = try? decoder.decode(ChatTurn.self, from: bytes) {
                loaded.append(turn)
            }
        }
        // Reserve `turns` for freshly-created turns from this session by
        // appending on top of what we loaded — the ScrollViewReader in
        // AskPastView will land the user at the bottom either way.
        turns = loaded + turns
    }

    /// Append one turn's JSON to the day's log file. Best-effort; failures
    /// are non-fatal (a lost line is preferable to blocking the UI).
    fileprivate static func appendTurn(_ turn: ChatTurn) {
        let url = chatLogURL(for: turn.createdAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(turn) else { return }
        var line = data
        line.append(0x0A) // '\n'

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private static func chatLogURL(for date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let day = f.string(from: date)
        return VaultInitializer.vaultURL
            .appendingPathComponent("wiki/chats", isDirectory: true)
            .appendingPathComponent("\(day).jsonl")
    }

    // MARK: - Pin to Diary

    /// 把一条 assistant 回答封装成 memo 追加到今天的日记文件。用于
    /// AskPastView 里"存入今日日记"按钮。返回是否成功。
    @discardableResult
    public func pinTurnToDiary(_ turn: ChatTurn) -> Bool {
        guard turn.role == .assistant, !turn.text.isEmpty else { return false }
        // The AI answer becomes the body verbatim; a small prefix marker
        // makes it discoverable when browsing raw memos later.
        let body = "✨ AI · \(turn.text)"
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
    /// 历史只带最近若干轮，避免上下文无限膨胀（token 成本控制，研究文档 §5）。
    public func buildMessages(question: String, context: RetrievedContext, historyLimit: Int = 4) -> [LLMMessage] {
        var messages: [LLMMessage] = [.system(Self.systemPrompt)]

        // 最近 historyLimit 轮历史（不含当前这条尚未入队的 user 问题）。
        let priorTurns = turns.dropLast().suffix(historyLimit)
        for turn in priorTurns {
            switch turn.role {
            case .user: messages.append(.user(turn.text))
            case .assistant: messages.append(.assistant(turn.text))
            }
        }

        // 当前问题 + 检索上下文一起作为 user 消息，让模型看到依据。
        let userContent = """
        ## 检索到的上下文
        \(context.toPromptContext())

        ## 我的问题
        \(question)
        """
        messages.append(.user(userContent))
        return messages
    }
}
