# PRD: Wave 3 — 统计洞察仪表盘 + Settings 云同步 + 收口

> 关联蓝图：`docs/PRD-vNext.md` Epic B + Epic C(C3/C4)。本 PRD 为可执行规格。
> 多数底层数据"已落库未消费"（见蓝图 §2.4），本 Wave 把它们点亮成仪表盘。

## 1. Introduction / Overview

DayPage 已默默积累大量数据（`activities`、`prompt_log`、`memos.location/weather/device`、`page_links` 等），但几乎无处展示。本 Wave 新建统一的 `/insights` 仪表盘，呈现知识活动、（横切的）系统/成本两个维度（开发活动维度在 Wave 2、生活足迹维度在 Wave 4），并加自动周报；同时把 Settings 升级为云同步、补齐暗色主题、收口剩余 coming soon。

## 2. Goals

- 一个 `/insights` 页，所有数字真实、可按时间范围筛选。
- 点亮从未被读取的 `activities`、`prompt_log`。
- 自动周报：每周生成一份"知识/系统"复盘 synthesis page。
- Settings 设置项云端持久化（跨设备），支持暗色主题。

## 3. User Stories

### US-301: /insights 页面骨架 + 时间范围切换
**Description:** As a user, I want a dashboard page so I can review my activity at a glance.

**Acceptance Criteria:**
- [ ] 新建 `(app)/insights/page.tsx`，加入侧边栏导航
- [ ] 时间范围切换：今天 / 本周 / 本月 / 全部（状态存 URL params）
- [ ] 复用 Card/Sparkline/Chip/SectionLabel
- [ ] 各维度无数据时优雅降级（空态或"连接 X 解锁"）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-302: 知识活动维度
**Description:** As a user, I want to see my knowledge-building activity.

**Acceptance Criteria:**
- [ ] memo 录入趋势（日/周折线）：`memos.created_at` group by day
- [ ] 编译成功率：`compile_status` 占比（done/failed/pending）
- [ ] 知识图谱增长：`pages` + `page_links` 按周累计
- [ ] 活跃概念 Top N：`pages.backlink_count` desc
- [ ] 领域分布：`pages.domain_id` group by
- [ ] 待整理：`inbox_items`(orphan) 与待裁决矛盾(contradiction) 计数
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-303: 活动流组件（点亮 activities 表）
**Description:** As a user, I want a real activity feed so I can see what happened recently.

**Acceptance Criteria:**
- [ ] 新增 `GET /api/insights/activity`（或复用 `/api/activities`）读取真实活动
- [ ] `/insights` 与首页 Recent activity（Wave 0 已接 /api/activities）数据一致
- [ ] 支持"加载更多"分页
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-304: 系统/成本维度（点亮 prompt_log）
**Description:** As a user, I want to see my LLM usage so I understand the cost of compilation.

**Acceptance Criteria:**
- [ ] 新增聚合查询读取 `prompt_log`：token 用量（in/out）、按 kind(chat/embed/transcribe)、按 model 分布
- [ ] 时间范围内的 token 趋势 sparkline
- [ ] （可选）embed cache 命中率
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-305: 自动周报 cron
**Description:** As a user, I want a weekly recap generated automatically so I don't have to summarize myself.

**Acceptance Criteria:**
- [ ] 新增 Inngest cron 函数（复用 `daily-page.ts` 模式），每周运行一次
- [ ] 为有数据的用户生成一份 `type='synthesis'` 的复盘 page：本周 memo/pages/链接增量、主要思考主题、（若有）开发/足迹概要
- [ ] 周报 page 可在 `/insights` 顶部展示
- [ ] 无数据用户跳过
- [ ] Typecheck passes

### US-306: Settings 云同步
**Description:** As a user, I want my settings to sync across devices so I don't reconfigure each time.

**Acceptance Criteria:**
- [ ] 新增 `GET/PATCH /api/settings`，落 `users.settings` jsonb（已预留字段）
- [ ] `SettingsClient.tsx` 从 localStorage 升级为读写后端（保留 localStorage 作离线/即时缓存）
- [ ] 同步项：主题、密度、AI 模型偏好、通知设置
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-307: 暗色主题
**Description:** As a user, I want a dark theme so the app is comfortable at night.

**Acceptance Criteria:**
- [ ] 实现暗色调色板（CSS token 已是变量，加 dark 变体）
- [ ] 移除 `SettingsClient.tsx:303` 的 disabled，主题选择生效
- [ ] 切换即时生效并随云同步持久化
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-308: 收口剩余 coming soon
**Description:** As a user, I don't want fake disabled buttons; each should either work or be removed.

**Acceptance Criteria:**
- [ ] `/wiki/[slug]` "Ask about this page"(:364)：接通——带页面上下文跳转 `/chat` 新线程
- [ ] `/add` 语音输入(:558)：接通录音→Whisper（LLM transcribe 已有）或明确移除
- [ ] `/chat/[id]` 附件按钮(:317)：接通上传或明确移除
- [ ] `/api/drafts/add`(501)：实现或删除
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

## 4. Functional Requirements

- FR-1: `/insights` 呈现知识活动 + 系统/成本维度，全部真实数据，可按时间筛选。
- FR-2: 点亮 `activities` 与 `prompt_log` 两张此前无读取的表。
- FR-3: 每周自动生成复盘 synthesis page。
- FR-4: Settings 设置项云端持久化并支持暗色主题。
- FR-5: 所有遗留 coming soon 要么接通要么移除。

## 5. Non-Goals (Out of Scope)

- 开发活动维度在 Wave 2 实现；生活/数字足迹维度在 Wave 4（依赖 iOS 数据上行）。
- 不做可导出报表（PDF/CSV）——后续按需。
- 不做多用户对比/排行（单人产品）。

## 6. Design Considerations

- 仪表盘信息密度高，复用 Sparkline 做微图；大图可按需引入（d3 已在依赖）。
- 维度间统一时间范围控件。
- 空态设计要鼓励连接更多源（与 Epic A 形成正循环）。

## 7. Technical Considerations

- 聚合查询尽量用 SQL（group by / 窗口函数）而非应用层循环。
- 大范围（全部）查询注意性能；必要时加物化视图或缓存。
- 周报 cron 复用 daily-page 的"遍历用户 + LLM 总结 + upsert page"模式。

## 8. Success Metrics

- `/insights` 三/四维度全部真实数据，0 mock。
- `activities`、`prompt_log` 从"无读取"变为有展示。
- 周报每周稳定生成；Settings 跨设备一致。

## 9. Open Questions

- 仪表盘是否需要可视化大图（地图/力导图）还是 sparkline 足够？
- 周报推送渠道：仅站内，还是回推 Telegram/邮件（复用 Epic A）？
- token 成本是否需要换算成货币（按模型价格表）？
- 暗色主题：跟随系统还是手动？
