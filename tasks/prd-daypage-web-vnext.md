# PRD: DayPage Web vNext —— 编译成网、多源采集、对外 AI/agent 接入点与定制化创作

> 版本：vNext · 日期：2026-05-29 · 平台：**仅 Web**（`web/`，Next.js 桌面知识工作台）
> 依据：① 实跑评测 `docs/web-design-vNext.md`（P0-P2 设计方案）；② 竞品深度研究（deep-research，106 agent / 24 条经对抗验证的断言，见 §11 引用）
> 定位结论（已与产品方确认）：**Web = 桌面知识工作台**（阅读/编织/创作/对话）；捕获交给 iOS + Telegram + connector。

---

## 1. Introduction / Overview

DayPage 是一个个人化知识系统，核心循环是：**多源数据采集 → AI 编译成个人 wiki / 知识网络 → 基于 wiki 做定制化 → 作为接入点扩展到其他 AI/agent 辅助创作**。

本 PRD 解决两层问题：

1. **核心闭环没真正跑通**（P0）：实跑发现 wiki 全是 `source/draft` 页、`0 domains / 0 backlinks`，"把碎片编织成知识网络"因一个**冷启动死锁**（§3.1）而从未发生。
2. **愿景四段的差异化尚未兑现**（P1-P2）：竞品研究证明 DayPage 的 thesis 是对的且生态已验证，但 DayPage 在**对外 MCP 接入点、采集广度、定制化 agent、分析型图谱、时序知识图谱**这些被验证有价值的方向上几乎空白。

竞品研究的三个结构性结论（均经对抗验证，§11）：
- **"个人数据即 MCP 接入点"已是生态共识、正在出货**：Readwise Reader、Mem、Limitless、Cognee、Graphiti/Zep 都把个人记忆通过 MCP server 暴露给 Claude/Cursor/ChatGPT。这正是 DayPage 愿景第四段，且 DayPage 还没做——**单点 ROI 最高的方向**。
- **"丢进来、AI 全帮你整理"是主流制胜 UX**：Mem/Recall/Limitless 验证，且自动建图用**向量相似度**而非手动 `[[backlink]]`。DayPage 已有这个循环，但**采集广度弱**（无浏览器剪藏/社交视频/会议转写）。
- **战略叙事已从"整理你的笔记"转向"在 AI 同质化的时代，你独有的个人知识才是你的护城河"**（Recall: "Your knowledge is your edge"）。这直接支撑 DayPage 的"基于 wiki 定制化"支柱——**护城河是积累的个性化 wiki + 时序记录，不是会被快速同质化的 AI 编译本身**。

---

## 2. Goals

- **G1（P0 核心）**：让"编译成网"真正发生——跑通真实 memo 后 `domains > 0`、`backlinks > 0`、wiki 出现 ≥1 个 `concept`/`synthesis` live 页，且无永久 QUEUED memo。
- **G2（采集可靠性）**：采集→编译之间建立用户可见的可靠性契约（状态机 + 失败原因 + 重试），消灭"石沉大海"。
- **G3（对外接入点）**：交付 DayPage MCP server + 对外检索 API，让任意 MCP 客户端（Claude/Cursor）把用户 wiki 当作上下文——兑现愿景第四段。
- **G4（采集广度）**：暴露已就绪的 connector（email/rss/webhook），并交付浏览器剪藏，补齐竞品验证过的采集广度。
- **G5（定制化）**：交付"自定义编译视角"与"基于 wiki 的可配置 agent"，兑现愿景第三段。
- **G6（差异化护城河）**：交付时序知识图谱查询 + 分析型图谱（结构性 gap → 反思提示），占据无单一竞品完全拥有的白空间。
- **G7（体验一致性）**：收敛 `/today` 移动流定位，重整 `/wiki` 信息架构与空状态引导。

---

## 3. 背景：核心根因与竞品定位（实据）

### 3.1 冷启动死锁（P0 必修，代码实证）

`web/src/lib/inngest/functions/compile-memo.ts` 审查结论：
1. `/add` 默认 `ingest_mode="light"`。
2. LIGHT 模式（`:522-597` → apply `:728-758`）**永远只生成 summary → 建 `type:"source"`、`status:"draft"` 页，从不召回、不建 concept/entity/link、且不给生成的 page 写 embedding**。
3. FULL 模式才编织，但 `recall`（`:347`）要求"已有带 embedding 的 live page"。
4. → **死锁**：LIGHT 建的页既无 embedding 又是 draft → FULL 召回永远为空 → `compile-full` 的 RETRIEVED_PAGES 永远 "(none)" → 永远不产 concept/link → `0 domains/0 backlinks` 是必然结果，非数据不足。

### 3.2 竞品定位速览（经对抗验证的事实，详见 §11）

| 产品 | 定位一句话 | 核心差异化 | 对 DayPage 的启发 |
|---|---|---|---|
| **Readwise Reader** | 阅读 + 高亮聚合器 | 2025-06 上线 MCP server，把高亮实时暴露给 Claude/Cursor | MCP 接入点已是品类 table-stakes；DayPage 应暴露**结构化 wiki+图谱**而非裸高亮 |
| **Mem** | "AI Thought Partner"（认知卸载） | "Just Mem it—and forget it"；2026-03 上线 Claude Connector | dump-and-organize UX 验证；Claude 官方 connector 商店是分发渠道 |
| **Recall** | "Your Knowledge is Your Edge" | 多源一键保存（TikTok/YouTube/播客/PDF）+ 自动建图 + Augmented Browsing；可切换 GPT/Claude/Gemini | 采集广度 + "个人知识=护城河"叙事；多模型可选 |
| **Limitless** | 全天被动捕获的 AI 可穿戴 | 全天录音 → 自动摘要 → lifelog 经 `api.limitless.ai/mcp` 暴露 | 被动捕获是更高维"尽可能多采集"；**注意：2025-12-05 被 Meta 收购并停售 Pendant，趋势存疑** |
| **Reor**（开源本地） | 本地优先 AI 笔记 | 向量相似度自动连接 + 本地 RAG（Ollama/LanceDB）；"两个生成器：LLM 与人" | 自动建图机制验证；**本地优先 = 隐私护城河** |
| **Khoj**（开源自托管） | 开源可自托管的第二大脑 | 用户可创建带自定义知识/persona/模型/工具的 **agent** | **可配置 per-domain agent** 正是 DayPage 愿景第三/四段 |
| **Graphiti/Zep**（开源） | agent 记忆的时序知识图谱 | "实体+关系+时间线"，事实有 validity window、失效而非删除（arxiv 2501.13956） | **时序知识图谱**——DayPage 天然 day-stamped，是无竞品充分利用的白空间 |
| **Cognee**（开源） | 文本 → 结构化 KG 语义层 | 经 MCP 暴露为"agent 可直接访问的持久语义层" | KG-as-MCP 模式验证（注：其差异化**不是**多 provider 抽象，该断言已被证伪 0-3） |
| **InfraNodus** | 分析型知识图谱 | 网络科学指标（Louvain 社区/中介中心性/多样性）+ **结构性 gap 分析 → AI 生成跨 gap 的问题/想法** | **分析型图谱**：把图从被动可视化变成洞察引擎——高价值、retention 驱动、契合反思型受众 |

---

## 4. User Stories

> 约定：每个 story 小到可在一个专注 session 内实现。UI story 必含"浏览器验证"。所有 story 含 typecheck/lint。
> 阶段标记：**[P0]** 核心闭环 · **[P1]** 差异化 · **[P2]** 体验。

### 阶段 P0 —— 让"编译成网"真正发生

#### US-001: [P0] 给所有 page 写 embedding（解开死锁的钥匙）
**Description:** 作为系统，我需要在 compile apply 阶段给新建/更新的 page 写 embedding，使 FULL 召回不再永远为空。

**Acceptance Criteria:**
- [ ] LIGHT/FULL apply 阶段对 page `body_md` 调 `llm.embed()` 写入 `pages.embedding`
- [ ] 复用 `embed_cache`（body_hash TTL）避免重复 embed
- [ ] 跑一批 memo 后，至少一个 page 的 `embedding IS NOT NULL`
- [ ] 后续 FULL 编译的 recall 能返回 >0 个候选页（日志可见）
- [ ] Typecheck/lint passes

#### US-002: [P0] 编译状态机可观测 + 重试
**Description:** 作为用户，我希望看到每条 memo 的编译进度与失败原因，并能手动重试，这样东西不会石沉大海。

**Acceptance Criteria:**
- [ ] memo 卡片显示状态：`queued → running(step) → done / failed(reason)`，复用已有 `compile_step` 字段
- [ ] failed 状态显示 `compile_error` 并提供"重试"按钮（调 `/api/memos/[id]/recompile`）
- [ ] dev 下 `sendEvent` no-op 时，UI 显式提示"编译服务未连接（运行 npm run dev:inngest）"，而非假装 QUEUED
- [ ] Compile Queue 不再出现无解释的永久 QUEUED
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-003: [P0] 新增 weave-graph 周期性图谱构建管线
**Description:** 作为系统，我需要一条独立管线把 source 页聚类、综合成 concept/synthesis 页并建立 link，不再依赖逐条 memo 增量。

**Acceptance Criteria:**
- [ ] 新增 Inngest 函数 `weave-graph`（cron + 每 N 条 memo 触发），复用 `schema-detect` 的 `cosineSim` / `MIN_CLUSTER_SIZE`
- [ ] 对 source/draft 页做向量聚类；每个簇 → LLM 综合出一个 `concept`/`synthesis` 页
- [ ] 跨页抽取 entity → `entity` 页 + `create_link`（写 `page_links`，更新 `backlink_count`）
- [ ] 自动建议并写入 `domains` 表
- [ ] 跑通后 `domains > 0` 且 `backlinks > 0`
- [ ] Typecheck/lint passes

#### US-004: [P0] page 状态机 draft → live + 晋升规则
**Description:** 作为用户，我希望 wiki 默认展示成型的知识网络，而非一堆草稿剪报。

**Acceptance Criteria:**
- [ ] 晋升规则：page 被 ≥2 个 source 引用 或 被 weave-graph 综合过 → `status:"live"`
- [ ] `/wiki` 默认只列 live；draft source 收进"待编织/原料"区
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-005: [P0] RAG 走原生 pgvector HNSW
**Description:** 作为系统，我需要用原生向量检索替换全表扫 + JS cosine，保证页面规模上去后检索仍是对数级。

**Acceptance Criteria:**
- [ ] 核实 migration `0006_pgvector_hnsw.sql` 是否真正应用；embedding 以 `vector(1536)` 存储
- [ ] `rag.ts` retrievePages 与 `compile-memo` recall 改用 `ORDER BY embedding <=> $1::vector LIMIT k`
- [ ] 移除 JS 端全表 cosine 路径
- [ ] 现有 RAG/编译测试通过
- [ ] Typecheck/lint passes

### 阶段 P1 —— 对外接入点（愿景④，单点 ROI 最高）

#### US-010: [P1] DayPage MCP Server（只读）
**Description:** 作为用户，我希望在 Claude/Cursor 里直接检索我的 DayPage wiki，让外部 agent 把我的知识当上下文。

**Acceptance Criteria:**
- [ ] 暴露 MCP server，工具集：`search_wiki(query)`（复用 `rag.ts`）、`get_page(slug)`、`list_domains`
- [ ] 鉴权复用 `api_keys` + `scopes`（read scope）
- [ ] 可在 Claude Desktop 配置并成功检索到真实 wiki 内容
- [ ] 返回结果含来源 slug，可链回 DayPage
- [ ] Typecheck/lint passes

#### US-011: [P1] MCP 写回工具 add_memo
**Description:** 作为用户，我希望在外部 agent 对话中直接把内容存回 DayPage。

**Acceptance Criteria:**
- [ ] MCP 工具 `add_memo(text)`，鉴权需 write scope
- [ ] 写入后触发正常编译管线（`memo/created`）
- [ ] write scope 缺失时明确拒绝
- [ ] Typecheck/lint passes

#### US-012: [P1] 对外检索 API（key-auth v1 命名空间）
**Description:** 作为开发者，我希望用 API key 程序化检索 wiki，区别于内部 session-auth API。

**Acceptance Criteria:**
- [ ] `GET /api/v1/search?q=`、`GET /api/v1/pages/:slug`，Bearer api_key 鉴权
- [ ] `scopes` 控权；无效/越权 key 返回 401/403
- [ ] 命中 `api_keys.last_used_at` 更新
- [ ] Typecheck/lint passes

#### US-013: [P1] 出站 webhook（wiki 更新 → 通知外部 agent）
**Description:** 作为用户，我希望 wiki 页变更时推送事件，触发我的外部 agent 工作流。

**Acceptance Criteria:**
- [ ] page create/update/晋升 live 时，向用户配置的 webhook 推送事件（事件源复用 `change_log`）
- [ ] 推送含签名 secret 供验签
- [ ] settings 可配置 webhook URL 与 secret
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### 阶段 P1 —— 采集广度（愿景①）

#### US-020: [P1] 暴露已就绪的 connector 配置 UI（email/rss/webhook）
**Description:** 作为用户，我希望在 settings 配置 email/rss/webhook 入站源，让数据被动流入。

**Acceptance Criteria:**
- [ ] settings 新增 "Sources" 区：email（个人转发地址 `<uuid>@in.daypage.app`）、rss（feed URL 列表）、webhook（生成入站 URL + secret）
- [ ] 配置落 `ingest_sources`（config 经 `secret-crypto` 加密）
- [ ] rss 复用 `fetch-rss.ts`，新增 feed 后能拉取并产生 memo
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-021: [P1] 浏览器剪藏扩展 / Bookmarklet 增强
**Description:** 作为用户，我希望一键剪藏网页/文章到 DayPage，补齐竞品验证过的最常见采集广度。

**Acceptance Criteria:**
- [ ] 一键把当前网页 URL + 选中正文发送到 `/api/ingest`（key-auth）
- [ ] 剪藏内容进入正常编译管线
- [ ] 支持选中文本片段剪藏（非整页）
- [ ] Typecheck/lint passes

#### US-022: [P1] connector 声明 default_ingest_mode
**Description:** 作为系统，我需要每个源声明默认编译档位，避免高价值源被当作 light 草草处理。

**Acceptance Criteria:**
- [ ] `ingest_sources` 支持 `default_ingest_mode`（light/full）
- [ ] 来自该源的 memo 默认采用其档位（如 Readwise 高亮→full、RSS→light）
- [ ] Typecheck/lint passes

### 阶段 P1 —— 定制化（愿景③）

#### US-030: [P1] 自定义编译视角（MVP）
**Description:** 作为用户，我希望对某个 domain / 时间段说"用 X 视角重新编译"。

**Acceptance Criteria:**
- [ ] `daily-page` / `weave-graph` 接受可选 `perspective_prompt` 注入 compile prompt
- [ ] domain 页 / wiki 页提供"重新编译（自定义视角）"入口
- [ ] 重编结果可见且区别于默认视角
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-031: [P1] 基于 wiki 的可配置 agent
**Description:** 作为用户，我希望定义 grounded 在我 wiki 上的 agent（如"我的写作教练""我的旅行规划助手"），可选模型。

**Acceptance Criteria:**
- [ ] 用户可创建 agent：自定义名称 + persona prompt + 选用模型 + 关联 domain/检索范围
- [ ] agent 对话经 RAG 召回用户 wiki 作为上下文
- [ ] agent 配置持久化（新 `agents` 表或 `users.settings`）
- [ ] 与 MCP（US-010）共享同一检索层
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-032: [P1] 知识助手 persona（贯穿 chat 与 compile）
**Description:** 作为用户，我希望设定"我的知识助手是谁"，让语气/视角贯穿对话与编译。

**Acceptance Criteria:**
- [ ] settings 新增 persona prompt 配置
- [ ] persona 注入 `/chat` 与编译 prompt
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### 阶段 P1/P2 —— 差异化护城河（图谱）

#### US-040: [P1] 时序知识图谱查询（"as of 某日" / "X 的演变"）
**Description:** 作为用户，我希望查询"我对 X 的想法如何演变""三月时我的认知是什么"，利用 DayPage 天然的 day-stamped 数据。

**Acceptance Criteria:**
- [ ] page_links / page 版本带时间维度，支持按日期窗口查询（事实失效而非删除）
- [ ] 提供"某概念随时间演变"的视图或 chat 查询
- [ ] 验证：对同一 entity 在不同月份的 memo 能呈现演变而非覆盖
- [ ] Typecheck/lint passes

#### US-041: [P2] 分析型图谱：结构性 gap 检测 + 反思提示
**Description:** 作为用户，我希望系统指出"你写了 A 和 B 几周却从未连接——这是一个桥接问题"，把图从可视化变成洞察引擎（对标 InfraNodus）。

**Acceptance Criteria:**
- [ ] 对知识图谱跑社区检测 + 结构性 gap 分析（识别"应连未连"的簇）
- [ ] 对检测到的 gap 用 LLM 生成跨 gap 的反思问题/想法，落 `inbox_items`（kind 复用或新增）
- [ ] 用户可在 inbox 看到并采纳/忽略
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### 阶段 P2 —— 体验与一致性

#### US-050: [P2] /today 移动流定位收敛
**Description:** 作为产品，web 既定位桌面知识工作台，应消除 `/today` 移动流与桌面捕获的定位重叠。

**Acceptance Criteria:**
- [ ] `/today` 收敛为纯移动响应式 或 下线；桌面捕获统一走 `/add`
- [ ] 桌面浏览器不再渲染 280pt drawer/ComposerPill 错位布局
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-051: [P2] /wiki 信息架构重整
**Description:** 作为用户，我希望 wiki 首屏是知识网络（live concept/entity + 图谱），原料草稿次级呈现。

**Acceptance Criteria:**
- [ ] 默认展示 live concept/entity + 图谱入口；draft source 收进侧栏"原料"区
- [ ] 切换可查看原料
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

#### US-052: [P2] 空状态引导
**Description:** 作为新用户，我希望在 0 domains/0 backlinks 时被引导，而非看到冷冰冰的 0。

**Acceptance Criteria:**
- [ ] home 在无网络时显示"添加 N 条后我会自动编织出你的第一个知识网络"引导
- [ ] 引导含明确下一步 CTA（添加来源 / 剪藏）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

---

## 5. Functional Requirements

**编译成网（P0）**
- FR-1: compile apply 阶段必须给新建/更新的 page 写入 embedding，并复用 embed_cache。
- FR-2: 每条 memo 必须有用户可见的状态机（queued/running+step/done/failed+reason）与重试入口。
- FR-3: 必须新增 `weave-graph` 管线，基于向量聚类把 source 页综合为 concept/synthesis、抽取 entity、建 link、写 domains。
- FR-4: page 必须有 draft→live 晋升规则；`/wiki` 默认只展示 live。
- FR-5: RAG 检索必须走原生 pgvector HNSW（`<=>`），不得全表扫 + JS cosine。

**对外接入点（P1）**
- FR-6: 必须提供 MCP server，工具集 search_wiki/get_page/list_domains（read）+ add_memo（write），鉴权复用 api_keys+scopes。
- FR-7: 必须提供 key-auth 的 `/api/v1/*` 检索 API，与内部 session-auth API 隔离。
- FR-8: 必须支持出站 webhook，事件源复用 change_log，含验签 secret。

**采集广度（P1）**
- FR-9: settings 必须暴露 email/rss/webhook 源配置（config 加密）。
- FR-10: 必须提供浏览器剪藏（整页 + 选中片段）入口。
- FR-11: connector 必须可声明 default_ingest_mode。

**定制化（P1）**
- FR-12: 编译管线必须接受可选 perspective_prompt。
- FR-13: 必须支持用户创建 grounded 在 wiki 上的可配置 agent（persona + 模型 + 检索范围），与 MCP 共享检索层。
- FR-14: 必须支持全局知识助手 persona，注入 chat 与 compile。

**差异化（P1/P2）**
- FR-15: 知识图谱必须支持时间维度查询（按日期窗口 / 演变），事实失效而非删除。
- FR-16: 必须提供结构性 gap 检测 + LLM 生成的反思提示，落 inbox。

**体验（P2）**
- FR-17: `/today` 必须收敛定位，桌面捕获统一走 `/add`。
- FR-18: `/wiki` 首屏必须以知识网络为主、原料草稿次级。
- FR-19: 无网络时 home 必须有引导式空状态。

---

## 6. Non-Goals (Out of Scope)

- **不做 iOS 端改动**：本 PRD 仅 Web。iOS 作为采集/同步端，仅在接口层被引用（sync_state）。
- **不做全天被动录音/录屏可穿戴**（Limitless 路线）：受众与隐私成本不匹配，且 Limitless 已被收购停售，趋势存疑。
- **不在本期做本地 LLM 推理**：DayPage 当前用云端 LLM（DashScope/Whisper）。"本地优先存储"作为护城河叙事保留，"本地推理"列入 §10 待定，不在本期实现。
- **不做多 LLM provider 抽象作为核心卖点**：研究证伪了"MCP 价值=多 provider 抽象"（Cognee 断言 0-3）；可选模型是体验细节，不是护城河。
- **不做手动 `[[backlink]]` 编辑器**：DayPage 的差异化是自动建图，不与 Obsidian/Logseq 拼手动双链体验。
- **不在本期做 Obsidian/Logseq 双向同步**：列入 §10 备选（markdown 基础好，但非本期核心）。
- **不做通用团队协作/多人共享**：DayPage 是个人系统。

---

## 7. Design Considerations

- **复用现有组件**：`components/ui/*`（Btn/Card/Chip/Drawer/Sparkline）、`WikiGraph.tsx`（图谱）、`rag.ts`（统一检索层，MCP/agent/chat 共用）。
- **MCP 与 agent 共享检索层**：US-010 与 US-031 必须复用同一 `rag.ts`，避免两套召回逻辑。
- **状态机 UI**：复用 memo 卡片，`compile_step` 字段已存在，做成轻量进度条而非新组件。
- **空状态/IA**：参照竞品"dump-and-organize"叙事，引导文案强调"自动编织"，弱化"你需要手动整理"。
- **护城河叙事一致性**：所有面向用户的文案围绕"你独有的、积累的个人知识 = 你的护城河"（对标 Recall "Your knowledge is your edge"），而非"又一个 AI 助手"。

---

## 8. Technical Considerations

- **冷启动死锁修复顺序**：US-001（page embedding）必须先于 US-003（weave-graph），否则聚类无 embedding 可用。
- **pgvector**：先核实 `0006_pgvector_hnsw.sql` 是否真正应用——当前 `rag.ts` 注释自承 embedding 疑似仍以 text 存（US-005 前置）。
- **MCP 鉴权**：复用 `api_keys`（已有 `scopes` 字段，见 `web/src/app/api/keys/route.ts`），无需新鉴权体系。
- **ingest 统一抽象**：所有 connector 落 `ingest_sources` + 统一 `memo/created` 事件，**不为每个源写一套管线**（fetch-rss 已是范式）。
- **时序 KG**：参考 Graphiti/Zep（arxiv 2501.13956）的 validity-window 模型；DayPage 数据天然 day-stamped（`vault/raw/YYYY-MM-DD.md`），实现成本低于通用方案。
- **dev 可靠性**：`web/CLAUDE.md:3` 记录的 `sendEvent` no-op 是 US-002 的直接背景；prod 下 Inngest 抖动同样会静默丢，状态机是通用解。
- **编译可观测**：`prompt_log` 表已记录 token 用量，可与状态机联动展示成本。

---

## 9. Success Metrics

- **M1（G1）**：跑通一批真实 memo 后 `domains > 0`、`backlinks > 0`、≥1 个 concept/synthesis live 页。
- **M2（G2）**：Compile Queue 永久 QUEUED memo 数 = 0；失败 memo 100% 有可见原因 + 重试入口。
- **M3（G3）**：在 Claude Desktop 配置 DayPage MCP，能检索到真实 wiki 内容并链回来源。
- **M4（G4）**：email/rss/webhook 至少各跑通一条入站；浏览器剪藏成功产生 memo。
- **M5（G5）**：用户能创建 ≥1 个 grounded 在自己 wiki 上的 agent 并获得引用真实内容的回答。
- **M6（G6）**：能查询某 entity 跨月演变；inbox 出现 ≥1 条 gap 反思提示。
- **M7（G7）**：桌面浏览器不再出现 `/today` 错位布局；新用户空状态有明确引导。

---

## 10. Open Questions

- **本地推理护城河的真实性**：DayPage 当前云端 LLM；iOS 上本地推理（Reor/Khoj 路线）是否可行、是否值得？（研究 openQuestion）
- **个人 MCP server 的真实需求信号**：研究证据显示仍是"early adopters experimenting"，可能尚属早期——投入前如何验证真实需求？
- **journaling vs PKM 定位**：DayPage 的 day-centric 定位更接近 AI journaling 群组（Day One AI/Rosebud/Stoic）还是 PKM 群组？这影响叙事与受众——这批竞品未进入验证集（研究覆盖不足）。
- **商业模式**：研究surface了功能但缺各产品定价/用量上限数据；DayPage 的 monetization（订阅档/采集上限/模型用量）待定。
- **Obsidian/Logseq 双向同步**是否纳入后续版本？markdown 基础好、触达大量"第二大脑"用户，但非本期核心。

---

## 11. 竞品研究引用（经对抗验证，2025-2026 快照）

> 来源：deep-research workflow，106 agent，24/25 条断言通过 3 票对抗验证（need 2/3 refute to kill）。以下均 confidence=high。

1. **个人数据即 MCP 接入点（5 条 3-0 综合）**：Readwise Reader（2025-06 MCP）、Mem（2026-03 Claude Connector）、Limitless（api.limitless.ai/mcp）、Cognee、Graphiti/Zep 均已出货 MCP 个人数据访问。→ DayPage 单点 ROI 最高方向。
   - readwise.io/reader/update-june2025 · docs.readwise.io/tools/mcp · get.mem.ai · limitless.ai/developers · cognee.ai/blog/...introducing-cognee-mcp · getzep.com/product/knowledge-graph-mcp · github.com/getzep/graphiti
2. **dump-and-organize 主流 UX（3 条 3-0）**：Mem/Recall/Limitless。DayPage 已有循环但采集广度弱。
   - get.mem.ai · recall.it · limitless.ai/new
3. **向量相似度自动建图（4 条 3-0）**：Reor/Recall/Cognee/InfraNodus。
   - github.com/reorproject/reor · recall.it · cognee.ai · infranodus.com/use-case/visualize-knowledge-graphs-pkm
4. **时序知识图谱（3-0）**：Graphiti/Zep（arxiv 2501.13956），validity window、失效而非删除。DayPage day-stamped 天然契合。
   - getzep.com/product/knowledge-graph-mcp · github.com/getzep/graphiti · arxiv.org/abs/2501.13956
5. **分析型图谱（2 条 3-0）**：InfraNodus 社区检测 + 结构性 gap 分析 + AI 生成桥接问题。
   - infranodus.com/use-case/visualize-knowledge-graphs-pkm · support.noduslabs.com
6. **本地优先=护城河（3 条 3-0）**：Reor（Ollama/LanceDB 全本地）、Khoj（开源自托管）。DayPage YAML+Markdown vault 已具基础。
   - github.com/reorproject/reor · github.com/khoj-ai/khoj · docs.khoj.dev
7. **"你的知识=你的护城河"叙事（3-0）**：Recall "AI gave everyone the same brain / Your knowledge is your edge"。
   - recall.it · Chrome Web Store "Recall | Your Knowledge is Your Edge"
8. **可配置 per-domain agent（2 条 3-0）**：Khoj（自定义知识/persona/模型/工具的 agent）、Recall（可切换模型）。
   - github.com/khoj-ai/khoj · recall.it

**被证伪（0-3，勿采纳）**：Cognee 的核心差异化**不是**"多 LLM provider 统一接口抽象"。→ DayPage 的 MCP 价值主张不要建模成多 provider 抽象。

**重要 caveat**：多数一手来源是厂商营销页（描述"已出货功能/定位"而非独立审计性能）；Zep "sub-second/百万图" 为厂商自述未审计；Limitless 2025-12-05 被 Meta 收购并停售 Pendant，长期产品轨迹不确定；Tana/Capacities/Heptabase/Saner/Reflect/Personal.ai/MyMind/Rosebud/Mindsera/Scrintal/Obsidian Smart Connections **未进入验证集**——"此处缺席"= 未验证，非不相关（纯 PKM 与 AI-journaling 邻域覆盖不足）。

---

## 12. 实施顺序（建议）

```
P0  编译成网（先做，否则一切空中楼阁）
 └ US-001 page embedding → US-002 状态机 → US-003 weave-graph → US-004 draft→live → US-005 HNSW
P1-接入点（ROI 最高、直接兑现愿景④）
 └ US-010 MCP只读 → US-011 add_memo → US-012 v1 API → US-013 webhook
P1-采集广度（代码就绪，低成本兑现愿景①）
 └ US-020 connector UI → US-021 剪藏 → US-022 default_mode
P1-定制化（兑现愿景③）
 └ US-030 编译视角 → US-031 可配置 agent → US-032 persona
P1/P2-护城河
 └ US-040 时序KG → US-041 分析型图谱gap提示
P2  体验
 └ US-050 /today收敛 → US-051 wiki IA → US-052 空状态
```

按 CLAUDE.md 流程：每项设计先讨论 → 开 GitHub issue → 分支实现 → 测试 → PR 关联 issue。
建议 P0 五个 story 各拆一个 issue，P1/P2 按节拆。
