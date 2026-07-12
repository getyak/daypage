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

    // MARK: AgentPhase

    /// Agent 检索循环的可视阶段（issue #837）。UI 把每个阶段渲染成一行
    /// 状态文案，让「翻找 → 思考 → 逐字作答」的过程被用户感知——
    /// 这是把图谱检索的价值显性化的延伸（研究文档 §5 风险 4）。
    public enum AgentPhase: Equatable {
        case idle
        /// 正在重读附着的那条记录（memo 锚定对话首拍）。
        case reading
        /// 沿这些线索（实体显示名）翻找相关记录。
        case retrieving([String])
        /// 检索完成，找到 N 条相关记录，正在组织回答。
        case thinking(found: Int)
        /// LLM token 流式输出中（增量文本见 `streamingText`）。
        case streaming
    }

    // MARK: Published state

    @Published public var turns: [ChatTurn] = []
    @Published public var isResponding = false
    @Published public var errorMessage: String?
    /// Agent 循环当前阶段；仅在 `isResponding` 期间离开 `.idle`。
    @Published public private(set) var phase: AgentPhase = .idle
    /// 流式回答的增量缓冲；回答完成后清空并整体落入 assistant turn。
    @Published public private(set) var streamingText: String = ""
    /// memo 锚定对话（issue #837）：附着的那条记录会作为一等上下文
    /// 注入每一轮 prompt，其 entityMentions 作为图谱检索种子。
    @Published public private(set) var attachedMemo: Memo?
    /// 附着 memo 的实体显示名（由调用方解析 wiki `name:` 后传入），
    /// 用于 `.retrieving` 阶段的文案——slug 直出对 CJK 用户不可读。
    public private(set) var attachedClues: [String] = []

    // MARK: Dependencies

    /// 注入式 LLM 调用闭包，便于测试替身。默认走云端 DeepSeek。
    private let send: ([LLMMessage]) async throws -> String
    /// 注入式流式 LLM 闭包（messages, onDelta）→ 完整回答。为 nil 时
    /// `ask` 走非流式 `send`（测试注入 `send:` 即保持旧行为与节奏）。
    private let streamSend: (([LLMMessage], @escaping @MainActor @Sendable (String) -> Void) async throws -> String)?
    /// 注入式检索闭包 `(query, seedEntitySlugs)`，默认走图谱增强检索。
    /// `@Sendable` 标注让它可以安全地跨 actor 边界传给 detached task —— 真实
    /// 默认值 `GraphRetriever.retrieve` 是 `nonisolated static`，本身无主线程
    /// 依赖；测试桩通常是值语义闭包，也可跨线程调度。
    private let retrieve: @Sendable (String, [String]) -> RetrievedContext

    public init(
        send: (([LLMMessage]) async throws -> String)? = nil,
        streamSend: (([LLMMessage], @escaping @MainActor @Sendable (String) -> Void) async throws -> String)? = nil,
        retrieve: @escaping @Sendable (String, [String]) -> RetrievedContext = { GraphRetriever.retrieve(query: $0, seedEntitySlugs: $1) }
    ) {
        self.retrieve = retrieve
        if let send {
            self.send = send
            self.streamSend = streamSend
        } else {
            self.send = { messages in
                let client = LLMClient(
                    config: .deepSeek(maxTokens: 1500, temperature: 0.5),
                    spanName: "chat.memory"
                )
                return try await client.complete(messages: messages)
            }
            // 生产默认：优先流式。spanName 与非流式分桶，便于用量对比。
            self.streamSend = streamSend ?? { messages, onDelta in
                let client = LLMClient(
                    config: .deepSeek(maxTokens: 1500, temperature: 0.5),
                    spanName: "askpast.stream"
                )
                return try await client.stream(messages: messages, onDelta: onDelta)
            }
        }
    }

    // MARK: - Attached memo (issue #837)

    /// 把一条 memo 附着为对话锚点。`clues` 是其实体的显示名（UI 已解析），
    /// 缺省时回退为去连字符的 slug。
    public func attach(memo: Memo, clues: [String] = []) {
        attachedMemo = memo
        if clues.isEmpty {
            attachedClues = memo.entityMentions.map {
                $0.replacingOccurrences(of: "-", with: " ")
            }
        } else {
            attachedClues = clues
        }
    }

    /// 摘除锚点——对话退化为通用「问过去」。已生成的回合保留。
    public func detachMemo() {
        attachedMemo = nil
        attachedClues = []
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
    ///
    /// Agent loop（issue #837）：每一步驱动 `phase`，让 UI 把「重读 → 翻找 →
    /// 思考 → 逐字作答」的过程可视化。节奏拍（短 sleep）只在流式路径生效——
    /// 注入 `send:` 的测试路径保持原有零延迟行为。
    public func ask(_ rawQuestion: String) async {
        await run(rawQuestion, appendUserTurn: true)
    }

    /// 重试最近一条 user 提问——不重复追加 user 气泡（流式失败后的
    /// 「重试」按钮语义：同一个问题，再答一次）。
    public func retryLast() async {
        guard let lastUser = turns.last(where: { $0.role == .user }) else { return }
        await run(lastUser.text, appendUserTurn: false)
    }

    private func run(_ rawQuestion: String, appendUserTurn: Bool) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        errorMessage = nil
        if appendUserTurn {
            let userTurn = ChatTurn(role: .user, text: question)
            turns.append(userTurn)
            Self.appendTurn(userTurn)
        }
        isResponding = true
        defer {
            isResponding = false
            phase = .idle
            streamingText = ""
        }

        let paced = streamSend != nil

        // Phase 0: 重读锚定记录（仅 memo 锚定对话；本地即时，仅是节奏拍）。
        if attachedMemo != nil {
            phase = .reading
            if paced { try? await Task.sleep(nanoseconds: 400_000_000) }
        }

        // Phase 1 / Step 1: 图谱增强检索——磁盘 I/O 走 detached task 避免阻塞
        // 主线程。GraphRetriever.retrieve 是 nonisolated 静态函数，捕获不可变
        // 副本进入后台，再回到主 actor 装配 messages。
        phase = .retrieving(attachedClues)
        let retrieveClosure = self.retrieve
        let seedSlugs = attachedMemo?.entityMentions ?? []
        let context = await Task.detached(priority: .userInitiated) { @Sendable in
            retrieveClosure(question, seedSlugs)
        }.value

        // Allow caller (e.g. sheet dismissal) to cancel mid-flight.
        if Task.isCancelled { return }

        // Phase 2: 「找到 N 条」短拍——检索通常快到不可见，这一拍把
        // 结果数量讲给用户听，然后才进入等待 LLM 的阶段。
        phase = .thinking(found: context.memoHits.count)
        if paced { try? await Task.sleep(nanoseconds: 450_000_000) }

        // Step 2: 组装 messages（system + 锚定 memo + 检索上下文 + 历史 + 问题）。
        let messages = buildMessages(question: question, context: context)

        // Step 3: 调 LLM——优先流式（token 逐段落入 streamingText），
        // 无流式闭包时回退一次性 complete。
        do {
            let answer: String
            if let streamSend {
                phase = .streaming
                streamingText = ""
                answer = try await streamSend(messages) { [weak self] chunk in
                    self?.streamingText += chunk
                }
            } else {
                answer = try await send(messages)
            }
            if Task.isCancelled { return }
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

    /// memo 锚定对话的追加 system 规则（issue #837）。
    public static let anchoredMemoRule = """
    补充情境：用户此刻正打开自己过去的一条具体记录，并针对它追问。
    - 优先围绕这条记录回答；它的全文在「用户正在追问的这条记录」块中。
    - 当检索上下文里出现其他日期的相关记录时，指出它们与这条记录之间的
      联系或变化（想法的延续、反转、重现），并带上日期。
    - 不要复述这条记录本身——用户正看着它；直接给出观察与回答。
    """

    /// 构造发给 LLM 的 messages。
    /// 历史只带最近若干轮，避免上下文无限膨胀（token 成本控制，研究文档 §5）。
    public func buildMessages(question: String, context: RetrievedContext, historyLimit: Int = 4) -> [LLMMessage] {
        var messages: [LLMMessage] = [.system(Self.systemPrompt)]
        if attachedMemo != nil {
            messages.append(.system(Self.anchoredMemoRule))
        }

        // 最近 historyLimit 轮历史（不含当前这条尚未入队的 user 问题）。
        let priorTurns = turns.dropLast().suffix(historyLimit)
        for turn in priorTurns {
            switch turn.role {
            case .user: messages.append(.user(turn.text))
            case .assistant: messages.append(.assistant(turn.text))
            }
        }

        // 当前问题 + 锚定记录 + 检索上下文一起作为 user 消息，让模型看到依据。
        var blocks: [String] = []
        if let memo = attachedMemo {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd HH:mm"
            let moodPart = memo.mood.map { "（情绪：\($0)）" } ?? ""
            blocks.append("""
            ## 用户正在追问的这条记录（\(f.string(from: memo.created))\(moodPart)）
            \(memo.body)
            """)
        }
        blocks.append("""
        ## 检索到的上下文
        \(context.toPromptContext())
        """)
        blocks.append("""
        ## 我的问题
        \(question)
        """)
        messages.append(.user(blocks.joined(separator: "\n\n")))
        return messages
    }
}
