# PRD: Wave 0 — 速赢包（首页接真数据 · memo 详情页 · 修复 sendEvent）

> 关联蓝图：`docs/PRD-vNext.md` Wave 0。本 PRD 为可执行规格，面向开发者/agent 直接落地。
> 默认模拟器 iPhone 17（本 Wave 全是 Web 改动，无 iOS）。Web 在 `web/`，`npm run dev` + `npm run dev:inngest` 双进程。

## 1. Introduction / Overview

DayPage 首页 `/home` 当前大部分是写死的 mock 数据（147 sources / 84 wiki / 3.2k backlinks、Recent activity、Domains），但后端聚合端点 `/api/stats`、`/api/activities` **已经存在**。同时 `/add` 页两个组件链接到不存在的 `/memos/[id]` 路由，点击即 404。本地开发还有个隐形坑：`sendEvent` 在 dev 无 `INNGEST_EVENT_KEY` 时静默丢弃事件，memo 入库但不编译。

本 Wave 把这三处低成本高价值的缺口补齐：首页接真数据、新建 memo 详情页修死链、修复 sendEvent 静默问题。

## 2. Goals

- 首页所有数字/列表来自真实查询，零 mock 常量。
- 点击"最近编译"/"编译队列"条目能进入真实的 memo 详情页，不再 404。
- 本地开发时事件被丢弃不再静默，开发者能立刻察觉并知道怎么修。

## 3. User Stories

### US-001: 首页统计卡接入 /api/stats
**Description:** As a user, I want the home stats cards to show my real numbers so the dashboard reflects my actual knowledge base.

**Acceptance Criteria:**
- [ ] `home/page.tsx:138-156` 的 4 个写死数字（sources/wiki pages/domains/backlinks）改为调用 `GET /api/stats`
- [ ] 周 delta（"+12 this week" 等）来自 stats 端点的真实 delta，而非写死
- [ ] 新用户（数据为空）显示 0 与引导，而非假数字
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-002: 首页 Recent activity 接入 /api/activities
**Description:** As a user, I want recent activity to show what actually happened so I can track my real progress.

**Acceptance Criteria:**
- [ ] 移除 `home/page.tsx:68-75` 的写死 `recent` 数组
- [ ] 改为调用 `GET /api/activities`（读 change_log），按时间倒序展示真实活动
- [ ] 每条活动的目标链接（如指向 wiki page）指向真实存在的路由
- [ ] 空状态正确（无活动时显示引导文案，组件已有空态分支）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-003: 首页 "What the system noticed" 接入 inbox_items
**Description:** As a user, I want the observations section to show real AI-detected items so I can act on them.

**Acceptance Criteria:**
- [ ] 移除 `home/page.tsx:42-65` 的写死 `observations` 数组
- [ ] 改为查询 `inbox_items`（kind ∈ contradiction/schema/orphan，status=open），最多取 N 条
- [ ] 操作按钮接通真实端点：resolve→`/api/inbox/[id]/resolve`、dismiss→`/api/inbox/[id]/dismiss`、snooze→`/api/inbox/[id]/snooze`（端点均已存在）
- [ ] 无 observation 时显示已有的空态
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-004: 首页 Domains at a glance 接入真实 domain
**Description:** As a user, I want the domains section to show my real domains and their page counts.

**Acceptance Criteria:**
- [ ] 移除 `home/page.tsx:77-89` 的 `domainsMock` 与写死 `sparks`
- [ ] 改为调用 `GET /api/domains`，每个 domain 显示真实 page 计数
- [ ] sparkline 用真实周趋势数据（若暂无趋势数据，明确降级为静态或隐藏，不用假数据）
- [ ] "All domains" 按钮接通（跳转到 domain 列表）或明确移除 disabled 状态
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-005: 新建 memo 详情页路由
**Description:** As a user, I want to click a compiled/queued memo and view its detail so I can see the original input and what it became.

**Acceptance Criteria:**
- [ ] 新建 `web/src/app/(app)/memos/[id]/page.tsx`，server component，按 user 鉴权
- [ ] 通过 `GET /api/memos/[id]`（或直接 DB 查询）取 memo，404 时显示 notFound
- [ ] 展示：body 原文、type、来源（origin/device）、created_at、location、weather
- [ ] 展示附件：图片缩略图、语音 + transcript（若有）
- [ ] 通过 `page_sources` 反查并链接到该 memo 编译产出的 pages
- [ ] `RecentlyCompiled.tsx:67` 与 `CompileQueue.tsx:292` 的 `/memos/${id}` 链接点击后正常进入此页，不再 404
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-006: memo 详情页操作（recompile / 删除）
**Description:** As a user, I want to recompile or delete a memo from its detail page.

**Acceptance Criteria:**
- [ ] "Recompile" 按钮调 `POST /api/memos/[id]/recompile`（端点已存在），触发后显示状态变化
- [ ] "Delete" 按钮调 `DELETE /api/memos/[id]`（端点已存在），需二次确认对话框，删除后跳回上一页
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-007: 修复 sendEvent 的 dev 静默 no-op
**Description:** As a developer, I want to be warned when an event is dropped locally so I don't silently lose compilation.

**Acceptance Criteria:**
- [ ] `web/src/lib/inngest/client.ts` 的 no-op 分支（dev 且无 INNGEST_EVENT_KEY）加 `console.warn`，提示需启动 `dev:inngest` 或设 `INNGEST_EVENT_KEY`
- [ ] 在 `web/AGENTS.md` 或 README 文档化本地开发需同时跑 `npm run dev` 与 `npm run dev:inngest`
- [ ] （可选）dev 下若 8288 端口可达则即使无 key 也真实 send，让本地默认正确
- [ ] Typecheck/lint passes

## 4. Functional Requirements

- FR-1: 首页四块（统计卡/活动/观察/领域）全部从真实数据源渲染，移除所有 mock 常量。
- FR-2: 首页对空数据有正确空态，新用户不见假数字。
- FR-3: 存在 `/memos/[id]` 页面路由，展示 memo 全貌及其编译产物。
- FR-4: memo 详情页支持 recompile 与删除（带确认）。
- FR-5: sendEvent 在 dev 丢弃事件时输出 warn，并有文档说明双进程开发流程。

## 5. Non-Goals (Out of Scope)

- 不在本 Wave 做 settings 云同步、暗色主题（属 Wave 3）。
- 不实现新的统计维度（属 Wave 3 的 /insights）。
- 不改动编译管道逻辑本身，只修 sendEvent 的可观测性。
- 不做 memo 详情页的富文本编辑（仅展示 + recompile/删除）。

## 6. Design Considerations

- 复用现有 UI 组件：`Card`、`Sparkline`、`Chip`、`SectionLabel`、`Btn`（`web/src/components/ui/`）。
- 复用 CSS token（`globals.css:4-90`）。
- memo 详情页布局参考 `wiki/[slug]/page.tsx` 的 sources/backlinks 展示模式。

## 7. Technical Considerations

- `/api/stats`、`/api/activities`、`/api/domains` 已存在，确认其响应结构后直接消费。
- 首页是 server component，优先服务端取数（避免客户端 waterfall）；活动流若需分页可客户端增量。
- 验证编译链路需本地起 Inngest dev server（`npm run dev:inngest`）。

## 8. Success Metrics

- 首页 0 处 mock 常量（grep 验证）。
- `/memos/[id]` 点击 404 率归零。
- 本地新开发者按文档双进程启动后，新建 memo 能自动编译（无需手动补发事件）。

## 9. Open Questions

- Recent activity 是否需要分页/"加载更多"，还是固定显示最近 N 条？
- memo 详情页是否需要"编辑 body"能力（PATCH 端点已存在），还是仅展示？
- sparkline 周趋势数据：是否需要新增聚合查询，还是 Wave 0 先静态降级、留到 Wave 3？
