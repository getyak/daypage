# PRD: Wave 2 — Claude Code 双向集成 + 开发活动统计

> 关联蓝图：`docs/PRD-vNext.md` Epic A·A3 + Epic B·维度二。本 PRD 为可执行规格。
> 前置依赖：Wave 1（PAT 鉴权 + `/api/ingest` 必须先就绪）。

## 1. Introduction / Overview

把 DayPage 与 Claude Code 双向打通：
- **方向一（hooks 写入）**：Claude Code 编码会话结束时，通过 hook 自动把会话摘要/决策作为 memo 推进 DayPage，沉淀"我在编程上做了什么"。
- **方向二（MCP server）**：把 DayPage 暴露成 MCP server，让 Claude Code 能检索/写入你的知识库。
- 基于方向一的数据，在 `/insights` 增加"开发活动"统计维度。

## 2. Goals

- Claude Code 会话结束后自动产生一条 DayPage memo（无需手动记录）。
- 在 Claude Code 里能通过 MCP 工具检索 DayPage 知识库并写入 memo。
- 开发活动可被统计：会话数、touched repos、会话时长、技术栈画像。

## 3. User Stories

### US-201: Claude Code hook 脚本
**Description:** As a developer, I want my Claude Code sessions to auto-log to DayPage so my coding work is captured.

**Acceptance Criteria:**
- [ ] 新增 `integrations/claude-code/daypage-hook.{sh,js}`：读取 hook 传入的会话上下文，调 `POST /api/ingest`（带 DayPage API key）
- [ ] 推送 body 为会话摘要（默认只发摘要，不发代码原文）
- [ ] memo metadata 带结构化上下文：`{ repo, branch, files_touched, session_duration, tools_used }`
- [ ] `source_channel='claude-code'`，带 `external_id`（会话 id）做幂等
- [ ] 脚本从本地 env 读 API key，不硬编码
- [ ] 提供 redaction 配置选项（敏感内容过滤）

### US-202: hook 配置文档
**Description:** As a developer, I want clear instructions to register the hook so setup is reproducible.

**Acceptance Criteria:**
- [ ] `integrations/claude-code/README.md` 说明如何在 `~/.claude/settings.json` 的 `hooks` 注册（建议 `Stop` 事件）
- [ ] 含 API key 获取步骤（指向 DayPage Settings）
- [ ] 含 redaction 配置示例

### US-203: hook 端到端验证
**Description:** As a developer, I want to confirm a finished session lands a memo.

**Acceptance Criteria:**
- [ ] 完成一次 Claude Code 会话 → DayPage 出现对应 memo（origin=api, source_channel=claude-code）
- [ ] memo metadata 含 repo/branch/files/duration/tools
- [ ] memo 进入编译并 compile_status=done
- [ ] 同一会话不重复（external_id 幂等）

### US-204: DayPage MCP server 骨架
**Description:** As a developer, I want DayPage exposed as an MCP server so Claude Code can use it as a tool.

**Acceptance Criteria:**
- [ ] 新增 `integrations/mcp-server/`，用 `@modelcontextprotocol/sdk`
- [ ] 通过 PAT 调 DayPage API（不直连 DB）
- [ ] 可被 Claude Code 发现并列出工具
- [ ] README 说明如何在 Claude Code 注册此 MCP server

### US-205: MCP 工具 daypage_search
**Description:** As a developer using Claude Code, I want to search my DayPage knowledge base.

**Acceptance Criteria:**
- [ ] `daypage_search(query)` 工具走现有 RAG（经 API），返回相关 pages（slug/title/excerpt）
- [ ] 在 Claude Code 中调用返回真实结果
- [ ] 错误（无 key/网络）有清晰报错

### US-206: MCP 工具集（get_page / add_memo / list_recent / graph_neighbors）
**Description:** As a developer, I want to read and write DayPage from Claude Code.

**Acceptance Criteria:**
- [ ] `daypage_get_page(slug)` 读单页
- [ ] `daypage_add_memo(body, type?)` 走 `/api/ingest` 写 memo
- [ ] `daypage_list_recent(n)` 返回最近 memo/pages
- [ ] `daypage_graph_neighbors(slug)` 返回 page_links 邻居
- [ ] 每个工具有输入校验与错误处理

### US-207: /insights 开发活动维度
**Description:** As a developer, I want to see stats about my coding activity so I get an automatic work summary.

**Acceptance Criteria:**
- [ ] `/insights`（或 Wave 3 的 insights 页）新增"开发活动"区块
- [ ] 指标：编码会话数（日/周趋势）、touched repos 分布、会话时长累计、常用工具/技术
- [ ] 数据源为 `memos where source_channel='claude-code'` 的 metadata 聚合
- [ ] 无 Claude Code 数据时显示"连接 Claude Code 以解锁"引导（优雅降级）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

## 4. Functional Requirements

- FR-1: 提供 Claude Code hook 脚本，会话结束自动推 memo（含结构化 metadata），默认不泄露代码原文。
- FR-2: DayPage MCP server 提供 search/get_page/add_memo/list_recent/graph_neighbors 工具，经 PAT 调 API。
- FR-3: `/insights` 能从 claude-code memo 的 metadata 聚合出开发活动统计。
- FR-4: 所有 Claude Code 写入幂等（external_id=会话 id）。

## 5. Non-Goals (Out of Scope)

- 不修改 Claude Code 本体，只提供 hook 脚本 + MCP server。
- 不做实时双向同步（hook 是会话结束触发，非实时）。
- 不在 MCP server 内做编译（写入后由 DayPage 编译管道处理）。
- 不发送完整代码 diff（仅摘要 + 元数据，除非用户显式配置）。

## 6. Design Considerations

- hook 脚本保持零/极少依赖，跨平台（macOS/Linux）。
- MCP server 独立进程，不耦合 web 部署。
- 开发活动统计复用 `Card`/`Sparkline`/`Chip`。

## 7. Technical Considerations

- hook 事件类型参考 Claude Code 的 `Stop`/`SubagentStop`/`PostToolUse`。
- MCP server 用 stdio transport，便于 Claude Code 本地接入。
- RAG 检索复用 `web/src/lib/ai/rag.ts` 经 API 暴露。
- metadata 聚合：`memos.metadata` 是 jsonb，用 Postgres jsonb 操作符聚合。

## 8. Success Metrics

- 开发者注册 hook 后，每次会话结束自动产生 1 条 memo，零手动操作。
- Claude Code 中 `daypage_search` 能检索到真实笔记并用于编码。
- 一周后能在 /insights 看到"本周编码会话数 / 投入最多的 repo"。

## 9. Open Questions

- hook 用哪个事件最合适（Stop 还是 SubagentStop）？是否需要去抖（短会话不推）？
- 会话摘要由谁生成——hook 端本地总结，还是发原始上下文让 DayPage 编译时总结？
- MCP server 是否需要写操作的二次确认（防 agent 误写）？
- 开发活动统计是否要关联到具体 page（会话→解决的问题→知识页）？
