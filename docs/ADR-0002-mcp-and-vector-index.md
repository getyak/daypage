# ADR-0002 · MCP 接入与向量索引

- **状态**：Proposed
- **日期**：2026-06-17
- **关联**：`docs/research-2026-06-storage-and-capture.md` 第 3 节；ADR-0001（同步层）、ADR-0003（schema）
- **影响范围**：`DayPage/Services/Agent/`、`packages/mcp-daypage*/`、`vault/_agent/`

---

## 1. 背景

调研报告 §3 指出"`vault/raw/*.md` 是唯一信源，索引/向量/图谱皆为可丢弃产物"（引用 [11]）。但目前 DayPage **没有任何对外 Agent 接口**——外部 Claude/GPT 想读 vault 必须靠用户复制粘贴。Web 端 wiki 还有"冷启动死锁"（memory `project_web_compile_deadlock.md`）：编译产物不存在 → 网络稀疏 → 没东西可读 → 用户没动力写。

打开 Agent 接入面可以一次性解三件事：

1. 给本地 Claude Code / Cursor / 其他 Agent 一条干净的读写通道。
2. 让 web 端 wiki 直接消费本机产出的 entity/concept/relation。
3. 给"问问今天"这类自然语言查询打底（见 ADR-0004 草案：App Intents → MCP graph server）。

## 2. 选项矩阵

### 2.1 MCP server 形态

| 选项 | 暴露面 | 适合 |
|---|---|---|
| Filesystem-only | raw .md 文件 | 通用，但 Agent 拿到原文还得自己抽实体 |
| Memory（knowledge graph）-only | entity/concept/relation | 高阶 Agent，但失去原文上下文 |
| **Filesystem + Memory 双 server** | 上述两者 | 推荐：原文 + 抽好的图谱并行暴露 |
| 单 server，混合资源 | URI 前缀区分 | 协议上能跑，但分裂 capability 不清晰 |

MCP 三种 capability（**prompts / resources / tools**）由官方 reference servers 验证（引用 [14]）。

### 2.2 向量索引候选

| 候选 | iOS 16 兼容 | 全本地嵌入 | 备注 |
|---|:-:|:-:|---|
| **SQLiteVec**（sqlite-vec Swift 绑定） | ✅ | embedding 走外部 | iOS 侧首选，引用 [15] |
| VecturaKit (NaturalLanguage) | ❌ iOS 18+ / Swift 6 | ✅ Apple NaturalLanguage | 未来切换点，引用 [16] |
| LanceDB via `lancedb_mcp` | macOS/Web ✅，iOS ❌ | embedding 走外部 | Mac/Web 端可同时用，引用 [20][21] |
| Chroma / Turso / Pinecone | — | ❌ 服务端 | 与"本地优先"冲突，拒绝 |

## 3. 决策

### 3.1 暴露**双 MCP server**

| Server | 类型对照 | URI 模式 | Tools |
|---|---|---|---|
| `daypage-files` | 类官方 Filesystem [12] | `file:///vault/raw/YYYY-MM-DD.md`、`file:///vault/raw/assets/...` | `read_memo(date)`、`append_memo(text, metadata?)`、`search_grep(pattern)` |
| `daypage-graph` | 类官方 Memory（KG）[13] | `entity://{slug}`、`concept://{slug}`、`session://{date}-{n}` | `get_entity(slug)`、`link(from, to, rel)`、`traverse(slug, depth)`、`vector_search(query, k)` |

两 server 共享同一本机 vault，但运行时分两个进程（或 Swift 内的两个 socket）以保 capability 边界清晰。

### 3.2 双部署目标

- **macOS / Web 用 Node/Bun 实现**：放 `packages/mcp-daypage-files/`、`packages/mcp-daypage-graph/`，通过 stdin/stdout 走 MCP 标准协议；可被 Claude Code / Cursor / Continue 等 IDE 工具直接 attach。
- **iOS 用 Swift 内嵌**：`DayPage/Services/Agent/MCPServer.swift` 用 Unix domain socket（沙盒内）；主要服务 App 内的"AskTodayIntent"和 web 端走的代理。注意 iOS 沙盒下外部 process 不能直接 attach；这条路径主要给 in-app Agent 调用。

### 3.3 向量索引：分平台

| 平台 | 引擎 | 文件位置 |
|---|---|---|
| iOS | **SQLiteVec** | `vault/_agent/vectors.sqlite`（可丢弃，符合引用 [11]）|
| macOS | SQLiteVec（与 iOS 共代码） | 同上 |
| Web/Node | **LanceDB** via `lancedb_mcp` | `~/.daypage/lancedb/` |

iOS 16/17 阶段 embedding 调用：

- 文本 embedding 现阶段调 DashScope `text-embedding-v3` 或 OpenAI `text-embedding-3-small`（少量调用，可接受云出网；调用频率：单 memo 一次，编译时增量）。
- **当 deployment target 升 iOS 18**：切换 VecturaKit + Apple NaturalLanguage，实现"纯本地、零云出网"嵌入（引用 [16]）。该 PRD 已记入 ADR-0001 风险段。

### 3.4 增量重建

vault 一旦发生 mutation（写入新 memo / AI 编译产出新 entity），Sync 层（ADR-0001）会有 callback。MCP server 监听 callback，**只重建受影响 doc 的 entity 列表 + vectors**。

- 启动时若 `_agent/vectors.sqlite` 缺失 → 全量重建；100 条 memo 应 < 30 秒。
- 删除 `_agent/` 后任何端启动可重建。**这是核心契约**（引用 [11]）。

### 3.5 Entity linking 与 Graph

- 抽实体由 `CompilationService` （DashScope qwen3.5-plus）产出 → 写 `vault/entities/{slug}.md`。
- `daypage-graph` server 启动时扫这些文件 + 计算 backlink → 暴露 `entity://` resource。
- `link(from, to, rel)` tool 用来给 Agent 主动建立 entity 间关系（产出新 `relation:` 字段写回 Markdown）。
- `vector_search` tool 走 SQLiteVec / LanceDB。

## 4. 落地分阶段

| 阶段 | 内容 | 依赖 |
|---|---|---|
| Phase 0 | 本 ADR + ADR-0003 schema v2 | — |
| Phase 1 | `packages/mcp-daypage-files/`（Bun，单文件 ~200 行） | ADR-0003 |
| Phase 2 | `DayPage/Services/Agent/VectorIndex.swift` 包装 sqlite-vec | — |
| Phase 3 | `packages/mcp-daypage-graph/` + EntityResource 抽象 | Phase 1 |
| Phase 4 | iOS in-app MCP socket `MCPServer.swift` | Phase 1/2 |
| Phase 5 | Web 端接 `lancedb_mcp`，复用现有 wiki 编译路径 | — |
| Phase 6 | iOS 18 升级后切 VecturaKit | iOS 18 升级 |

## 5. 风险与退路

| 风险 | 缓解 |
|---|---|
| MCP 标准还在演进，可能 breaking change | 锁住 `@modelcontextprotocol/sdk` minor 版本；测试 nightly Anthropic Claude Code 兼容性 |
| iOS 沙盒下外部 Agent 不能直接 attach | 仅给 in-app 调用；外部 Agent 接 macOS Node 版本 |
| sqlite-vec 二进制大小 / iOS App Store 审核 | 已有项目验证可上架；万一被驳回 → 走 Apple `NLEmbedding`（精度低），或等 iOS 18 + VecturaKit |
| 100+ entity 时 backlink 重建慢 | 增量重建 + 持久化 graph cache |

**退路**：若 MCP 标准短期不稳，退到「只暴露 HTTP JSON API」（DayPage 自定义 `/api/agent/*`），保留资源/工具二分，未来再接 MCP。

## 6. 引用

- [11] [r0b0tlab/llm-wiki obsidian hermes](https://github.com/r0b0tlab/llm-wiki_obsidian_hermes_r0b0tlabbra1n) — "Indexes are disposable"（vote 2-0, 1 abstain）
- [12] [modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers) — Filesystem reference（vote 2-1）
- [13] 同上 — Memory (knowledge graph) reference（vote 3-0）
- [14] 同上 — prompts / resources / tools 三能力（vote 3-0）
- [15] [SQLiteVec](https://github.com/jkrukowski/SQLiteVec) — Swift 绑定（vote 3-0）
- [16] [VecturaKit](https://github.com/rryam/VecturaKit) — iOS 18 + NaturalLanguage（vote 3-0）
- [20] [lancedb_mcp](https://github.com/RyanLisse/lancedb_mcp) — `table://{name}` 资源（vote 3-0）
- [21] 同上 — 本地 `~/.lancedb`（vote 3-0）
