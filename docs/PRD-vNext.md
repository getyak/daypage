# DayPage vNext — 全项目改进与新功能 PRD

> 版本：Draft v1 · 日期：2026-05-27 · 作者：Claude（基于全仓代码审计）
> 状态：待评审。本文档基于对 `web/`（Next.js 后端+前端）与 `DayPage/`（iOS Swift）整仓代码的事实审计写成，**所有现状结论均附代码位置**，不含臆测。
> 范围：外部信息源集成 · 现有功能补全 · 统计与洞察 · 架构与工程质量。

---

## 0. 文档导航

| 章节 | 内容 |
|---|---|
| [1. 执行摘要](#1-执行摘要) | 一句话现状、核心判断、本 PRD 想达成什么 |
| [2. 现状全景审计](#2-现状全景审计) | 数据层/API/编译/前端/iOS 的真实成熟度（含缺口清单） |
| [3. 产品愿景与北极星](#3-产品愿景与北极星) | DayPage 应该成为什么，为谁 |
| [4. 架构主线决策](#4-架构主线决策) | 三个必须先定的架构问题（双管道、鉴权、sendEvent） |
| [5. 史诗 A：外部信息源集成](#5-史诗-a外部信息源集成) | 统一 Ingest Gateway / Telegram / Claude Code hooks / MCP / RSS / Email / Webhook |
| [6. 史诗 B：统计与洞察仪表盘](#6-史诗-b统计与洞察仪表盘) | 知识活动 + 开发活动 + 数字足迹三维度 |
| [7. 史诗 C：现有功能补全](#7-史诗-c现有功能补全) | home 接真数据 / memo 详情页 / settings 云同步 / 半成品收尾 |
| [8. 史诗 D：架构与工程质量](#8-史诗-d架构与工程质量) | iOS↔Web 统一 / pgvector / 可观测性 / 测试 / 安全 |
| [9. 数据模型变更汇总](#9-数据模型变更汇总) | 所有新增表/字段集中表 |
| [10. API 设计汇总](#10-api-设计汇总) | 所有新增/修改端点集中表 |
| [11. 分期路线图](#11-分期路线图) | Wave 0–4，按价值/成本排序 |
| [12. 风险与开放问题](#12-风险与开放问题) | 需要你拍板的决策点 |
| [13. 附录：现状证据索引](#13-附录现状证据索引) | 关键文件行号速查 |

---

## 1. 执行摘要

### 一句话现状

**DayPage 的后端与数据层远比前端成熟——大量能力"已落库、已建端点，但前端没接或没消费"。iOS 与 Web 则是两套互不同步的独立系统，各有一套会随时间发散的编译管道。**

### 核心判断（决定本 PRD 的写法）

1. **不是从零造，而是"接线 + 收口 + 扩展"。** 例如首页那些 mock 数字（147 sources / 84 wiki / 3.2k backlinks），后端 `/api/stats` 与 `/api/activities` **端点已经存在**（`web/src/app/api/stats/route.ts`、`activities/route.ts`），只是 `home/page.tsx` 用了写死常量没去调。这类"假数据真后端"的缺口，价值高、成本极低。

2. **统一的数据模型是天然的集成底座。** 所有外部源（Telegram / Claude Code / RSS / Email）最终都只需产出一条 `memo`（`origin` 枚举已含 `api`），复用现成的 `memo/created` → Inngest 编译管道。集成的边际成本主要在"鉴权 + 适配"，不在"重建管道"。

3. **两个架构性债务必须先还，否则后续都在沙上盖楼**：
   - **双编译管道**：iOS 直连 DeepSeek（BGTask 02:00 本地）、Web 用 Inngest+OpenAI（cron 00:30 UTC），输出格式/prompt/配额全不同，且 **iOS 根本没调用 Web 的同步端点**（`/api/memos/bulk` 是有端点无客户端）。
   - **无 API key 鉴权**：所有 28 个端点只认 NextAuth session cookie，没有任何 bearer/API-key 路径。外部源（bot、hook、webhook）无法鉴权写入——这是 Epic A 的前置阻塞。

4. **`sendEvent` 在 dev 静默 no-op**（`web/src/lib/inngest/client.ts:20-22`）是开发期的隐形坑：memo 入库但不编译，且无任何报错。已在本次会话验证。

### 本 PRD 想达成什么

把 DayPage 从"一个设计精良、核心闭环可用、但数据孤岛 + 半接线的个人记录器"，演进为：

> **一个以统一 memo 为中心、能自动从你所有信息流（聊天、编码、阅读、位置、照片）汲取原料，编译成知识网络，并用多维仪表盘反映你"知识/工作/生活"全貌的个人知识操作系统。**

---

## 2. 现状全景审计

### 2.1 成熟度热力图

| 层 | 成熟度 | 说明 |
|---|---|---|
| **数据模型（schema）** | 🟢 高 | 21 张表，多租户隔离完整（`user_id` FK + CASCADE），枚举定义清晰，已含审计表（change_log/activities/prompt_log/schema_cluster_log）、设备表（devices/sync_state/push_token） |
| **API 层** | 🟢 高 | 28 个端点，zod 校验，Upstash 限流，`/api/stats`、`/api/activities` 聚合端点已就绪 |
| **编译管道（Web）** | 🟢 高 | 4 个 Inngest 函数全部接线：compile-memo（事件）、schema-detect（每 50 memo）、daily-page（cron 00:30）、orphan-detect（cron 04:00） |
| **LLM 抽象层** | 🟢 高 | Provider 接口完整（chat/stream/embed/transcribe），OpenAI 在用，DeepSeek/DashScope 在树未连；prompt_log 自动记录每次调用 token |
| **Web 前端核心闭环** | 🟢 高 | chat（带 RAG 引用 + 流式）、wiki、wiki/[slug]、inbox、domain/[slug]、add 全部真实可用 |
| **Web 前端外围** | 🟡 中 | `/home` 半 mock；`/settings` 仅 localStorage；`/memos/[id]` 死链 404 |
| **iOS 端** | 🟡 中 | 功能完整且采集维度丰富（GPS/天气/EXIF/被动位置），但**与 Web 零同步**，自带独立编译管道 |
| **外部集成** | 🔴 无 | Telegram/Slack/RSS/Email/MCP/Webhook **全部不存在**；唯一外部交互是 iOS 出站提 GitHub issue |
| **API key 鉴权** | 🔴 无 | 仅 session cookie，无机器对机器鉴权路径 |
| **iOS↔Web 同步** | 🔴 无 | `/api/memos/bulk` 端点存在但 iOS 无调用代码 |

### 2.2 "假数据真后端"缺口清单（高价值低成本）

| 前端展示 | 现状 | 真实数据源（已存在） |
|---|---|---|
| 首页 4 个统计卡（147/84/12/3.2k） | 写死常量 `home/page.tsx:138-156` | `GET /api/stats`（已实现，含周 delta） |
| 首页 Recent activity（6 行） | 写死数组 `home/page.tsx:68-75` | `GET /api/activities`（读 change_log，已实现） |
| 首页 "What the system noticed" | 写死 2 条，按钮 disabled `home/page.tsx:42-65` | `inbox_items`（kind=contradiction/schema/orphan，编译管道已在写） |
| 首页 Domains at a glance | 写死 `domainsMock` + sparkline `home/page.tsx:77-89` | `GET /api/domains` + pages 计数 |

### 2.3 半成品 / coming soon / 死链清单

| 位置 | 类型 | 证据 |
|---|---|---|
| `/memos/[id]` | **死链 404** | `RecentlyCompiled.tsx:67`、`CompileQueue.tsx:292` href 指向不存在的路由 |
| `/home` 3 个按钮 | disabled | `home/page.tsx:50-52,214,293` |
| `/chat/[id]` 附件按钮 | coming soon | `ChatView.tsx:317` |
| `/wiki/[slug]` "Ask about this page" | coming soon | `wiki/[slug]/page.tsx:364` |
| `/add` 语音输入 | coming soon | `UnifiedInput.tsx:558` |
| `/settings` 暗色主题 | disabled "soon" | `SettingsClient.tsx:303` |
| `/settings` 账号级同步 | roadmap | `SettingsClient.tsx:235` |
| `/api/drafts/add` | 501 未实现 | route 返回 Not implemented |

### 2.4 已落库但未消费的字段（统计/集成的金矿）

| 表.字段 | 现状 | 可用于 |
|---|---|---|
| `memos.location` (jsonb) | iOS/web 写入，**无读取查询** | 数字足迹地图、位置时间线 |
| `memos.weather` | 写入，无业务逻辑 | 天气-心情关联、足迹增强 |
| `memos.device` / `origin` | 写入，无聚合 | 按来源/设备的活动统计 |
| `memo_attachments.exif` (jsonb) | schema 有，iOS 存成字符串塞 transcript | 摄影统计、GPS 足迹 |
| `memo_attachments.ocr_text` | schema 有，未采集 | 图片内容检索 |
| `activities` 表 | 定义了**无任何读取** | 活动流（首页/全历史） |
| `prompt_log` 表 | 自动写入，无读取 | LLM 用量/成本仪表盘 |
| `pages.embedding` (text 存 JSON) | RAG 用，全表扫描 | 待迁 pgvector（规模化瓶颈） |
| `users.settings` (jsonb) | 预留，未用 | settings 云同步落点 |
| `devices.push_token` | schema 有 | 推送通知 |

### 2.5 iOS↔Web 数据模型错配（同步前必须解决）

| iOS Memo 字段 | Web schema | 状态 |
|---|---|---|
| `type` 含 `.location`/`.mixed` | web 含 `url`/`file`，无 `location`/`mixed` | 枚举不一致 |
| `mood` | 无 | iOS 独有，web 丢弃 |
| `entityMentions[]` | 无 | iOS 独有 |
| `attachments[].transcript` 塞 EXIF 字符串 | `exif` 期望 JSON object | 格式错配 |
| 被动位置访问（visits.json） | 无对应 | iOS 独有 |
| attachment 路径（相对 vault） | `storage_key`（S3） | 存储模型不同，无同步 |

---

## 3. 产品愿景与北极星

### 3.1 目标用户

承袭 CLAUDE.md：**数字游民 / nomad**。延伸画像——一个边旅行边工作的知识工作者/开发者：用手机随手记、用电脑写代码与聊天、读大量资料、位置和环境一直在变。他需要的不是又一个笔记 app，而是一个**把分散信息流自动收拢、并能回答"我这段时间在干什么、想什么、去过哪"的系统**。

### 3.2 北极星指标（建议）

- **主**：每周「自动汲取的 memo 数 / 手动录入的 memo 数」比值 → 衡量"系统替你收料"的程度。
- **辅**：每周编译产出的 live pages 数、知识图谱新增链接数、仪表盘周活打开率。

### 3.3 设计原则

1. **统一 memo 为唯一原料入口**——任何来源最终都是一条 memo，复用编译管道。
2. **采集与编译分离**——采集要快要全（哪怕脏数据），编译负责结构化。
3. **隐私优先**——外部源接入要可审计、可撤销、密钥可轮换；位置/照片等敏感数据本地可控。
4. **复用既有设计系统**——新页面用现成的 6 个 UI 组件 + 18 个 CSS token，不另起炉灶。

---

## 4. 架构主线决策

这三个决策决定后续所有 Epic 的地基，**必须先拍板**。

### 4.1 决策一：iOS 与 Web 的关系（最重要）

**现状**：两套独立系统。iOS 用本地 vault（YAML+Markdown）+ 自带 DeepSeek 编译 + iCloud 冲突合并；Web 用 Postgres + Inngest+OpenAI 编译。`/api/memos/bulk` 端点存在但 iOS 从不调用。两套编译会随时间发散（不同 prompt、不同模型、不同输出格式）。

**三个候选路线**：

| 路线 | 描述 | 优点 | 代价 |
|---|---|---|---|
| **A. Web 为唯一真相源（推荐）** | iOS 退化为"采集 + 展示"客户端：本地 vault 作离线缓存，联网时通过 `/api/memos/bulk` 同步到 Web；**编译只在 Web 端发生**，iOS 拉取编译结果展示。废弃 iOS 的 CompilationService/BackgroundCompilationService。 | 单一编译管道、单一配额、知识图谱统一、外部源天然汇入同一处 | iOS 需重构同步层；离线编译能力丧失（可保留"离线草稿，联网编译"） |
| **B. 显式双体验** | 明确 iOS=本地优先的私密日记，Web=云端知识库，两者**不强求同步**，各自独立。 | 改动最小、隐私最强 | 数据永久分裂，外部源只进 Web，违背"统一原料"愿景 |
| **C. 双向 CRDT 同步** | iOS 与 Web 双向实时同步，本地与云都能编译再合并。 | 理论最完整 | 实现复杂度极高（冲突解决、编译去重），对单人产品过度设计 |

**建议**：**路线 A**。理由——本 PRD 的统计/外部集成两大目标都要求"一个汇聚点"，A 是唯一能让 Telegram/Claude Code/iOS 数据落到同一张知识图谱的路线。先做 iOS→Web 单向同步（采集上行），编译结果下行展示；离线时本地草稿，联网补编译。

**前置任务**（在 Epic D 展开）：统一 memo schema（解决 2.5 的错配）、iOS 实现 bulk 同步客户端、附件上行到对象存储。

### 4.2 决策二：机器对机器鉴权（Epic A 的前置阻塞）

**现状**：28 个端点全部只认 `auth()` 返回的 session.user.email，无 API key/bearer。外部 bot/hook/webhook 无法鉴权写入。

**方案：引入 Personal API Key（PAT）机制**

- 新表 `api_keys`：`id, user_id, name, key_hash(sha256), prefix(前8位明文用于展示), scopes(jsonb, 如 ["memo:write"]), last_used_at, created_at, revoked_at`。
- 新建一个**统一 Ingest 中间件**：解析 `Authorization: Bearer dp_xxx`，按 sha256 比对 `api_keys.key_hash`，解析出 user_id 与 scopes，注入请求上下文。
- 复用现有 Upstash 限流（`web/src/lib/ratelimit.ts`），按 key 维度限流。
- Settings 页新增"API Keys"管理区：生成（只显示一次明文）、命名、查看 last_used、撤销。

**安全要求**：密钥只存 hash；明文仅创建时返回一次；支持撤销与轮换；所有外部写入打 `origin='api'` 并记 `change_log`。

### 4.3 决策三：修复 sendEvent 的 dev no-op

**现状**：`web/src/lib/inngest/client.ts:20-22`，dev 且无 `INNGEST_EVENT_KEY` 时直接 `return`，memo 入库但永不编译，无报错。本会话已验证：必须手动起 Inngest dev server 并补发事件才能编译。

**方案**：
1. 文档化本地开发流程：`npm run dev` + `npm run dev:inngest` 必须同时跑（写进 `web/AGENTS.md` 与 README）。
2. 给 no-op 加一条**显式 warn 日志**（`console.warn("[inngest] event dropped in dev — start dev:inngest or set INNGEST_EVENT_KEY")`），消除"静默"。
3. 可选：dev 下若检测到本地 Inngest server（8288 可达），即使无 key 也走真实 send（让本地体验默认正确）。

---

## 5. 史诗 A：外部信息源集成

> 核心目标。把"信息自动流入"做成 DayPage 的护城河。所有源统一汇入 memo。

### 5.1 架构基石：统一 Ingest Gateway

所有外部源不各写各的 route，而是共用一条**标准化摄入管线**：

```
外部源 → Source Adapter（归一化为 NormalizedInput）
       → Ingest Gateway（鉴权 + 限流 + 去重 + 落 memo + 发 memo/created）
       → 现有 Inngest 编译管道（零改动）
```

**NormalizedInput 契约**（所有 adapter 的输出）：

```
{
  user_id: uuid,            // 由 API key 或源绑定解析
  type: "text|url|voice|photo|file",
  body: string,             // 正文（已是文本）
  source_url?: string,
  origin: "api",            // 统一标记
  source_channel: string,   // "telegram" | "claude-code" | "rss" | "email" | "webhook"
  external_id?: string,     // 源侧唯一 id，用于幂等去重
  ingest_mode: "light|full",
  attachments?: [...],
  metadata?: jsonb          // 源特定上下文
}
```

**新增字段**：`memos.source_channel`（text，可空）、`memos.external_id`（text，可空，与 user_id+source_channel 建唯一索引做幂等）。

**新表 `ingest_sources`**：记录每个用户配置的源（`id, user_id, channel, config(jsonb, 含加密的源密钥/绑定), enabled, created_at`）。

### 5.2 A1：通用 Inbound Webhook + API（最先做，是其它源的基础）

**端点**：`POST /api/ingest`（PAT 鉴权，scope `memo:write`）。

- Body 接受 NormalizedInput 子集（最少 `{ body }`）。
- 幂等：带 `external_id` 时同源重复直接返回已存在 memo。
- 这就是"任何东西都能往里灌"的入口——Zapier/IFTTT/快捷指令/curl 皆可。

**User Story**：
- 作为用户，我能在 Settings 生成一个 API key，然后用 `curl -H "Authorization: Bearer dp_xxx" -d '{"body":"..."}' /api/ingest` 把任意文本变成 memo。
- 验收：带 key 的请求落 memo 且触发编译；无效 key 返回 401；同 `external_id` 重复不产生第二条。

### 5.3 A2：Telegram 集成（nomad 场景最高频）

**形态**：用户私有 Telegram bot，转发/发送消息即成 memo。

**架构**：
- `POST /api/ingest/telegram`（Telegram webhook 目标，用 secret token 校验，见 Telegram `setWebhook` 的 `secret_token`）。
- Adapter 解析 Telegram update：文本→text memo；含 URL→url memo；语音→下载 voice file→转 attachment（走 Whisper 转写）；图片→photo memo（含 caption）。
- 绑定流程：用户在 Settings 点"连接 Telegram"，DayPage 生成一次性绑定码；用户发给 bot `/start <code>`，把 `telegram_chat_id` 写入 `ingest_sources.config`，完成 chat_id↔user_id 绑定。

**User Story**：
- 作为 nomad，我在路上把一条有意思的推文转发给我的 DayPage bot，它当晚就被编译进知识库并可能链接到已有概念页。
- 验收：转发文本/链接/语音/图片各能正确落对应 type 的 memo；未绑定的 chat_id 被拒；绑定可在 Settings 撤销。

**技术注意**：不引入重型 telegram SDK，直接用 Bot API 的 webhook + fetch（符合 CLAUDE.md"优先无依赖"）。语音文件需先 `getFile` 再下载。

### 5.4 A3：Claude Code 双向集成（你特别要的）

分两个方向，互补。

#### 方向一：Claude Code Hooks → 写入 DayPage（编码活动汲取）

利用 Claude Code 的 hooks（如 `Stop`、`SubagentStop`、`PostToolUse`）在每次编码会话结束时，把**会话摘要/决策/解决的问题**作为 memo 推进 DayPage。

**交付物**：
1. 一个轻量 hook 脚本（`integrations/claude-code/daypage-hook.sh` 或 `.js`），读取 hook 传入的会话上下文，调 `POST /api/ingest`（带用户的 DayPage API key），`source_channel="claude-code"`，body 为会话摘要。
2. 一份配置文档：如何在 `~/.claude/settings.json` 的 `hooks` 里注册（`Stop` 事件触发）。
3. memo metadata 带上结构化上下文：`{ repo, branch, files_touched, session_duration, tools_used }`——为 Epic B 的"开发活动统计"提供原料。

**User Story**：
- 作为开发者，我用 Claude Code 改完一个 bug、会话结束时，DayPage 自动收到一条"在 repo X 的分支 Y 解决了 Z"的 memo，无需手动记录。
- 验收：会话结束 hook 触发 → DayPage 出现对应 memo（origin=api, source_channel=claude-code）→ 编译后可在仪表盘的"开发活动"维度统计到。

**隐私**：hook 脚本默认只发摘要不发代码原文；可配置 redaction 规则；API key 存本地 env，不硬编码。

#### 方向二：DayPage 作为 MCP Server → Claude Code 读写知识库

把 DayPage 暴露成一个 MCP server，让 Claude Code（或任何 MCP 客户端）能查询/写入你的知识库。

**MCP 工具集（建议）**：
- `daypage_search(query)` → 走现有 RAG（`web/src/lib/ai/rag.ts`），返回相关 pages。
- `daypage_get_page(slug)` → 读单页。
- `daypage_add_memo(body, type?)` → 走 `/api/ingest`。
- `daypage_list_recent(n)` → 最近 memo/pages。
- `daypage_graph_neighbors(slug)` → 知识图谱邻居（page_links）。

**形态**：独立的 Node MCP server（`integrations/mcp-server/`），用 `@modelcontextprotocol/sdk`，通过 PAT 调 DayPage API。这样你在 Claude Code 里可以"问我的知识库里关于 Raft 我都记过啥"。

**User Story**：
- 作为开发者，我在 Claude Code 里直接让它"查 DayPage 里我关于分布式锁的笔记并据此写代码"，它通过 MCP 工具检索到我的知识页。
- 验收：MCP server 能被 Claude Code 发现；`daypage_search` 返回真实 RAG 结果；`daypage_add_memo` 成功落库。

### 5.5 A4：RSS / 阅读源

- `ingest_sources` 存订阅的 feed URL；一个 Inngest cron（如每小时）拉取各用户的 feed，新条目→url memo（带幂等 `external_id`=feed item guid）。
- 复用 `daily-page.ts` 的 cron 模式。
- 可选 light 模式只存摘要，避免 token 浪费。

**User Story**：作为用户，我订阅几个技术博客的 RSS，新文章自动成为 memo，DayPage 帮我提炼并链接到已有概念。

### 5.6 A5：Email 入站

- 方案：用第三方收信服务（如 Postmark inbound / Cloudflare Email Worker）把发到 `me@daypage-inbox.xxx` 的邮件 POST 到 `/api/ingest/email`。
- Adapter 解析邮件主题+正文+附件→memo。绑定靠发件人地址匹配用户（或专属转发地址带 token）。
- 比 IMAP 轮询轻，无需常驻连接。

**User Story**：作为用户，我把想稍后处理的邮件转发到我的 DayPage 地址，它就进了知识库。

### 5.7 A6：浏览器扩展 / 快捷指令（轻量补充）

- 现状已有 bookmarklet（`add/page.tsx:95`）。升级为正式浏览器扩展：一键剪藏当前页（标题+URL+选中文本+可选正文抽取）→ `/api/ingest`。
- iOS 侧：Share Extension + 快捷指令，把任意 app 的分享内容发到 `/api/ingest`。

### 5.8 Epic A 汇总：源 × 状态 × 优先级

| 源 | 端点 | 鉴权 | 优先级 | 依赖 |
|---|---|---|---|---|
| 通用 Webhook/API | `POST /api/ingest` | PAT | **P0** | 决策二（API key） |
| Telegram | `POST /api/ingest/telegram` | secret token + 绑定 | **P0** | A1 |
| Claude Code hooks | 复用 `/api/ingest` | PAT | **P1** | A1 |
| DayPage MCP server | 独立 server 调 API | PAT | **P1** | A1 |
| RSS | Inngest cron | 源绑定 | P2 | A1 |
| Email 入站 | `POST /api/ingest/email` | 转发地址 token | P2 | A1 |
| 浏览器扩展/快捷指令 | 复用 `/api/ingest` | PAT | P2 | A1 |

---

## 6. 史诗 B：统计与洞察仪表盘

> 你要的"统计相关信息"。做成一个统一的 `/insights` 仪表盘，三大维度。底层数据多数**已落库未消费**（见 2.4），主要工作是聚合 + 可视化。

### 6.1 总体设计

- 新页面 `/insights`（`(app)/insights/page.tsx`），server component 拉聚合数据，复用现有 `Card`/`Sparkline`/`Chip`/`SectionLabel`。
- 时间范围切换：今天 / 本周 / 本月 / 全部。
- 新增聚合端点 `GET /api/insights?range=&dimension=`，或拆成多个细端点（见 §10）。
- 复用并扩展现有 `/api/stats`（已含 sources/pages/domains/backlinks + 周 delta）。

### 6.2 维度一：个人知识活动

| 指标 | 数据源 | 备注 |
|---|---|---|
| memo 录入趋势（日/周折线） | `memos.created_at` group by day | sparkline |
| 编译成功率 | `memos.compile_status` 占比 | done/failed/pending 饼图 |
| 知识图谱增长 | `pages` + `page_links` 按周计数 | 累计曲线 |
| 主题/领域分布 | `pages.domain_id` group by | 各 domain 的 page 数 |
| 活跃概念 Top N | `pages.backlink_count` desc | 被引用最多的概念 |
| 孤立页清理 | `inbox_items.kind='orphan'` | 待整理 |
| 知识矛盾 | `inbox_items.kind='contradiction'` | 待裁决 |
| 实体增长 | `pages.type='entity'` 计数趋势 | 人/地/物 |

**关键**：`activities` 表当前**无任何读取**——这里把它点亮成"活动流"组件，同时也修复首页 Recent activity 的 mock（见 Epic C）。

### 6.3 维度二：开发/工作活动（依赖 Claude Code 集成 A3）

源自 Claude Code hooks 推送的 memo（`source_channel='claude-code'`，metadata 带 repo/branch/files/duration/tools）。

| 指标 | 数据源 | 备注 |
|---|---|---|
| 编码会话数（日/周） | `memos where source_channel='claude-code'` | 趋势 |
| 触及的 repo 分布 | `metadata->>'repo'` group by | 你在哪些项目上花时间 |
| 解决的问题/决策数 | 编译后的 page（type=source/synthesis） | 从会话摘要提炼 |
| 会话时长累计 | `metadata->>'session_duration'` sum | 投入度 |
| 常用工具/技术 | `metadata->'tools_used'` 聚合 | 技术栈画像 |

**价值**：对 nomad 开发者，这是一份**自动生成的"我在编程上做了什么"的周报原料**——无需手动记。

### 6.4 维度三：生活 / 数字足迹（依赖 iOS 数据上行 A·决策一）

源自 iOS 已采集但 Web 未消费的字段（`memos.location`、`weather`、`memo_attachments.exif`、被动位置 visits）。

| 指标 | 数据源 | 备注 |
|---|---|---|
| 位置足迹地图 | `memos.location` (lat/lng) | 地图打点 / 城市切换时间线 |
| 城市/国家停留时长 | 被动位置 visits（arrival/departure） | nomad 的"我在每个城市待了多久" |
| 天气-记录关联 | `memos.weather` × created_at | "我在什么天气下记得最多" |
| 摄影统计 | `memo_attachments.exif`（光圈/快门/ISO/焦距） | 镜头/参数偏好（摄影爱好者向） |
| 记录的时间节律 | `created_at` 按小时分布 | 你是晨型还是夜型记录者 |
| 设备来源分布 | `memos.device` / `origin` | iOS vs Web vs API 占比 |

**前置**：需先解决 EXIF 格式错配（iOS 把 EXIF 存成字符串塞 transcript，应改存结构化 `exif` jsonb，见 §2.5、Epic D）。

### 6.5 维度四（横切）：系统/成本洞察

| 指标 | 数据源 | 备注 |
|---|---|---|
| LLM token 用量/成本 | `prompt_log`（kind/model/tokens_in/out） | **当前无读取**，点亮它 |
| 按模型/操作类型分布 | `prompt_log` group by kind, model | chat vs embed vs transcribe |
| 编译耗时分布 | 可新增 compile 计时字段 | 性能监控 |
| embed cache 命中率 | `embed_cache` 命中日志 | 成本优化效果 |

### 6.6 衍生功能：自动周报 / 复盘

把上述维度组合成一份**每周自动生成的"复盘页"**（新 Inngest cron，复用 daily-page 模式）：
- "本周你记了 N 条、编译出 M 页、知识图谱新增 K 条链接"
- "你主要在思考 [topic cluster]"
- "编码上你在 repo X/Y 投入最多"
- "你去过 [城市]，停留 D 天"
- 落为一个 `type='synthesis'` 的 page，可在 `/insights` 顶部展示。

**User Story**：作为 nomad，每周一早上我打开 DayPage 看到一份自动复盘，知道上周的知识/工作/足迹全貌，无需自己整理。

### 6.7 Epic B User Stories 验收要点

- `/insights` 页所有数字均来自真实查询，无 mock。
- 三大维度可按时间范围筛选。
- 知识维度即使没有 Claude Code/iOS 数据也能独立工作（优雅降级：无数据维度显示"连接 X 以解锁"）。
- 周报 cron 能为有数据的用户生成 synthesis page。

---

## 7. 史诗 C：现有功能补全

> 把"设计稿壳子"和死链收口。多数是接线活，价值立竿见影。

### 7.1 C1：首页接真数据（最高性价比）

把 `home/page.tsx` 的四块 mock 全部换成真实查询：

| 块 | 改法 |
|---|---|
| 4 个统计卡 | 调 `GET /api/stats`（已实现） |
| Recent activity | 调 `GET /api/activities`（已实现，读 change_log） |
| What the system noticed | 调 `inbox_items`（kind=contradiction/schema/orphan），按钮接真实 resolve/dismiss（端点已存在 `/api/inbox/[id]/resolve|dismiss|snooze`） |
| Domains at a glance | 调 `GET /api/domains` + 各 domain 的 page 计数；sparkline 用真实周趋势 |

**验收**：首页无任何写死常量；空状态正确（新用户看到引导而非假数字）；"Draft the page"等按钮接通或明确移除。

### 7.2 C2：memo 详情页（修死链）

新建 `(app)/memos/[id]/page.tsx`，修复 `RecentlyCompiled.tsx:67`、`CompileQueue.tsx:292` 的 404。

页面内容：
- memo 原文（body）、type、来源（origin/source_channel/device）、时间、位置、天气。
- 附件展示（图片缩略图、语音播放+transcript）。
- 编译状态与结果：链接到它编译出的 pages（走 `page_sources` 反查）。
- 操作：recompile（端点已存在）、编辑（PATCH 已存在）、删除（DELETE 已存在）。

**验收**：从队列/最近编译点进来不再 404；能看到 memo 全貌及其产物；recompile/编辑/删除可用。

### 7.3 C3：Settings 云同步

把 `/settings` 从 localStorage 升级为账号级（`SettingsClient.tsx:235` 标注的 roadmap）。
- 落点：`users.settings` jsonb（已预留）。
- 新端点 `GET/PATCH /api/settings`。
- 同步：主题、密度、AI 模型偏好、通知设置。
- 顺带实现 disabled 的暗色主题（`SettingsClient.tsx:303`）——CSS token 已是变量，做 dark 调色板即可。

### 7.4 C4：收口其它 coming soon

| 项 | 处理 |
|---|---|
| `/wiki/[slug]` "Ask about this page"（:364） | 接通：带页面上下文跳转到 `/chat` 新线程（RAG 已有） |
| `/chat/[id]` 附件按钮（:317） | 接通文件/图片上传到对话（或明确延后并移除按钮） |
| `/add` 语音输入（:558） | 接通：录音→Whisper（transcribe 能力已有于 LLM 层） |
| `/api/drafts/add`（501） | 决定：实现草稿同步或删除该端点 |

**原则**：每个 coming soon 要么接通，要么移除——不留 disabled 按钮制造"假功能感"。

---

## 8. 史诗 D：架构与工程质量

### 8.1 D1：统一 iOS↔Web（落实决策一·路线 A）

分步：
1. **统一 memo schema**：解决 §2.5 错配——web 加 `mood`、`entity_mentions`（或并入 metadata）；`type` 枚举对齐（加 `location`/`mixed` 或映射）；EXIF 改结构化 `exif` jsonb。
2. **iOS 实现 bulk 同步客户端**：调用现有 `/api/memos/bulk`（last-write-wins by updated_at 已实现），上行本地 memo。
3. **附件上行**：iOS 本地 asset → 对象存储（`memo_attachments.storage_key`）。
4. **编译收归 Web**：废弃 iOS 的 CompilationService/BackgroundCompilationService，iOS 拉取 Web 编译结果展示；保留"离线草稿，联网补编译"。
5. **设备注册**：iOS 注册到 `devices` 表，填 `push_token`，用 `sync_state.cursor` 做增量同步。

### 8.2 D2：embedding 迁移到 pgvector

**现状**：`pages.embedding`/`memos.embedding` 用 `text` 存 JSON 数组，RAG 和 recall 是**全表扫描 + 内存余弦**（`rag.ts`、`compile-memo.ts` recall step）。memo/page 一多就是性能悬崖。

**方案**：启用 pgvector 扩展，embedding 改 `vector(1536)` 列，加 ivfflat/hnsw 索引，检索改 SQL 近邻查询。迁移脚本把现有 JSON 文本转 vector。

### 8.3 D3：可观测性

- 已有 Sentry（iOS）。Web 端接 Sentry/日志聚合。
- 点亮 `prompt_log` 读取做成本看板（Epic B §6.5）。
- 编译管道加结构化日志与计时（Inngest step 级别）。
- 健康检查端点：DB、Inngest、LLM provider 可达性。

### 8.4 D4：测试

- **Web**：当前测试覆盖未知。建立 Vitest 单测（schema 校验、adapter 归一化、聚合查询）+ Playwright E2E（`test:e2e` 脚本已存在，补关键流程：add→compile→wiki、ingest API、登录）。
- **iOS**：DayPageTests（Swift Testing）补同步/解析测试。
- **目标**：关键路径 80% 覆盖（承袭全局 RULES.md）。

### 8.5 D5：安全加固

| 项 | 现状 | 动作 |
|---|---|---|
| iOS GitHub bot token | **硬编码**于 Secrets（FeedbackService） | 移到后端代理端点，iOS 不持有 token |
| API key 机制 | 无 | 实现 PAT（决策二）：只存 hash、可撤销、可轮换 |
| 外部 ingest 输入 | N/A | 严格 zod 校验、大小限制、内容清洗（XSS） |
| 限流 | 仅 memos mutations | 扩展到所有 ingest 与新端点 |
| 密钥管理 | `.env.local` + GeneratedSecrets | 审计无明文入库；源密钥（Telegram token 等）加密存 `ingest_sources.config` |
| webhook 校验 | N/A | Telegram secret_token、email 转发 token、Inngest 签名 |

### 8.6 D6：开发体验

- 文档化 `dev` + `dev:inngest` 双进程（决策三）。
- 修 sendEvent 静默 no-op 加 warn。
- 一键本地启动脚本（含 Inngest dev server + DB）。

---

## 9. 数据模型变更汇总

| 变更 | 类型 | 用途 | Epic |
|---|---|---|---|
| `api_keys` 表 | 新增 | PAT 鉴权（key_hash/prefix/scopes/last_used/revoked） | 决策二 |
| `ingest_sources` 表 | 新增 | 外部源配置与绑定（channel/config 加密/enabled） | Epic A |
| `memos.source_channel` | 新增字段 | 标记来源（telegram/claude-code/rss...） | Epic A/B |
| `memos.external_id` | 新增字段 | 源侧唯一 id，幂等去重（与 user_id+channel 唯一索引） | Epic A |
| `memos.mood` | 新增字段 | iOS 已采集，统一 schema | Epic D |
| `memos.entity_mentions` 或并入 metadata | 新增 | iOS 已采集 | Epic D |
| `memos.type` 枚举 | 修改 | 对齐 iOS（location/mixed） | Epic D |
| `memo_attachments.exif` | 改用法 | 从字符串改结构化 jsonb | Epic D |
| `pages.embedding` / `memos.embedding` | 改类型 | text → vector(1536) + 索引 | Epic D |
| `users.settings` | 启用 | settings 云同步落点 | Epic C |
| `devices.push_token` | 启用 | 推送通知 | Epic D |
| 周报 synthesis page | 新增数据 | type=synthesis 的复盘页 | Epic B |

---

## 10. API 设计汇总

| 端点 | 方法 | 鉴权 | 用途 | 状态 |
|---|---|---|---|---|
| `/api/ingest` | POST | PAT | 通用摄入（所有源基础） | 新增 |
| `/api/ingest/telegram` | POST | secret token | Telegram webhook | 新增 |
| `/api/ingest/email` | POST | 转发 token | Email 入站 | 新增 |
| `/api/keys` | GET/POST/DELETE | session | API key 管理 | 新增 |
| `/api/sources` | GET/POST/PATCH/DELETE | session | 外部源配置 | 新增 |
| `/api/insights` | GET | session | 仪表盘聚合（或拆细端点） | 新增 |
| `/api/settings` | GET/PATCH | session | settings 云同步 | 新增 |
| `/api/stats` | GET | session | 首页统计 | **已存在，前端待接** |
| `/api/activities` | GET | session | 活动流 | **已存在，前端待接** |
| `/api/memos/bulk` | POST | session | iOS 同步 | **已存在，iOS 待接** |
| `/api/drafts/add` | GET/PUT | session | 草稿同步 | 待决定（实现或删除） |

**MCP server**（独立进程，非 HTTP route）：`daypage_search` / `get_page` / `add_memo` / `list_recent` / `graph_neighbors`，通过 PAT 调上述 API。

---

## 11. 分期路线图

> 按"价值 ÷ 成本"排序。每个 Wave 结束应可独立交付价值。每项遵循 CLAUDE.md：issue → 分支 → 实现 → 验证 → PR。

### Wave 0：地基与速赢（1–2 周）
- **决策三**：修 sendEvent no-op + 文档化 dev:inngest（半天）。
- **C1**：首页接真数据（stats/activities/inbox/domains 端点已就绪）——**立刻消灭最显眼的 mock**。
- **C2**：memo 详情页（修死链 404）。
- 产出：首页变真、死链修复、本地开发不再踩 no-op 坑。

### Wave 1：集成地基（2–3 周）
- **决策二**：PAT 鉴权（`api_keys` + Ingest 中间件 + Settings 管理 UI）。
- **A1**：通用 `/api/ingest` + 幂等。
- **A2**：Telegram 集成（端到端：绑定→转发→编译）。
- 产出：第一个"信息自动流入"的源跑通；任何外部系统可经 API 灌入。

### Wave 2：Claude Code 双向 + 开发统计（2–3 周）
- **A3 方向一**：Claude Code hooks → DayPage（编码活动汲取）。
- **A3 方向二**：DayPage MCP server。
- **B 维度二**：开发活动统计（依赖 A3 数据）。
- 产出：你的编码活动自动进知识库并可统计；Claude Code 能读你的知识库。

### Wave 3：仪表盘与洞察（2–3 周）
- **B**：`/insights` 完整三维度仪表盘 + 系统/成本维度。
- **B 衍生**：自动周报 cron。
- **C3/C4**：settings 云同步 + 暗色主题 + 收口 coming soon。
- 产出：统计诉求全面落地。

### Wave 4：架构收口与规模化（3–4 周）
- **决策一/D1**：iOS↔Web 统一（路线 A），消除双编译管道。
- **B 维度三**：生活/数字足迹统计（依赖 iOS 数据上行 + EXIF 结构化）。
- **D2**：pgvector 迁移。
- **D4/D5**：测试与安全加固（含 iOS bot token 下沉）。
- **A4/A5/A6**：RSS / Email / 浏览器扩展（按需）。
- 产出：单一真相源、可规模化、可观测、安全。

---

## 12. 风险与开放问题

| # | 问题 | 需你拍板 |
|---|---|---|
| 1 | iOS↔Web 走路线 A（Web 唯一真相）还是 B（显式双体验）？ | **影响最大**，决定 Wave 4 与整体愿景 |
| 2 | Claude Code 集成优先哪个方向？hooks 写入（编码统计）还是 MCP server（知识库读取）？ | 决定 Wave 2 顺序 |
| 3 | 外部源密钥/隐私边界：Telegram/email 数据敏感，是否需端到端加密或本地处理选项？ | 隐私策略 |
| 4 | LLM 后端是否要切/加 Claude（Anthropic）？现 OpenAI，DeepSeek/DashScope 在树未连。 | provider 策略（改 `index.ts:14` 一行 + 新增 adapter） |
| 5 | 周报/复盘的推送渠道：站内？Telegram bot 回推？邮件？ | 复用集成回路 |
| 6 | 对象存储选型（附件上行）：S3 / R2 / Supabase Storage？ | Wave 4 前定 |
| 7 | `/api/drafts/add`（501）：实现还是删除？ | 收口决策 |

---

## 13. 附录：现状证据索引

**数据层**
- schema：`web/src/lib/db/schema.ts`（21 表，枚举、索引、CASCADE）
- 迁移：`web/drizzle/migrations/`
- memo zod：`web/src/lib/schemas/memo.ts`

**API**
- 28 端点：`web/src/app/api/**/route.ts`
- 已存在聚合：`web/src/app/api/stats/route.ts`、`activities/route.ts`
- iOS 同步端点（无客户端）：`web/src/app/api/memos/bulk/route.ts`
- 鉴权：`web/src/auth.ts`
- 限流：`web/src/lib/ratelimit.ts`

**编译**
- `web/src/lib/inngest/functions/compile-memo.ts`（事件 memo/created）
- `schema-detect.ts`（每 50 memo）、`daily-page.ts`（cron 00:30 UTC）、`orphan-detect.ts`（cron 04:00 UTC）
- sendEvent no-op：`web/src/lib/inngest/client.ts:20-22`

**LLM**
- `web/src/lib/ai/`（index/openai/deepseek/dashscope/provider/rag/embed-utils/prompt-log）
- 当前 backend：`index.ts:14`（= openai）

**前端**
- 半 mock 首页：`web/src/app/(app)/home/page.tsx:42-89,138-157`
- 死链：`(app)/add/RecentlyCompiled.tsx:67`、`CompileQueue.tsx:292`
- 设计系统：`web/src/components/ui/`、`web/src/app/globals.css:4-90`

**iOS**
- 模型：`DayPage/Models/Memo.swift`
- 采集服务：`DayPage/Services/{Location,Weather,Photo,Voice,PassiveLocation}Service.swift`
- 独立编译：`DayPage/Services/{Compilation,BackgroundCompilation}Service.swift`
- GitHub 反馈（硬编码 token）：`DayPage/Services/FeedbackService.swift`

---

*本 PRD 为活文档。每个 Epic 落地前应拆为独立 GitHub issue，按 CLAUDE.md 流程（issue → 分支 → 实现 → 验证 → PR）执行。*
