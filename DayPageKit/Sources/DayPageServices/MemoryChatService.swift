import Foundation

// MARK: - ChatTurn

/// 对话中的一轮消息（用于 UI 展示与历史回放）。
public struct ChatTurn: Identifiable, Equatable {
    public enum Role: Equatable { case user, assistant }
    public let id = UUID()
    public let role: Role
    public var text: String
    /// 仅 assistant 轮：本次回答检索到的上下文（用于在 UI 上展示引用来源）。
    public var context: RetrievedContext?
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
    public static let systemPrompt = """
    你是 DayPage 用户的「记忆助手」。用户会问关于他们过去记录的问题。

    规则：
    1. **只依据下面提供的「检索到的上下文」回答**，不要编造未出现在上下文里的事实。
    2. 回答用中文，简洁、像朋友一样自然，避免机械罗列。
    3. 引用具体记录时带上日期（如「你在 2026-03-14 提到…」），让用户能对照。
    4. 如果上下文里没有相关信息，**坦诚说明没有找到相关记录**，并建议用户换个问法或先去编译/记录。
    5. 当能观察到时间跨度上的变化或模式（情绪、地点、主题的演变），主动指出来——这是知识网络的价值。
    """

    // MARK: - Ask

    /// 处理一条用户提问：检索 → 组装 prompt → 调 LLM → 追加 assistant 回合。
    public func ask(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        errorMessage = nil
        turns.append(ChatTurn(role: .user, text: question))
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
            turns.append(ChatTurn(role: .assistant, text: answer, context: context))
        } catch {
            let msg = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            errorMessage = msg
            // 失败时不留空 assistant 回合；错误通过 errorMessage 展示。
        }
    }

    /// 清空对话（开始新会话）。
    public func reset() {
        turns.removeAll()
        errorMessage = nil
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
