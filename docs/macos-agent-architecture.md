# DayPage macOS — Agent-First Desktop Workstation 架构设计

> 状态：初稿 (2026-06-30)
> 作者：xiongxinwei + Claude (deep-research 工作流，107 个并行 agent，84% claim 通过 3/3 对抗验证)
> 适用范围：DayPage macOS 桌面 app 的架构选型与对标分析；不替代 PRD
> 配套 ADR：本文档稳定后拆出 ADR-0005 (Mac target + 代码共享)、ADR-0006 (Agent 编排)、ADR-0007 (沙盒 + 工具调用)、ADR-0008 (本地/云 LLM 路由)

---

## 0. TL;DR — 推荐方案一句话版

DayPage macOS 是一个 **SwiftUI 原生 Mac target**（不走 Catalyst），通过 SwiftPM `DayPageKit` 与 iOS 共享 vault/services/models 三层，UI 全分叉。**Agent 编排照搬 Claude Code Agent Teams 的「Lead + Teammates + 共享任务列表 + 邮箱」骨架**，沙盒走 macOS 内置 Seatbelt + Unix-domain-socket egress proxy（与 Anthropic 同款），AppleScript 列为 Tier-2 显式授权能力。**本地 LLM 走 MLX**（吞吐量第一），**云端走现有 DashScope/DeepSeek + Claude Sonnet**（用于长上下文/agentic），路由器三层决策：PII → 任务分类 → 置信度逃逸。**RAG 用 sqlite-vec 单文件库 + `nomic-embed-text` 768 dim 嵌入**，存在 vault 内随 iCloud 同步。**UI 是「Plan → Approve → Execute」三态 + 菜单栏 HUD**，不是纯 chat。

---

## 1. 产品定位与设计约束

### 1.1 定位
DayPage macOS ≠ "iOS 端的大屏版"。**它是把 DayPage 的 vault 作为长期记忆的 Agent 桌面工作站**，做三件 iOS 永远做不到的事：

1. **本地工具调用**：读写 vault 文件、跑 shell、用 AppleScript/Accessibility 操控 Mail/Calendar/Notes/浏览器，全部在 sandbox 内
2. **代码/repo 理解**：能读懂用户 git repo，跑命令、生成 patch（参考 Codex CLI / Claude Code）
3. **主动洞察**：基于 vault RAG，主动推"三个月前你提过这个想法"

### 1.2 硬约束（必须保留兼容）

| 资产 | 现状 | macOS 端约束 |
|---|---|---|
| vault | YAML frontmatter + Markdown，`vault/raw/YYYY-MM-DD.md` | iCloud Drive 双向同步，schema 不变 |
| AI 编译 | DashScope qwen3.5-plus，2:00 AM BGTaskScheduler | macOS 端用 `LaunchAgent` 替代 BGTask，编译逻辑下沉到 `DayPageKit` 共享 |
| iOS SwiftUI 代码 | TodayView/ArchiveView/GraphView 等 | UI 全分叉，**只共享 Models/Services/Utilities** |
| web/ Next.js | 已有 Today/Archive 镜像 | macOS 不依赖 web 端；二者通过 vault + Supabase 共存 |

### 1.3 非目标
- **不做** Catalyst 移植版（详见 §3）
- **不做** 跨平台 Electron / Tauri 壳（破坏原生体验，且无法用 Apple 框架）
- **不做** 把 Claude Code 或 Codex CLI 当外部 daemon 调用（虽然有 "thin gateway" 架构先例 [^bswen]，但放弃了 DayPage 自有 agent 路由与 UX 主权）

---

## 2. Agent 编排架构

### 2.1 对标矩阵

| 产品 | 编排模型 | 并行原语 | 长期记忆 | 沙盒 | 上下文管理 |
|---|---|---|---|---|---|
| **Claude Code Agent Teams** [^cc-teams] | Lead + Teammates，共享 task list + mailbox | 文件锁 + DAG 依赖图 | 项目文件 (`CLAUDE.md` / MCP) — **teammate 不继承 lead 历史** | macOS Seatbelt + bubblewrap [^cc-sandbox-blog] | 每个 teammate 独立 context window |
| **Codex CLI / OMX v2** [^omx] | Codex CLI 作为 executor，OMX 编排 | tmux + git worktree per agent | git history + AGENTS.md | (依赖 CLI 自身) | 每个 worker 独立 worktree |
| **Cursor / Claude Code 实战栈** [^zyte] | 角色专精 agent + 权限范围 (R/O vs edit/bash) | plan-mode-first，子任务串行 | git + 项目文件 | (Claude Code Seatbelt) | scout agent (Gemini 2.5 Flash 1M 窗口) 返回结构化报告 |
| **wshobson/agents marketplace** [^wshobson] | 一份 Markdown → 适配 5 个 harness | 插件目录自动发现，按需加载 | (harness 决定) | (harness 决定) | "只加载你装的插件，不加载整个 marketplace" |
| **Claude Code CLI wrapper** [^bswen] | 把 Claude Code CLI 当 subprocess，自己只做路由/UI | asyncio subprocess + 300s timeout | (委托给 CLI) | (委托给 CLI) | "wrap, don't reimplement" |
| **Ralph Loop** [^ralph] | Pick → Implement → Validate → Commit → Reset | git worktree per agent，3-5 agent 上限 | 4 通道：git history / 进度日志 / task 文件 / AGENTS.md | (依赖底层 harness) | 每 cycle stateless，agent 在 85% token 预算自动暂停 |

### 2.2 DayPage 选择：抄 Claude Code Agent Teams 的骨架

**理由**：
- Anthropic 在 Agent Teams 文档里给出的"sweet spot 3-5 teammates × 5-6 任务" [^cc-teams] 是经验校准过的数字，直接拿来用，不用自己摸
- 用文件锁 + 共享 task list 实现并发，**不需要 daemon**——和 DayPage 现有「vault-as-source-of-truth」哲学完全对齐
- Teammate 不继承 lead 历史 [^cc-teams] 这一条尤其重要：**它从架构上强迫长期记忆必须落到磁盘**，正好是 DayPage 的 vault

**不抄的部分**：
- 不抄 `~/.claude/teams/` 目录布局，DayPage 用 `vault/.daypage/agent-teams/{team-name}/`，跟着 vault 走 iCloud 同步
- 不抄 mailbox 字段名（用 DayPage 自己的 schema）

### 2.3 具体设计

```
DayPage macOS 进程
├─ MainWindow (SwiftUI)
│  └─ PlanApproveExecute UI (§7)
├─ AgentOrchestrator (新增, @MainActor)
│  ├─ TeamLeadAgent — 接收用户意图，分解任务，写 task list
│  ├─ TaskList (FileLock + DAG, 存 vault/.daypage/agent-teams/{id}/tasks.json)
│  ├─ Mailbox (append-only JSONL, 存同上目录)
│  └─ TeammatePool — 派生 N 个独立 LLM 会话，按角色拆分
│       ├─ Scout (cheap model, 读取/索引/检索，无写权限)
│       ├─ Planner (high model, 只读 + 出方案)
│       ├─ Executor (mid model, 工具调用 + 写)
│       └─ Critic (mid model, review executor 输出)
├─ ToolHost (XPC service, 见 §4)
└─ LLMRouter (见 §5)
```

**关键决策点**：

| 决策 | 选择 | 依据 |
|---|---|---|
| 并行上限 | **3-5 teammates** | Anthropic 实测 sweet spot [^cc-teams] |
| 工作隔离 | **每个 executor 一个 git worktree**（如果在 repo 内）；否则 vault 子目录 | OMX 经验 [^omx] |
| 上下文重载 | **每次 spawn 重新读 vault `AGENTS.md` + 任务相关文件** | Claude Code 模型 [^cc-teams] |
| Memory 来源 | **人写的 `vault/AGENTS.md` 作为骨架**，vault 检索做为运行时上下文 | Osmani 实测 LLM 生成的 AGENTS.md 反而降低成功率 ~3% [^osmani] |
| 模型分层 | Scout/Critic 用 Haiku/qwen-flash，Planner 用 Opus/qwen-max，Executor 用 Sonnet/qwen-plus | Claude Code Agent Teams + zyte 实战 [^cc-teams][^zyte] |
| 一次任务最大字段 | **token 预算 85% 时硬性暂停** | Ralph Loop 安全机制 [^ralph] |

### 2.4 已被对抗验证 *否决* 的诱惑选项

| 诱惑 | 为什么放弃 |
|---|---|
| "三层 tier (in-process / local orchestrator / cloud async) 二选一" | Osmani 的原文恰恰说「2026 大多数开发者会同时用三层」，prescriptive 版本与源头相反 [^osmani] |
| "Lead + 共享 task list + DAG 是真正并行 agent 的唯一架构" | Microsoft / Google / LangGraph 都有 graph-based cyclic / hub-and-spoke / swarm 等其它有效拓扑；选 Claude Code 模型是合规于 DayPage，不是「唯一」 |
| "包一层 Claude Code CLI 当 subprocess 就行" | 架构上可行 [^bswen]，但放弃了路由权和 UX 主权——DayPage 是产品不是 IDE 插件 |

---

## 3. SwiftUI macOS 代码共享策略

### 3.1 对标：Catalyst vs 原生 SwiftUI Mac target

| 维度 | Mac Catalyst | 原生 SwiftUI macOS target |
|---|---|---|
| Apple 定位 | "把已有 iPad app 端到 Mac" [^medium-3] | "新 Mac app 的首选" [^medium-3] |
| 行业现状 (2022 Ventura 数据) | 在 Apple 自家系统 app 中**已经平台化**（plateau） [^timac] | macOS 系统 app 中 SwiftUI 占比 ~12% 且 Apple 自己在用 SwiftUI 重写 System Settings / Font Book [^timac] |
| `MenuBarExtra` 支持 | ❌ macOS-only API，Catalyst 不可用 [^apple-forum-649675] | ✅ 原生支持 |
| `Settings` scene | ❌ 同上 | ✅ 原生支持 |
| 窗口/菜单/document flow | 受 iPad 隐喻约束，长期技术债 [^medium-3] | 原生 Mac 隐喻 |
| 与 iOS 代码共享 | 完整共享 UI（这是它的卖点） | UI 全分叉，**只共享 model/service** |

### 3.2 DayPage 选择：原生 SwiftUI Mac target + SwiftPM `DayPageKit`

**理由**：
1. DayPage 是 **agent-first 工作站**，需要菜单栏常驻（`MenuBarExtra`）和系统级 Settings——这两个 Catalyst 都不支持
2. iOS 端的 TodayView/ArchiveView 是为「单人手持 + 触摸 + 小屏」设计的，Mac 上反而**需要重新设计**多窗口/键盘/侧栏布局
3. iOS 代码 90% 是 SwiftUI（不是 UIKit），用 Catalyst 的"复用 UIKit"卖点对 DayPage 没价值
4. Apple 战略轴线明确：AppKit = legacy，Catalyst = transitional，SwiftUI = future [^timac]

### 3.3 共享层 `DayPageKit` 设计

新增 SPM 包，结构：

```
DayPageKit/
├─ Sources/
│  ├─ DayPageModels/        ← Memo, Attachment, YAML parser (全复用)
│  ├─ DayPageStorage/       ← RawStorage, ConflictMerger, SyncQueueService (全复用)
│  ├─ DayPageServices/      ← Location, Weather, Voice (复用), Compilation (复用核心，UI 分叉)
│  ├─ DayPageRAG/           ← 新增，§6 详述
│  └─ DayPageAgentKit/      ← 新增，§2 的 AgentOrchestrator/TaskList/Mailbox
└─ Tests/
```

`DayPage` (iOS) 和 `DayPageMac` (macOS) 两个 target 都 `dependencies: ["DayPageKit"]`。

**分叉的部分**（不进 DayPageKit）：
- 所有 `Features/*/View.swift` —— UI 两端独立
- `App/RootView.swift` —— iOS 是抽屉 sidebar，Mac 是 `NavigationSplitView`
- `Resources/*.xcassets` —— icon/launch screen 不同
- `Config/GeneratedSecrets.swift` —— 各自一份（不共享，避免 entitlement 混乱）

### 3.4 Xcode 项目布局

```
daypage/
├─ DayPage.xcworkspace
├─ DayPage.xcodeproj           ← iOS target，保持现状
├─ DayPageMac/                  ← 新增
│   ├─ DayPageMac.xcodeproj
│   ├─ App/                    ← MacApp, NavigationSplitView, MenuBarExtra
│   ├─ Features/
│   │   ├─ Chat/               ← agent 对话窗口
│   │   ├─ Plan/               ← Plan-Approve-Execute 三态 UI
│   │   ├─ TodayMac/           ← Today 的桌面版
│   │   └─ ArchiveMac/         ← Archive 的桌面版
│   └─ Resources/
└─ DayPageKit/                  ← SPM package, 两端共享
```

**simulator 约束扩展**：iOS 仍用 iPhone 17；Mac 端用 macOS 26+ Apple Silicon 实机测试，不走 macCatalyst destination。

---

## 4. macOS 原生集成 + Sandbox 安全模型

### 4.1 对标：Claude Code 怎么做的

Anthropic 在公开博客和 docs 里完整披露了 Claude Code 的沙盒架构 [^cc-sandbox-blog][^cc-sandbox-docs]：

| 关注点 | Claude Code 做法 | DayPage 直接复用？ |
|---|---|---|
| OS 沙盒基元 | **macOS Seatbelt** (`sandbox-exec`)，Linux bubblewrap | ✅ macOS 端完全复用 Seatbelt |
| 安装负担 | macOS 零安装（Seatbelt 内置） | ✅ |
| 文件写入边界 | **默认只能写 cwd + $TMPDIR**；子进程继承同样边界 | ✅ DayPage 把 "cwd" 替换为「当前任务的 worktree / vault 子路径」 |
| 文件读取边界 | **默认读权限不受限**（包括 `~/.aws`, `~/.ssh`！）—— 必须用 `sandbox.credentials` 或 `denyRead` 显式封堵 [^cc-sandbox-docs] | ⚠️ DayPage 必须 **默认开启 credentials 屏蔽**，反转 Claude Code 默认 |
| 网络出口 | **所有出网走 Unix domain socket → 沙盒外 proxy 验证 hostname** [^cc-sandbox-blog] | ✅ 直接照搬 |
| 网络细节 | proxy 按 hostname 允许，不做 TLS 拦截，**理论上易被 domain fronting 绕过** [^cc-sandbox-docs] | ⚠️ 列入文档；高敏模式下提供 TLS-terminating proxy 选项 |
| Apple Events | **默认禁用**；`open` / `osascript` 返回 errno -600；`allowAppleEvents=true` **会消解代码执行隔离** [^cc-sandbox-docs] | ⚠️ DayPage 把 AppleScript 列为 Tier-2 权限，UX 必须显式弹窗 |
| 减少审批弹窗 | Anthropic 内部数据：沙盒化让确认弹窗减少 **84%** [^cc-sandbox-blog] | ✅ 这是 sandbox-first 路线的核心 ROI 论据 |
| 沙盒覆盖范围 | **只覆盖 Bash subprocess**，Read/Edit/Write 文件工具、computer-use 用不同边界 | ✅ DayPage 同样分层（见下表） |

### 4.2 DayPage 工具能力分层

| Tier | 工具类 | 沙盒方式 | 用户授权点 |
|---|---|---|---|
| Tier 0 | vault 读写、RAG 查询 | App Sandbox 内 `files.user-selected` + bookmark | 首次选择 vault 目录 |
| Tier 1 | shell 命令（在 git worktree 内） | Seatbelt + Unix socket egress proxy | 全局开关 + 每个 repo 首次确认 |
| Tier 2 | AppleScript / Accessibility / Apple Events | 退出 App Sandbox 或申请 `scripting-targets` 细粒度 entitlement | **每个目标 app + 每个 access group 单独授权** |
| Tier 3 | Computer-use（操控屏幕） | **运行在真实桌面，不在沙盒** [^cc-sandbox-docs] | 默认关闭，明确开关 + 录屏可见 |

### 4.3 关键 entitlement 清单

```xml
<!-- DayPageMac.entitlements -->
<dict>
  <!-- Tier 0 -->
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>

  <!-- 网络出口 (走 proxy) -->
  <key>com.apple.security.network.client</key><true/>

  <!-- Tier 2: AppleScript - 用细粒度 scripting-targets，不要 temporary-exception -->
  <key>com.apple.security.scripting-targets</key>
  <dict>
    <key>com.apple.mail</key><array><string>com.apple.mail.compose</string></array>
    <key>com.apple.iCal</key><array><string>com.apple.iCal.read</string></array>
  </dict>

  <!-- Hardened Runtime - 给 MLX/llama.cpp 留 JIT 通道 -->
  <key>com.apple.security.cs.allow-jit</key><true/>
  <!-- 注意：allow-unsigned-executable-memory 会大幅降低 App Store 通过率，
       优先用 allow-jit 通过 MAP_JIT 路径 -->
</dict>
```

**Apple QA1888 [^qa1888] 给出的硬约束**：
- 沙盒 app 之间 **任何方向** 发送 Apple Event 都要 entitlement
- 申请 `temporary-exception` 针对 **Finder / System Events 几乎必被拒** —— 因为等于授予系统级控制
- Apple 推荐沙盒 app **优先用 NSFileManager 等系统框架，AppleScript 是兜底**
- **Automator action 运行在沙盒外**，是一个可控的"逃生口"

### 4.4 ToolHost 进程拓扑

```
┌─────────────────────────────────┐
│ DayPageMac (主进程, App Sandbox) │  ← UI + AgentOrchestrator + LLMRouter
└──────┬──────────────────┬───────┘
       │ XPC              │ XPC
       ▼                  ▼
┌──────────────┐  ┌──────────────────┐
│ ShellHost    │  │ NetworkProxy     │  ← 沙盒外 helper
│ (Seatbelt    │  │ (UDS endpoint)   │
│  per-task)   │  │  + 域名白名单    │
└──────────────┘  └──────────────────┘
       │
       ▼
┌──────────────────────────┐
│ git worktree per task    │
│ vault/.daypage/work/<id>/│
└──────────────────────────┘
```

- 主进程 **永远在 App Sandbox 内**，便于潜在的 MAS 发行
- 真正执行 shell / git 的子进程在 `ShellHost` helper 里跑，受 Seatbelt profile 约束
- `NetworkProxy` 是一个常驻 helper，所有 agent 出网都走它的 UDS

---

## 5. 本地 vs 云端 LLM 路由

### 5.1 对标：Apple Silicon 推理栈实测

来自 2025-11 的 peer-style benchmark [^arxiv-2511]：

| 框架 | 强项 | 弱项 | 适用场景 |
|---|---|---|---|
| **MLX** | **吞吐量第一**，长上下文 KV cache 拷贝开销低 [^contracollective] | 模型生态依赖 `mlx-community` 转换 | 后台批量编译（DayPage 日报合成、嵌入生成） |
| **MLC-LLM** | **TTFT 第一**（time-to-first-token），中等 prompt 下交互最快 | 部署链路复杂 | 交互式 vault 对话（"刚才说的那个想法"） |
| **Ollama** | 开发体验最好，**0.19 起原生 MLX 后端**：Qwen3.5-35B-A3B NVFP4 **prefill 1810 t/s、decode 112 t/s** [^ollama-mlx] | 比裸 llama.cpp 慢 5-10%，调参选项被隐藏；MLX 后端要求 **32 GB 内存**（不是 MLX 框架本身的限制） | 原型 / 用户自带模型 |
| **llama.cpp** | **GGUF 模型生态最广**（HF 任意 GGUF 直接跑），M4 Pro 24GB 上 7B Q4_K_M ~60-80 t/s、13B ~35-50 t/s | 吞吐量比 MLX 低 20-40% [^contracollective] | 用户用 HF 自带模型时的兜底 |
| **vLLM** | 服务端多租户最强 | **Metal/MPS 仍是实验级，不可用于本地** [^contracollective] | 不选 |
| **PyTorch MPS** | — | 大模型/长上下文有内存约束 [^arxiv-2511] | 不选 |

**硬件门槛**（来自驳倒"32GB 是 MLX 通用门槛"那条 claim 时积累的反向证据）：
- 8 GB：3B 量化跑得起
- 16 GB：7-8B Q4 可用（Qwen2.5-7B / Llama 3.1-8B / Mistral-7B）
- 32 GB+：13B-70B 舒适运行

### 5.2 对标：混合路由的工程实践

| 实践 | 出处 | DayPage 取舍 |
|---|---|---|
| **三柱路由：数据敏感度 / 任务复杂度 / 系统可用性** [^sitepoint] | SitePoint 2026 hybrid guide | ✅ 直接照搬 |
| **敏感请求 fail closed**，不要回退云 [^sitepoint] | 同上 | ✅ PII gate 是硬约束 |
| **量化感知训练 (QAT) 质量退化 <1.3%**，post-training quant 5-10% [^tianpan] | 边缘云路由 2026-04 | ✅ 选模型时优先 QAT 版本 |
| **token-budget 切线**：输出 >512-2048 token 偏云 [^tianpan] | 同上 | ✅ |
| **可用性回退基于失败预算 + 滑动窗口**，p99 > 2× 滚动 5min 中位数 = 延迟尖峰 [^sitepoint] | SitePoint | ✅ 用于自动降级到本地 |
| **本地 quantized 7-13B 适合：分类、短摘要、模板生成**；**云端 frontier 用于：多步推理、长上下文综合、agentic 工具使用、复杂代码生成** [^sitepoint] | 同上 | ✅ 决定哪些 agent role 默认走云 |
| 参考栈：**LiteLLM gateway + Ollama 本地 + Anthropic 云 + LangChain RunnableBranch 路由** [^sitepoint] | 同上 | ⚠️ 不引入 LangChain（Swift 生态没有等价物），手写 RunnableBranch 等价品 |

### 5.3 DayPage `LLMRouter` 设计

```swift
// 伪代码
enum Route {
    case local(MLXModel)       // 默认本地路径
    case localFast(MLCModel)   // 交互优先
    case cloudPlus              // DashScope qwen3.5-plus (现有)
    case cloudFrontier         // DeepSeek R1 或 Claude Sonnet (长上下文/agentic)
}

func route(_ req: LLMRequest) async -> Route {
    // 1. 硬约束：PII 检测，命中 → 本地或拒绝
    if PIIDetector.detect(req.prompt).hasHits { return .local(.qwen7BQ4) }

    // 2. 任务类别
    switch req.taskClass {
    case .classify, .shortSummary, .templateFill: return .local(.qwen7BQ4)
    case .interactiveChat:                         return .localFast(.qwen3BQ4)
    case .dailyCompile:                            return .cloudPlus  // 现有路径
    case .agentExecutor, .longContextSynth:        return .cloudFrontier
    }

    // 3. 置信度逃逸：本地结果 confidence < 阈值 → 云重试
    // 4. 可用性：滚动失败预算超标 → 强制本地，UI 显示 banner
}
```

**关键约束**：
- DayPage 默认 **本地优先**（隐私是 DayPage 的核心价值主张）
- 现有 DashScope qwen3.5-plus 编译路径**不动**，作为 `.cloudPlus`
- 新增 `cloudFrontier` 通道（DeepSeek 或 Claude）只用于 agent executor 长任务
- `LLMRouter` 用同一接口包装现有 `CompilationService` 的云调用，不破坏 iOS 端逻辑

### 5.4 与 vault 隐私的契合
- iOS 端 vault 内容只通过 DashScope 走云（已有，用户已同意）
- macOS 端新增的 agent 检索（§6）默认全部本地嵌入 + 本地推理
- 任何把 vault 内容送云的 agent 操作必须显式 Plan-Approve 阶段告知"本次将发送 N 段 vault 摘要到 X 服务"

---

## 6. RAG 在桌面端的实现

### 6.1 对标：Obsidian 生态的本地 RAG 方案

DayPage 的 vault 结构 (YAML frontmatter + markdown + 用户文本) 和 Obsidian 高度同构，社区已经把 vault → 本地 RAG 这条路趟通。**主要参考四个项目**：

| 项目 | 存储 | 嵌入 | 集成 | DayPage 借鉴点 |
|---|---|---|---|---|
| **obsidian-notes-rag** [^proofgeist] | **sqlite-vec ~200 KB 单文件**（注：单源数据，且 sqlite-vec 仍 pre-1.0），元数据在 SQLite 主表 | 可插拔（OpenAI/Ollama/LM Studio） | MCP server，5 个工具：`search_notes / get_similar / get_note_context / get_stats / reindex` | ✅ 全套采纳 |
| **vault-mcp** [^vault-mcp] | ChromaDB | Sentence Transformers (本地/API) | 同时 FastAPI REST + MCP，**Watchdog 文件监听 + 事件 debounce 实时索引** | ✅ 实时索引 + 双协议暴露 |
| **Nooscope** [^rodneydyer] | SQLite vector | **Ollama `nomic-embed-text` 768/1538 dim，cosine 相似度** | MCP，**Claude Desktop 通过 `claude_desktop_config.json` 接入** | ✅ MCP 是关键 |
| **alexbeattie/local-RAG** [^alexbeattie] | ChromaDB persistent | `nomic-embed-text`，**asymmetric prefix `search_document:` / `search_query:` —— 不加召回降 15-20%** [^alexbeattie] | FastMCP stdio | ✅ asymmetric prefix 必须写进代码 |
| **MotherDuck Obsidian RAG** [^motherduck] | **DuckDB Vector Similarity Search**，**BGE-M3 1024 dim** | local | — | 备选，如需 frontmatter SQL 分析 |

### 6.2 嵌入模型选择

| 模型 | 维度 | 速度 (M2 16GB) | 备注 |
|---|---|---|---|
| **`nomic-embed-text` (via Ollama)** | 768 | 快 | **DayPage 默认选择**；记得加 asymmetric prefix |
| BGE-M3 | 1024 | 慢，M2 16GB 上有 timeout 风险 [^numbpill3d] | 只在需要图文混合时用 |
| Apple `NLEmbedding` (Natural Language) | 内置 | 极快 | 备选，Apple Silicon 原生路径 [^rodneydyer] |
| MLX 自定义模型 | 任选 | 取决于模型 | 高级用户路径 |

### 6.3 分块策略

| 策略 | 出处 | DayPage 应用 |
|---|---|---|
| **Heading-aware (## / ###) + MIN 150 / MAX 2000 char + 15% overlap** | [^alexbeattie][^numbpill3d] | DayPage memo 通常 1-3 段，可以**整条 memo 一块**，多 memo 文件按 `---` 切 |
| **Hierarchical recursive (headings > 段落 > 行 > 句)，~1500 token 上限** (Chonkie RecursiveChunker) | [^proofgeist] | 用于 vault 之外的长文档（PDF 导入等） |
| **保留 code block 完整性，backlinks 作为预构图结构** | [^motherduck] | DayPage Graph 视图的图谱已有，直接复用做 hybrid retrieval |

### 6.4 DayPage `DayPageRAG` 模块设计

```
DayPageKit/DayPageRAG/
├─ VaultIndexer
│  ├─ FileWatcher (FSEvents on macOS, NSMetadataQuery for iCloud)
│  ├─ Chunker (heading-aware)
│  └─ EmbedderProtocol → NomicEmbedder | NLEmbedder | OpenAIEmbedder
├─ VectorStore
│  └─ SqliteVecStore (vault/.daypage/index.db)
│     ├─ chunks 表 (id, memo_id, text, embedding BLOB)
│     └─ vec0 虚拟表 (KNN)
├─ Retriever
│  ├─ semanticSearch(query, k)
│  ├─ backlinkGraph(memoId)
│  └─ hybridRank(semantic, backlink, recency)
└─ MCPServer (可选，对外暴露)
   ├─ search_notes
   ├─ get_similar
   ├─ get_note_context
   ├─ get_stats
   └─ reindex
```

**存储位置**：`vault/.daypage/index.db` ——
- 跟着 vault 走 iCloud 同步（让 iOS 端首次启动也能享受预算好的索引）
- 但 iOS 端**只读**索引，**不重新生成**（iOS 不部署 embedding pipeline，保持轻量）
- macOS 端是唯一写入者，规避双端写冲突

**对外接口**：实现 MCP server，启用后 Claude Desktop / Cursor 也能查 vault——这是 wshobson/agents [^wshobson] "一份 Markdown 适配多 harness" 哲学的延伸：**DayPage vault 就是那份 Markdown**。

### 6.5 Read + Write，不能只读

Nooscope 作者明确强调：**只读的 vault MCP 没用，必须有 write 工具**（inbox capture、daily log append、模板填充） [^rodneydyer]。DayPage MCP 写工具列表：
- `append_memo(date, content, tags)` —— 等价于 DayPage 主 app 的快速输入
- `create_entity(name, kind, props)` —— 写入 graph
- `link_memos(from, to, relation)` —— 维护 backlinks

---

## 7. UI 模式

### 7.1 对标的薄弱面

deep-research 主要 angle 没覆盖 Raycast / Spotlight / 命令面板这一类直接对标的产品。**仅有的间接证据**：
- Plan-mode-first + `/goal` 持久化（zyte 实战）[^zyte] → 暗示不能是纯 chat
- OMX 出货了一个 "live HUD" 作为 CLI 编排的副屏 [^omx] → 暗示需要状态总览面
- OpenCode + OpenRouter 的模型 alias / auto router 路由（auto / free / pareto-code）放在配置里，不放在 chat slash command [^zyte]

下面的设计基于现有 macOS UI 经验 + iOS 端 DayPage 的产品基调推导，**不是 deep-research 验证过的结论**，在第一版用户测试中需要重新校准。

### 7.2 DayPage macOS UI 三态架构

```
┌─────────────────────────────────────────────────────────────────┐
│ MenuBarExtra (常驻)                                              │
│   "DayPage" 图标 + N 个进行中 agent 任务徽章                      │
│   下拉：今日 memo 数 / agent 队列 / 快速捕获                     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ MainWindow (NavigationSplitView)                                 │
│ ┌──────────┬──────────────────────┬──────────────────────────┐  │
│ │ Sidebar  │ Content              │ Inspector (可折叠)        │  │
│ │          │                      │                          │  │
│ │ - Today  │  [TodayMac]          │  [TaskList]              │  │
│ │ - Archive│  [ArchiveMac]        │  当前 Plan 的待办          │  │
│ │ - Graph  │  [GraphMac]          │  agent 进度 / 工具调用日志│  │
│ │ - Chat   │  [ChatPane]          │                          │  │
│ │ - Plans  │  [PlanInspector]     │                          │  │
│ │          │   ↓ 三态：            │                          │  │
│ │          │   Plan → Approve →   │                          │  │
│ │          │   Execute            │                          │  │
│ └──────────┴──────────────────────┴──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**三态详解**（来自 zyte 经验 [^zyte]）：

1. **Plan**：用户输入意图，agent **不动任何文件**，只输出 markdown 计划：要读哪些 vault 文件 / 调用哪些工具 / 预计成本 / 风险
2. **Approve**：用户逐条勾选/修改/删除计划项；可以 "全选" 也可以单选
3. **Execute**：勾选项进 task list，teammate 池开始执行，Inspector 实时显示每个工具调用 + 输出 + token 消耗

**全局 `/goal` 命令**：在 Chat 顶部输入一条"本次会话目标"，所有 plan/execute 阶段把它注入 prompt，防止漂移。

### 7.3 入口：菜单栏 + 全局快捷键 + Sidebar

- **菜单栏** (`MenuBarExtra`)：常驻入口，看 agent 状态、快速捕获 memo、打开主窗口
- **全局快捷键** (`⌥-Space` 默认，可改)：在任意 app 里调出 "快速捕获" 浮层，类似 Raycast/Alfred 的浮层
- **Sidebar**：iOS 抽屉的桌面版，但 Tab 多两个（Chat、Plans）

### 7.4 不做的事
- **不做** 全屏命令面板替代主窗口（DayPage 是"日记 + agent"，不是 launcher）
- **不做** 纯 chat 首页（Claude Desktop 的形态对 DayPage 错位 —— 日记内容才是主角，chat 是工具）
- **不做** Cursor 那种 IDE 三栏（DayPage 用户不是 100% 程序员）

---

## 8. 与 iOS / web 端的关系

| 端 | 数据写入 | RAG 索引 | Agent 能力 | 主要场景 |
|---|---|---|---|---|
| **iOS** | ✅ 主要捕获端 | ❌ 只读 macOS 生成的索引 | ❌ 无 agent，只有现有 OnThisDay / WeeklyRecap | 移动碎片捕获、查看、语音 |
| **macOS** | ✅ 长文 + agent 自动写入 | ✅ 唯一索引生成者 | ✅ 全 agent 栈 | 整理、深度对话、自动化 |
| **web (Next.js)** | ✅ 浏览器输入 | ❌ 用 Supabase 全文检索，不用本地索引 | ❌ | 借用同事电脑捕获 |

**冲突避免**：
- vault 写入仍走现有 `RawStorage` + `ConflictMerger`（已有 iCloud 冲突解析机制）
- `.daypage/index.db` 只由 macOS 写，iOS/web 只读 → 不需要 vector store 层面的冲突解析
- agent 写入用现有 `SyncQueueService` 派单，保证三端最终一致

---

## 9. 实施路径建议（非 PRD，仅建议）

| 阶段 | 范围 | 验证点 |
|---|---|---|
| **M0：抽 DayPageKit** | 把 Models/Storage/Services 抽进 SPM，iOS 端零行为变化 | iOS 现有测试全过；XCFramework 体积报告 |
| **M1：macOS 壳 + Today 视图** | NavigationSplitView + Today/Archive 桌面版，无 agent | 在 Mac 上能日常用，vault 与 iOS 实时同步 |
| **M2：MenuBarExtra + 全局捕获** | 菜单栏 + `⌥-Space` 浮层 | 一周不打开主窗口也能捕获 |
| **M3：DayPageRAG** | sqlite-vec + nomic-embed-text，搜索 UI | "三个月前我提过 X" 召回率手测 ≥ 80% |
| **M4：单 agent + 工具调用** | Tier 0/1 工具，Plan-Approve-Execute 三态，**只有一个 executor** | 能完成"整理本周散乱 memo 为周报"这类任务 |
| **M5：Agent Teams** | Lead + 3-5 teammates + 共享 task list + mailbox | sweet spot 实测，对比单 agent 的速度/成本/正确率 |
| **M6：LLMRouter + 本地推理** | MLX 后端 + 路由器，PII gate | 本地路径在 16GB Mac 上 P50 < 2s |
| **M7：MCP server** | 暴露 vault 给 Claude Desktop / Cursor | 在 Claude Desktop 里 "在 DayPage 里搜 X" 成功 |
| **M8：Tier 2 AppleScript** | 邮件草稿、日历事件等细粒度 entitlement | TestFlight 通过审核 |

---

## 10. 待研究 / 已知薄弱面

deep-research 流程明确暴露的覆盖盲区，第二轮研究应该补：

1. **macOS UI 模式对标**：Raycast / Alfred / Spotlight 的命令面板、Notion AI / Reflect / Mem 的"笔记 + AI" 形态、Day One 的桌面体验 —— 当前 §7 主要靠 macOS UI 常识推
2. **App Sandbox entitlement 细节**：Apple 官方 entitlements 页和 Hardened Runtime 页在 deep-research 里返回了空结果，§4.3 的 entitlement 清单应该和 Apple 文档逐项核对
3. **Catalyst vs SwiftUI 决策矩阵**：pilky.me 的核心文档抓取失败，§3 的判断主要靠 Apple Forum 间接证据 + DayPage 自身约束推导
4. **iCloud Drive vs Supabase 的 vault 同步在双写场景的鲁棒性**：当 macOS agent 在自动写 vault 时，iOS 端正好也在写同一个 memo，现有 `ConflictMerger` 是否够用？需要专门的回归测试
5. **MLX / MLC-LLM 在 DayPage 实际负载下的对比**：abstract benchmark vs 真实"日报合成 + 5k token 上下文 + 严格 JSON 输出"延迟，需要原型测

---

## 引用

[^cc-teams]: Anthropic, "Agent Teams", code.claude.com/docs/en/agent-teams — Lead + Teammates 架构、3-5 teammate sweet spot、teammate 不继承 lead 历史、文件锁 + DAG 任务依赖
[^cc-sandbox-blog]: Anthropic Engineering, "Claude Code Sandboxing", anthropic.com/engineering/claude-code-sandboxing — macOS Seatbelt + bubblewrap、Unix-domain-socket egress proxy、84% 审批弹窗减少
[^cc-sandbox-docs]: Anthropic, "Sandboxing", code.claude.com/docs/en/sandboxing — 默认写入 cwd + $TMPDIR、默认读权限不受限、Apple Events 禁用、proxy 不做 TLS 拦截
[^osmani]: Addy Osmani, "Code Agent Orchestra", addyosmani.com/blog/code-agent-orchestra — Ralph Loop、AGENTS.md 人写优于 LLM 生成（成功率 -3%、成本 +20%）、tier 1/2/3 分类（注：原文是组合用，不是二选一）
[^ralph]: 同上 (Osmani 博客中 Ralph Loop 部分) — Pick → Implement → Validate → Commit → Reset、85% token 预算自动暂停、git worktree per agent
[^omx]: evomap.ai, "Oh My Codex Agent Orchestration", evomap.ai/blog/oh-my-codex-agent-orchestration-claude-codex — OMX v2 Codex CLI 作为 executor、tmux + git worktree 并发
[^zyte]: Zyte Blog, "My Agentic Coding Setup", zyte.com/blog/my-agentic-coding-setup-claude-code-multi-agent-orchestration-and-how-i-actually-work — 角色专精 + 权限范围、scout agent on Gemini 2.5 Flash、plan-mode-first、`/goal` 持久化、OpenRouter alias 路由
[^wshobson]: wshobson/agents on GitHub — 一份 Markdown 适配 5 个 agent harness、插件目录自动发现、Codex CLI 8KB skill cap、OpenCode permission 块要求
[^bswen]: bswen, "Claude Code CLI Wrapper Architecture", docs.bswen.com/blog/2026-03-16-claude-code-cli-wrapper-architecture — 把 Claude Code CLI 当 subprocess、asyncio + 300s timeout、wrap-don't-reimplement
[^qa1888]: Apple QA1888 — scripting-targets / temporary-exception apple-events entitlement、Finder/System Events 被拒、推荐 NSFileManager > AppleScript、Automator action 在沙盒外
[^timac]: Timac Blog, "State of AppKit Catalyst SwiftUI Mac (Ventura)" — Apple 系统 app 中 SwiftUI ~12%、AppKit 主导但在被替换、Catalyst 平台化、System Settings/Font Book 用 SwiftUI 重写
[^medium-3]: dorangao on Medium, "Native macOS, SwiftUI, and Mac Catalyst — The 3 Apple App Models" — SwiftUI 是新 Mac app 首选、Catalyst 是 iPad 移植路径、错误选择形成长期技术债
[^apple-forum-649675]: Apple Developer Forums Thread 649675 — `Settings` scene / `MenuBarExtra` 是 macOS-only，Catalyst 不可用
[^arxiv-2511]: arXiv:2511.05502 (2025-11) — MLX/MLC-LLM/Ollama/llama.cpp/PyTorch MPS 在 M2 Ultra Qwen-2.5 上的 peer-style benchmark；MLX 吞吐第一、MLC-LLM TTFT 第一、PyTorch MPS 不适合生产
[^ollama-mlx]: Ollama Blog, "MLX", ollama.com/blog/mlx — 0.19 Qwen3.5-35B-A3B NVFP4 prefill 1810 t/s、decode 112 t/s
[^contracollective]: contracollective.com, "llama.cpp vs MLX/Ollama/vLLM on Apple Silicon (2026)" — MLX 比 llama.cpp 高 20-40% 吞吐、M4 Pro 24GB 7B Q4_K_M 60-80 t/s、vLLM 在 Apple Silicon 不可用
[^tianpan]: tianpan.co, "Hybrid Cloud Edge LLM Inference Routing (2026-04)" — 边缘 50-170ms、云端 +20-80ms 网络、PII → 任务分类 → 置信度 → token 预算分层路由、QAT 退化 <1.3% vs PTQ 5-10%
[^sitepoint]: SitePoint, "Hybrid Cloud/Local LLM Architecture Guide 2026" — 三柱路由（敏感度/复杂度/可用性）、敏感请求 fail closed、LiteLLM + Ollama + Anthropic + LangChain RunnableBranch 参考栈
[^proofgeist]: github.com/proofgeist/obsidian-notes-rag — sqlite-vec 单文件 (~200KB)、可插拔嵌入、MCP 5 工具集、Chonkie RecursiveChunker、SQLite + vec0 虚拟表布局
[^vault-mcp]: github.com/robbiemu/vault-mcp — ChromaDB + Sentence Transformers + Watchdog 文件监听 + 事件 debounce、FastAPI + MCP 双协议
[^rodneydyer]: rodneydyer.com, "Your Vault Your Vectors" — Nooscope SQLite 向量、Ollama `nomic-embed-text` 768/1538 dim、Claude Desktop 通过 `claude_desktop_config.json` 接入、Apple `NLEmbedding` 备选、必须有写工具
[^alexbeattie]: alexbeattie.com, "Building Local RAG Pipeline" — `nomic-embed-text` asymmetric prefix `search_document:` / `search_query:`、heading-based 分块、FastMCP stdio
[^motherduck]: motherduck.com, "Obsidian RAG with DuckDB" — DuckDB VSS + BGE-M3、backlinks 作为预构图、584 篇笔记本地嵌入 ~2 小时
[^numbpill3d]: dev.to/numbpill3d, "Local RAG That Actually Works in 2026" — `nomic-embed-text` 在 M2 16GB 推荐、BGE-M3 1024 dim 易 timeout、qwen2.5:14b 8-12 t/s、向量+图谱存 vault 内随 iCloud 同步
