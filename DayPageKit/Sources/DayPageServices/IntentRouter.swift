import Foundation

// MARK: - ChatIntent

/// 用户在 AI 入口的输入意图。用于把「记录当下」和「查历史」两条完全不同
/// 的路径分开——避免 Today 的 sparkle 承诺陪写、跳进去却进入 RAG 检索的
/// 错位（issue #804）。
///
/// 意图的选择只影响**路由**（哪个 service 处理这句话），不影响 UI 层是否
/// 显示「存入今日」等 CTA——那些 CTA 在所有 assistant 回复下都应该出现，
/// 因为无论问过去还是当下引导，最终产物都可能是一条今日 memo。
public enum ChatIntent: String, Equatable, Codable {
    /// 记录当下：dump、卡住、情绪表达、"我今天很累"。走 Today Coach。
    case recordToday = "record_today"
    /// 查历史：时间/地点/人物/模式/趋势。走 MemoryChatService（RAG）。
    case askPast = "ask_past"
    /// 整理情绪 / 澄清模糊感受。走 Today Coach（更共情的 prompt 变体）。
    case clarifyMood = "clarify_mood"
    /// 生成行动种子 / 明日一件事。走 Today Coach。
    case actionSeed = "action_seed"
    /// 显式要求编译日报 / 生成 daily page。UI 应引导用户按 compile 按钮，
    /// 而不是在聊天里编。
    case compile = "compile"
    /// 无法确定——默认按 recordToday 处理，避免把用户扔进历史检索。
    case unknown = "unknown"

    /// 意图对应的默认 service 后端。UI 层根据这个决定打开哪个 sheet /
    /// 调用哪个服务。
    public var backend: Backend {
        switch self {
        case .askPast: return .memoryChat
        case .compile: return .compiler
        case .recordToday, .clarifyMood, .actionSeed, .unknown: return .todayCoach
        }
    }

    public enum Backend: String, Equatable {
        case todayCoach
        case memoryChat
        case compiler
    }
}

// MARK: - IntentRouter

/// 把用户输入分类到 `ChatIntent`。当前实现是**纯启发式规则**——按 keyword
/// 家族匹配，避免为每次 sparkle 输入触发一次 LLM 调用（那既慢又费钱）。
///
/// 规则设计取自研究文档 §3 D1 的对话意图分析 + 真实 dogfood 语料：
/// - askPast：包含时间词（去年/上个月/上次/以前/最近）或 wh- 词（什么时候/在哪/多少次）
/// - clarifyMood：包含情绪词（累/烦/焦虑/难过/开心/迷茫）而无问号或历史指向
/// - actionSeed：包含意图动词（该做/想做/接下来/明天/下一步）
/// - compile：显式命令词（编译/生成日报/整理今天）
/// - recordToday：其余全部——把"不知道写什么""脑子乱"扔进 coach，而不是 RAG
///
/// 阈值可调；未来若需要更高准确率，可在此之上叠一层 LLM 分类作为兜底，
/// 但 90% 的日常输入靠规则已足够路由正确。
public struct IntentRouter {

    /// 主入口。传入用户原文，返回意图；空字符串 → `.unknown`。
    ///
    /// 参数：
    /// - `text`：用户输入（未 trim 也可，内部会处理）
    /// - `hasHistoryHints`：调用方可传 true 表示当前 UI 上下文（例如"过去
    ///   记录"面板）本身就在历史检索场景——这时任何非明确 record 意图都
    ///   路由到 askPast。默认 false。
    public static func classify(_ text: String, hasHistoryHints: Bool = false) -> ChatIntent {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unknown }

        let s = raw.lowercased()

        // 1. 显式命令词最优先——用户明确说"编译"就是想生成日报。
        if matchesAny(s, compileKeywords) {
            return .compile
        }

        // 2. 历史检索指向：时间锚点 + 疑问结构，或 hasHistoryHints 上下文。
        let looksHistorical = matchesAny(s, historyTimeKeywords) || matchesAny(s, historyPatternKeywords)
        let hasQuestionMark = raw.contains("?") || raw.contains("？")
        if looksHistorical && (hasQuestionMark || matchesAny(s, historyWhKeywords)) {
            return .askPast
        }
        if hasHistoryHints && !matchesAny(s, presentTenseKeywords) {
            return .askPast
        }

        // 3. 行动种子：显式的"明天/接下来/下一步"。放在 mood 之前，因为
        //    "接下来我想放松一下"应归 actionSeed 而非 clarifyMood。
        if matchesAny(s, actionSeedKeywords) {
            return .actionSeed
        }

        // 4. 情绪澄清：含情绪词，且不带疑问指向历史。
        if matchesAny(s, moodKeywords) {
            return .clarifyMood
        }

        // 5. 兜底：默认按记录当下。这一点是**核心设计**——"我不知道想做
        //    什么"、"脑子乱"、"随便写点"都会走 Today Coach，而不是被扔进
        //    RAG 说"没找到过去相关记录"。
        return .recordToday
    }

    // MARK: - Keyword families

    /// 显式编译/生成日报意图。
    private static let compileKeywords: [String] = [
        "编译", "生成日报", "整理今天", "整理一下今天", "编成日记",
        "compile", "generate diary", "make daily"
    ]

    /// 历史检索的时间锚点。命中之一 + 疑问 → askPast。
    private static let historyTimeKeywords: [String] = [
        "去年", "上个月", "上周", "上次", "以前", "之前", "前几天",
        "过去", "从前", "最近这几天", "这一年", "这几年", "多久没",
        "上一次", "那时候",
        "last year", "last month", "last week", "in the past",
        "used to", "when did i", "before"
    ]

    /// 历史模式/趋势词。
    private static let historyPatternKeywords: [String] = [
        "变化", "趋势", "模式", "规律", "多少次", "几次", "统计",
        "提到最多", "去过的地方", "最常见", "常常", "总是",
        "trend", "pattern", "how many times", "most mentioned"
    ]

    /// 疑问引导词（配合历史词判断 askPast）。
    private static let historyWhKeywords: [String] = [
        "什么时候", "在哪", "在哪里", "在何时", "跟谁", "和谁",
        "when", "where", "who", "which day"
    ]

    /// 明确指向当下的短语——即便 hasHistoryHints 为真，命中这些仍走 record。
    private static let presentTenseKeywords: [String] = [
        "现在", "此刻", "此时", "今天", "刚刚", "刚才",
        "now", "just now", "right now", "today", "just"
    ]

    /// 行动/规划意图。
    private static let actionSeedKeywords: [String] = [
        "明天", "接下来", "下一步", "下一件", "打算", "计划做",
        "该做什么", "想做点", "开始做",
        "tomorrow", "next step", "what should i do", "plan to"
    ]

    /// 情绪词汇。命中且未落入 askPast/actionSeed 时 → clarifyMood。
    private static let moodKeywords: [String] = [
        "累", "烦", "烦躁", "焦虑", "难过", "低落", "沮丧", "迷茫",
        "开心", "兴奋", "紧张", "害怕", "心累", "疲惫", "空虚", "麻木",
        "心情", "情绪", "感觉", "有点丧", "卡住",
        "tired", "anxious", "sad", "stuck", "overwhelmed", "burned out",
        "excited", "happy", "lost", "confused"
    ]

    // MARK: - Helpers

    /// 在 lowercased 输入里查任一子串（子串匹配比分词更稳，中英混杂时不
    /// 依赖分词器）。
    private static func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles {
            if haystack.contains(n) { return true }
        }
        return false
    }
}
