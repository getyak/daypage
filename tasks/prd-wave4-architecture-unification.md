# PRD: Wave 4 — 架构统一（iOS↔Web · pgvector · 足迹统计 · 测试/安全 · 其余源）

> 关联蓝图：`docs/PRD-vNext.md` 决策一 + Epic D + Epic B·维度三 + Epic A(A4/A5/A6)。本 PRD 为可执行规格。
> 这是收口 Wave：还清架构债务、让系统可规模化、可观测、安全。

## 1. Introduction / Overview

DayPage 当前最大架构债务：**iOS 与 Web 是两套互不同步的系统，各有独立编译管道**（iOS 直连 DeepSeek/BGTask 本地，Web 用 Inngest+OpenAI/cron）；`/api/memos/bulk` 端点存在但 iOS 从不调用。本 Wave 落实蓝图决策一·**路线 A（Web 为唯一真相源）**：iOS 退化为采集+展示客户端，编译收归 Web。同时迁移 embedding 到 pgvector、点亮生活/足迹统计、补测试与安全、接入剩余轻量源。

## 2. Goals

- 单一编译管道（Web），消除 iOS/Web 编译发散。
- iOS 采集的数据（含 GPS/天气/EXIF/被动位置）上行到 Web 知识图谱。
- embedding 走 pgvector，RAG/recall 不再全表扫描。
- 生活/数字足迹统计上线。
- 关键路径有测试；硬编码密钥下沉；外部输入受控。

## 3. User Stories

### US-401: 统一 memo schema（解决 iOS↔Web 错配）
**Description:** As a developer, I need iOS and Web memo models aligned so sync doesn't lose data.

**Acceptance Criteria:**
- [ ] Web schema 增补 iOS 独有字段：`mood`、`entity_mentions`（或并入 `metadata`）
- [ ] `memos.type` 枚举对齐（处理 iOS 的 `location`/`mixed`：新增或映射规则）
- [ ] `memo_attachments.exif` 改为结构化 jsonb（iOS 停止把 EXIF 塞进 transcript 字符串）
- [ ] 生成并运行迁移成功
- [ ] Typecheck passes（Web）+ build passes（iOS）

### US-402: iOS 实现 bulk 同步客户端
**Description:** As an iOS user, I want my memos to sync to the cloud so they appear on web.

**Acceptance Criteria:**
- [ ] iOS 新增同步服务，调用现有 `POST /api/memos/bulk`（last-write-wins by updated_at 已实现）
- [ ] 上行本地 vault 的 memo（含 location/weather/device/EXIF 结构化）
- [ ] 用 `devices` 表注册设备 + `sync_state.cursor` 做增量同步
- [ ] 离线时排队，联网后补传
- [ ] iOS build + 同步端到端验证（iPhone 17 模拟器）

### US-403: 附件上行到对象存储
**Description:** As a user, I want my photos/voice to be available on web too.

**Acceptance Criteria:**
- [ ] 选定对象存储（S3/R2/Supabase Storage，见 Open Questions）
- [ ] iOS 本地 asset 上传，回填 `memo_attachments.storage_key`
- [ ] Web memo 详情页能展示这些附件（Wave 0 的详情页已就绪）
- [ ] 上传失败可重试

### US-404: 编译收归 Web
**Description:** As a developer, I want a single compilation pipeline so outputs don't diverge.

**Acceptance Criteria:**
- [ ] 废弃 iOS 的 `CompilationService` / `BackgroundCompilationService`（或降级为"离线草稿，联网后由 Web 编译"）
- [ ] iOS 改为拉取 Web 编译结果（pages/daily）展示
- [ ] 同一天不再被两套管道重复编译
- [ ] iOS build passes；端到端：iOS 记录 → 同步 → Web 编译 → iOS 看到结果

### US-405: embedding 迁移 pgvector
**Description:** As a developer, I want vector search to scale so recall/RAG stays fast.

**Acceptance Criteria:**
- [ ] 启用 pgvector 扩展
- [ ] `pages.embedding` / `memos.embedding` 从 text(JSON) 改 `vector(1536)`，加 ivfflat/hnsw 索引
- [ ] 迁移脚本把现有 JSON 文本转 vector
- [ ] `rag.ts` 与 compile-memo recall step 改用 SQL 近邻查询（不再全表内存余弦）
- [ ] Typecheck passes；RAG 结果与迁移前一致性验证

### US-406: /insights 生活/数字足迹维度
**Description:** As a nomad, I want to see my location/photo footprint so I can review where I've been.

**Acceptance Criteria:**
- [ ] 位置足迹：`memos.location` (lat/lng) 地图打点 / 城市时间线
- [ ] 城市/国家停留时长（基于被动位置 visits，需 iOS 上行）
- [ ] 天气-记录关联：`memos.weather` × created_at
- [ ] 摄影统计：`memo_attachments.exif`（光圈/快门/ISO/焦距）
- [ ] 记录时间节律：`created_at` 按小时分布
- [ ] 设备来源分布：`memos.device` / `origin`
- [ ] 无 iOS 数据时优雅降级
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-407: 安全加固
**Description:** As a developer, I need to remove hardcoded secrets and harden inputs.

**Acceptance Criteria:**
- [ ] iOS GitHub bot token 从 `FeedbackService` 硬编码下沉到后端代理端点；iOS 不再持有 token
- [ ] 外部 ingest 输入：严格 zod 校验 + 大小限制 + HTML 清洗（XSS）
- [ ] 限流扩展到所有 ingest 与新端点
- [ ] `ingest_sources.config` 敏感字段加密存储
- [ ] webhook 校验齐全（Telegram secret_token、email token、Inngest 签名）
- [ ] Typecheck passes

### US-408: 测试基线
**Description:** As a developer, I want tests on critical paths so regressions are caught.

**Acceptance Criteria:**
- [ ] Web Vitest 单测：schema 校验、ingest adapter 归一化、聚合查询
- [ ] Web Playwright E2E（`test:e2e` 脚本已存在）：add→compile→wiki、ingest API、登录
- [ ] iOS DayPageTests：同步、YAML 解析
- [ ] 关键路径 ≥80% 覆盖
- [ ] CI 跑通

### US-409: 可观测性
**Description:** As a developer, I want visibility into pipeline health and cost.

**Acceptance Criteria:**
- [ ] Web 接入 Sentry/日志聚合（iOS 已有 Sentry）
- [ ] 编译管道加结构化日志 + step 级计时
- [ ] 健康检查端点：DB / Inngest / LLM provider 可达性
- [ ] Typecheck passes

### US-410: 剩余轻量源（RSS / Email / 浏览器扩展）
**Description:** As a user, I want more sources to flow in automatically.

**Acceptance Criteria:**
- [ ] RSS：`ingest_sources` 存 feed URL + Inngest cron 拉取，新条目→url memo（external_id=item guid 幂等）
- [ ] Email 入站：`POST /api/ingest/email`（第三方收信服务转发），解析主题/正文/附件→memo
- [ ] 浏览器扩展：升级现有 bookmarklet 为正式扩展，一键剪藏→`/api/ingest`
- [ ] 各源端到端验证
- [ ] Typecheck passes

## 4. Functional Requirements

- FR-1: Web 是唯一编译真相源；iOS 仅采集+展示。
- FR-2: iOS 全量数据（含 GPS/天气/EXIF/被动位置）经 bulk 同步上行。
- FR-3: embedding 用 pgvector + 索引，检索走 SQL 近邻。
- FR-4: `/insights` 上线生活/足迹维度。
- FR-5: 无硬编码密钥；外部输入受控；关键路径有测试与可观测性。
- FR-6: RSS/Email/浏览器扩展按需接入。

## 5. Non-Goals (Out of Scope)

- 不做双向 CRDT 同步（蓝图路线 C，过度设计）。
- 不做 iOS 离线编译保留（除非 Open Questions 另定）。
- 不做团队/多人协作。

## 6. Design Considerations

- iOS 改动大，分步上线（先单向上行，再编译收归，最后下行展示）。
- 足迹地图可引入轻量地图组件；摄影统计复用 Sparkline/Chip。

## 7. Technical Considerations

- pgvector 迁移需停机或在线迁移策略（数据量评估）。
- 对象存储选型影响 iOS 上传实现与成本。
- last-write-wins 已在 bulk 端点实现，注意 iOS↔Web 时钟与 updated_at 一致性。
- 被动位置 visits 当前存 iOS 本地 visits.json，需设计上行映射。

## 8. Success Metrics

- iOS 记录的 memo 100% 出现在 Web；同一天 0 重复编译。
- RAG/recall 在 1 万+ pages 下查询 <200ms（pgvector 后）。
- 关键路径测试覆盖 ≥80%；无硬编码密钥（扫描验证）。
- 足迹维度对有 iOS 数据的用户可用。

## 9. Open Questions

- 对象存储选 S3 / R2 / Supabase Storage？（影响成本与实现）
- iOS 是否保留"离线编译"作为联网前的临时体验，还是完全收归 Web？
- pgvector 迁移走停机还是在线双写？
- 被动位置 visits 的隐私：默认上行还是需用户逐条确认？
- Email 入站用哪家服务（Postmark inbound / Cloudflare Email Worker）？
