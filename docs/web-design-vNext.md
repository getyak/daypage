# DayPage Web — 深度评测与设计方案 (vNext)

> 日期：2026-05-29 · 分支：feat/sidebar-heatmap · 评测基于实跑 dev server + 全量代码审查
> 定位结论（已与产品方确认）：**Web = 桌面知识工作台**（阅读/编织/创作/对话）。捕获交给 iOS + Telegram + connector。
> 愿景四段：**多源采集 → 编译成 wiki → 基于 wiki 定制化 → 作为接入点扩展到其他 AI/agent 创作**。

---

## 0. 一句话结论

DayPage Web 的**架构底子（数据模型、异步管线、provider 抽象、RAG）已经达到产品级**，
但**核心价值闭环——"把碎片编织成知识网络"——尚未真正发生**：实跑结果是 5 个页面全为
`source` 类型、全 `draft`、`0 domains / 0 backlinks`。这不是数据不足，而是一个**冷启动死锁的设计缺陷**（见 §2）。
修复它是 vNext 的 P0，其余三段愿景都建立在它之上。

完成度自评（对照愿景四段）：

| 愿景段 | 完成度 | 卡点 |
|---|---|---|
| ① 多源采集 | ~50% | connector 代码就绪，但 UI 只暴露 Telegram；缺被动源生态 |
| ② 编译成 wiki | ~35% | **冷启动死锁**：永远只生成 source 摘要，不建 concept/entity/link |
| ③ 基于 wiki 定制化 | ~15% | 无自定义视角/模板/domain 规则的 UI |
| ④ 对外 AI/agent 接入点 | ~20% | 有 api_keys+scopes 种子，无 MCP server、无对外检索 API |

---

## 1. 现状全景（实跑实据）

实际登录 dev（`dev@daypage.local`）后逐页确认：

- **`/home`** — 真桌面仪表盘。左导航（Home/Add/Chat/Wiki/Inbox/Insights/Domains/Settings）+ 4 联 stats（14 sources / 5 pages / **0 domains** / **0 backlinks**）+ "系统注意到了什么" + 最近活动。
- **`/add`** — 统一采集入口（"Drop something in, I'll figure out the rest"，自动判定 light/full）。**Compile Queue 里 8+ 条 memo 全卡 QUEUED**。
- **`/wiki`** — 5 个页面**全是 source 类型 + 全 DRAFT**，无一 concept/entity/synthesis/live。
- **`/chat`** — RAG over wiki，定位精准："只答你捕获过的，数字链回源，不知道就说不知道"。
- **`/insights`** — 五维分析：Knowledge / Activity Stream / System & Cost / Development / Digital Footprint（已超出预期）。
- **`/inbox`** — contradiction/schema/orphan/compiled 四类系统主动待办（骨架已在）。
- **`/settings`** — Telegram + API Keys + AI 模型/温度/auto-compile。**email/rss/webhook 配置入口未暴露**（代码已就绪）。
- **`/today`** — iOS 移植的移动捕获流（280pt drawer + ComposerPill），跑在桌面浏览器里——**定位错位**。

技术栈：Next 16 + React 19 + Drizzle/Postgres + pgvector + Inngest（6 条管线）+ NextAuth + 加密 ingest_sources。
数据模型 `memo → page → page_links / page_sources → domains` 把知识图谱关系建模得很干净，`LLMProvider`
接口（chat/chatStream/embed/transcribe）是清晰的 provider 抽象。

---

## 2. P0 — 让"编译成网"真正发生（最高优先级）

### 2.1 根因：冷启动死锁（代码实证）

`src/lib/inngest/functions/compile-memo.ts` 审查结论：

1. `/add` 默认 `ingest_mode = "light"`（schema default；Compile Queue 实测全标 LIGHT）。
2. **LIGHT 模式永远只做一件事**（line 522–597 → apply 728–758）：生成 summary → 建一个
   `type:"source"`、`status:"draft"` 页。**从不召回、从不建 concept/entity/link，且不给生成的 page 写 embedding。**
3. FULL 模式才走 `recall → conflict-check → compile(create_page/extract_entity/create_link)`。
4. 但 `recall`（line 347）要求"已有带 embedding 的 live page"才能召回。

→ **死锁**：LIGHT 建的 source 页既无 embedding 又是 draft → FULL 召回永远为空 →
`compile-full` 的 RETRIEVED_PAGES 永远是 "(none)" → LLM 只能走"create source 摘要"分支 →
永远不会有 concept/entity/link → `0 domains / 0 backlinks` 是**必然结果**，不是数据不足。

### 2.2 修复设计

**(a) 给所有 page 写 embedding（解开死锁的钥匙）**
- LIGHT/FULL 的 apply 阶段，对新建/更新的 page `body_md` 调 `llm.embed()` 并写入 `pages.embedding`。
- 复用现有 `embed_cache`（已有 body_hash TTL 缓存），增量成本低。
- 一旦 page 有 embedding，FULL 的 recall 立即能召回 → 网络开始生长。

**(b) 引入"图谱构建"独立管线，不再依赖逐条 memo 增量**
- 现状的问题：知识编织被绑在"单条 memo 进来"这一个触发点上，且 LIGHT 根本不编织。
- 新增 Inngest 函数 `weave-graph`（cron 或 N 条 memo 触发，复用 `schema-detect` 的聚类逻辑）：
  1. 对当前所有 source/draft 页做向量聚类（已有 `cosineSim` + `MIN_CLUSTER_SIZE` 逻辑）。
  2. 每个簇 → LLM 综合出一个 `concept`/`synthesis` 页（升级到 `status:"live"`）。
  3. 抽取跨页实体 → `entity` 页 + `create_link`。
  4. 自动建议 domain（写 `domains` 表，schema-detect 已设计但未产出）。
- 这把"编织"从"实时增量"解耦成"周期性重构"，更符合"日→周→月→年逐级编译"的产品逻辑。

**(c) page 状态机：draft → live**
- 当前所有页卡在 draft。定义晋升规则：被 ≥2 个 source 引用 或 被 weave-graph 综合过 → live。
- `/wiki` 默认只展示 live，draft 收进"待编织"区——让用户看到的是"知识网络"而非"剪报堆"。

**(d) 编译可靠性 + 可观测（产品级 bug，非 dev 问题）**
- 现状：memo 丢进去可能石沉大海，UI 不报错（dev 下 `sendEvent` no-op；prod 下 Inngest 抖动同样静默丢）。
- 每条 memo 暴露用户可见状态机：`queued → running(step) → done / failed(reason)` + **重试按钮**。
- `compile_step` 字段已存在（normalize|embed|recall|compile|apply|notify），前端做成进度条。
- dev 下 `sendEvent` no-op 时，UI 显式提示"编译服务未连接（运行 npm run dev:inngest）"，而非假装排队。

**(e) 修 RAG 性能债**
- schema 已声明 `vector(1536)` + HNSW 索引，但 `rag.ts` / `compile-memo recall` 仍全表扫 + JS cosine。
- 改用原生 `ORDER BY embedding <=> $1::vector LIMIT k`，走 HNSW。页面规模上去后这是线性 vs 对数的差距。
- 需先核实 migration `0006_pgvector_hnsw.sql` 是否真正应用（embedding 当前疑似仍以 text 存）。

**P0 验收指标**：跑通一批真实 memo 后，`domains > 0`、`backlinks > 0`、wiki 出现至少一个
`concept`/`synthesis` live 页、Compile Queue 不再有永久 QUEUED。

---

## 3. P1-A — 多源采集生态

### 3.1 立即可做：暴露已就绪的 connector
`ingest_sources` 表 + `/api/ingest-sources` 已支持 `telegram/email/rss/webhook/api_claude`，
config 加密存储（`secret-crypto.ts`），但 settings 只露 Telegram。

- settings 新增 **Sources 区**：email（转发地址）、rss（feed URL 列表）、webhook（生成入站 URL + secret）的配置 UI。
- 复用现有 `fetch-rss.ts` 管线（已实现 RSS/Atom 解析）。
- email：给每个用户一个 `<uuid>@in.daypage.app` 转发地址 → `/api/ingest/email` 已存在。

### 3.2 connector 生态规划（被动采集才是"尽可能多"的关键）
当前主力是 `/add` 主动粘贴；愿景要的是**无感被动采集**。优先级：

| Connector | 价值 | 实现路径 |
|---|---|---|
| GitHub | 代码活动（Insights 已有 Development 卡） | OAuth + events API → ingest |
| Readwise / 微信读书 | 阅读高亮（高价值知识源） | API 轮询 → ingest_sources(rss-like) |
| 浏览器历史/书签 | 当前仅一个 Bookmarklet | 扩展 / Bookmarklet 增强 |
| 日历 | 时间线锚点（who/where/when） | CalDAV / Google Calendar |
| 地理轨迹 / 健康 | iOS 端已采集，web 端接收 | 复用 iOS sync_state |

- 统一抽象：所有 connector 落到 `ingest_sources` + 统一 `memo/created` 事件，**不为每个源写一套管线**。
- 每个 connector 声明 `default_ingest_mode`（如 Readwise 高亮 → full，GitHub commit → light）。

---

## 4. P1-B — 基于 wiki 的定制化

让"每一次基于 wiki 做定制化"成为可感知功能。最小可用形态到完整形态：

**(a) 自定义编译视角（MVP）**
- 在一个 domain / 时间段上，让用户说"用 X 视角重新编译"（如"用投资人视角重编我这个月的旅行记录"）。
- 实现：`daily-page.ts` / `weave-graph` 接受可选 `perspective_prompt`，注入 compile prompt。
- UI：domain 页 / wiki 页加"重新编译（自定义视角）"入口。

**(b) 自定义 page 模板**
- 让用户为 `concept`/`entity` 定义结构化模板（如 entity-人物 = 关系/首次出现/相关事件）。
- 存 `users.settings` 或新 `page_templates` 表，compile prompt 按 type 选模板。

**(c) 自定义 domain 规则**
- schema-detect 自动聚类 + 用户可手动定义 domain 关键词/规则覆盖自动结果。

**(d) 把 settings 的"定制"从参数升级为视角**
- 现状只能调 model/temperature。增加"我的知识助手是谁"——一段 persona prompt，贯穿 chat 与 compile。

---

## 5. P1-C — 对外 AI/agent 接入点

愿景终局："基于 wiki 灵活扩展到其他 AI 或 agent 作为接入点，更好地创作"。
现有种子：`api_keys`（含 `scopes` 字段）+ `api_claude` ingest 类型 + `/chat` RAG。缺的是**对外标准协议**。

**(a) MCP Server（最高 ROI，技术成本低）**
- 暴露一个 DayPage MCP server，让 Claude Desktop / Cursor / 任意 MCP 客户端直接读用户 wiki。
- 工具集：`search_wiki(query)`（复用 `rag.ts`）、`get_page(slug)`、`list_domains`、`add_memo(text)`（写回）。
- 鉴权：复用 `api_keys` + `scopes`（read / write 分级）。
- 价值：用户在 Claude 里写作时，Claude 能引用"我自己捕获过的知识"——这就是"接入点扩展到其他 AI 创作"。

**(b) 对外检索 API（key-auth，区别于内部 session-auth API）**
- `GET /api/v1/search?q=`、`GET /api/v1/pages/:slug`，Bearer api_key 鉴权，`scopes` 控权。
- 现有 `/api/pages` 是 session-auth 内部 API，不能直接对外——需新建 v1 命名空间 + key 中间件。

**(c) 出站 webhook（wiki 更新 → 通知外部 agent）**
- wiki 页 create/update/晋升 live 时，向用户配置的 webhook 推送事件 → 触发外部 agent 工作流。
- 复用 `change_log`（已记录 agent_action）作为事件源。

**(d) Obsidian / Logseq 双向同步**
- wiki 是 markdown（`body_md`），导出/同步成本低，触达大量"第二大脑"用户。

---

## 6. P2 — 体验与一致性

- **`/today` 定位收敛**：既定位"桌面知识工作台"，`/today` 移动捕获流应收敛为纯移动响应式或下线，
  桌面只保留 `/add` 作为捕获入口，消除两套 UI 的定位重叠（都能加 memo）。
- **`/wiki` 信息架构**：默认展示知识网络（live concept/entity + 图谱），draft source 收进侧栏"原料"区。
- **空状态引导**：`0 domains/0 backlinks` 时，home 应引导"添加 N 条后我会自动编织出你的第一个知识网络"，
  而非冷冰冰的 0。

---

## 7. 实施顺序（建议）

```
P0  编译成网          ← 先做，否则一切是空中楼阁
 ├─ (a) page embedding（解死锁）
 ├─ (d) 编译可靠性+可观测（用户级 bug）
 ├─ (b) weave-graph 管线
 ├─ (c) draft→live 状态机
 └─ (e) RAG 走 HNSW

P1-C 对外 MCP server   ← 高 ROI、技术成本低、直接兑现愿景④
P1-A 暴露 connector UI ← 代码已就绪，低成本兑现愿景①
P1-B 自定义编译视角    ← 兑现愿景③ MVP

P2  /today 收敛 + wiki IA + 空状态
```

按 CLAUDE.md 流程：每项设计先讨论 → 开 GitHub issue → 分支实现 → 测试 → PR 关联 issue。
建议 P0 拆成 5 个 issue（按 a–e），其余按节拆。

---

## 附：评测一手实据索引

- 冷启动死锁根因：`web/src/lib/inngest/functions/compile-memo.ts:522-597`（LIGHT 永不编织）、`:347`（recall 要求 live+embedding）、`:728-758`（LIGHT apply 建 source/draft、无 embedding）。
- RAG 性能债：`web/src/lib/ai/rag.ts:86-107`（全表扫 + JS cosine，注释自承 pgvector pending）vs `web/src/lib/db/schema.ts`（已声明 hnsw index）。
- connector 就绪未暴露：`web/src/app/api/ingest-sources/route.ts`（支持 5 类源）vs `web/src/app/(app)/settings/`（只有 Telegram/ApiKeys）。
- 对外接入点种子：`web/src/app/api/keys/route.ts`（api_keys + scopes 已存在）。
- 编译静默失败：`web/CLAUDE.md:3`（dev sendEvent no-op）+ `/add` 实测 8+ 条永久 QUEUED。
