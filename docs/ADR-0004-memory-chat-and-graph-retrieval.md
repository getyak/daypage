# ADR-0004 · 记忆对话 Agent（D1）与图谱增强检索（D2）

- **状态**：Accepted（已实现，首版落地）
- **日期**：2026-06-17
- **关联**：`docs/research-2026-06-market-and-product-directions.md` §3 D1/D2、§5 红线；ADR-0002（MCP，未来检索后端）
- **影响范围**：`DayPage/Services/LLMClient.swift`、`GraphRetriever.swift`、`MemoryChatService.swift`、`DayPage/Features/Ask/AskPastView.swift`、`DayPage/Intents/AskTodayIntent.swift`、`DayPage/App/{DayPageApp,RootView,AppNavigationModel}.swift`

---

## 1. 背景

调研报告 §3 把「**和你的过去对话**」（D1）与「**图谱增强检索**」（D2）列为 P0
差异化方向，且有顶会论文背书：

- OmniQuery (arXiv 2409.08250) `3-0`：**先用跨记忆上下文增强、再检索**，胜/平朴素 RAG 74.5%。朴素检索只能捞孤立事实，无法回答需要推断上下文的复杂查询。
- Emotion-aware journaling agent (arXiv 2508.20585) `3-0`：AI 日记 agent 用 RAG 提供上下文丰富的对话式交互。

落地前的现状缺口：

1. **LLM 调用逻辑被锁死在编译管线里**。`CompilationService.callDeepSeek`（私有方法）是唯一的 LLM 通道，无法被对话能力复用。
2. **检索是纯关键词 `contains`**。`SearchService` 把每条 memo 当孤立文本扫描，没有沿知识网络扩展——正是 OmniQuery 证明有天花板的做法。
3. **`AskTodayIntent` 是占位**。它把「问问今天」路由到关键词 SearchView，注释里预留了"once an on-device MCP/LLM pipeline is wired up we can re-route"。

## 2. 决策

### 2.1 分层架构（地基 → 检索 → 对话 → 入口）

```
AskTodayIntent / app 入口
        │  daypage://ask?q=…
        ▼
AskPastView（对话 UI，展示来源 chips）
        │
        ▼
MemoryChatService（D1：编排检索 + 对话 + 历史）
        ├──► GraphRetriever（D2：先连后查）──► vault/raw + vault/wiki（只读）
        └──► LLMClient（可复用云端通道）──► DeepSeek
```

四层各自单一职责，互不耦合：

| 组件 | 职责 | 复用 |
|---|---|---|
| `LLMClient` | OpenAI 兼容传输：messages → 重试 → 文本 | 编译与对话**共用**；未来可在前台路径替换为端侧模型 |
| `GraphRetriever` | 关键词种子命中 → 沿 `entityMentions` 扩展一跳邻居实体页 → 带来源标注的上下文 | D1 的检索层；未来可被 D3（MCP）/向量索引替换 |
| `MemoryChatService` | `@MainActor ObservableObject`：检索→组装 prompt→调 LLM→多轮历史 | — |
| `AskPastView` | 对话界面 + 来源 chips（把"连"显性化） | — |

### 2.2 D2「先连后查」的具体实现

1. **种子命中**：复用 `SearchService.search`（不重复造关键词检索）。
2. **回读 entityMentions**：`SearchResult` 不含 `entityMentions`，故按命中日期回读 `vault/raw/*.md`，从 `Memo.entityMentions` 收集邻居 slug。
3. **图谱扩展**：沿 slug 读 `vault/wiki/{places,people,themes}/{slug}.md`，解析 `name` / `occurrence_count`，按出现次数降序取前 N。同时把 query 本身 slug 化作为直接命中候选（用户问"清迈"可直接命中地点页）。
4. **组装**：`RetrievedContext.toPromptContext()` 渲染"相关原始记录 + 相关实体"两块，带日期/情绪标注，供 LLM 引用。

纯本地、零 token、零网络——这是 D1 对话的检索基质。

### 2.3 入口重路由

`AskTodayIntent` 从 `daypage://search` 改为 `daypage://ask`。`DayPageApp.onOpenURL`
新增 `ask` 分支，把 query 写入 `AppNavigationModel.pendingAskQuery`；`RootView`
用 `.sheet(item:)` 观察并弹出 `AskPastView`。原 `search` 路由保留给 ArchiveView。

## 3. 架构红线遵守（研究报告 §5）

- **iOS 后台 GPU 限制**：`MemoryChatService` **只在前台被用户主动调用**，不绑定 `BGTaskScheduler`。后台编译保留云端 DeepSeek。端侧模型（D4）若引入，只替换前台 `LLMClient`，后台不动。
- **token 成本**：对话 `max_tokens` 限 1500、历史只带最近 4 轮，控制单次成本。
- **图谱价值显性化**（§5 风险 4）：对话回答下方用 chips 展示"依据"（命中日期 + 实体名），让用户直接看到"连"比"存"多了什么。

## 4. 权衡与未竟项

- **检索仍是关键词种子 + 一跳扩展**，非向量召回。够 MVP；语义召回留待 ADR-0002 的 SQLiteVec / 向量索引接入后增强 `GraphRetriever` 的种子阶段。
- **多跳图谱**：当前只扩展一跳邻居。多跳（实体→实体）在实体页尚未存关系边前不做。
- **DeepSeek vs qwen**：研究文档写的是 qwen，实际代码用 DeepSeek（`deepseek-v4-pro`）。`LLMClient.Config.deepSeek()` 沿用现有配置，不在本 ADR 内切换 provider。

## 5. 测试

`DayPageTests/MemoryChatTests.swift` 覆盖：`LLMClient.parseContent`（含空响应抛错）、
`GraphRetriever.parseEntityPage` / `bodySummary`（frontmatter + 正文解析、name 缺失回退 slug）、
`RetrievedContext.toPromptContext`、`MemoryChatService.ask`（用户/助手回合、错误不留空回合、空问题忽略、reset、检索上下文注入 prompt）。
