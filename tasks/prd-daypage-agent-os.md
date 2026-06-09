# PRD: DayPage Agent OS — 主动演化引擎 + 生产级编排 + Agent 执行接入

> 状态：Draft · 2026-06-09
> 范围：Web 后端服务 + Web 前端 + Agent 执行层（终端/浏览器）
> 前置：建立在现有 Inngest / Postgres(pgvector) / 审计(change_log) / 五环采集(ingest_sources) 之上
> 下游：本 PRD 完成后转 Ralph `prd.json` 驱动自主实现

---

## 1. Introduction / Overview

DayPage 当前是一个**被动编译型**系统：用户/三方源把碎片信息写入 `memos`，
Inngest 工作流（`compile-memo` → `weave-graph` → `daily-page`）把碎片编译成
`pages` 知识图。系统只在"有新数据"时被动反应，产物止于"一张可检索的知识图"。

本 PRD 把它升级为**主动演化型**系统 —— 一个「个人 context 操作系统」：

> 系统**持续主动**地整理碎片、在**任务树**上推演、按**用户设定的时机**（如每小时）
> 把"任务建议列表"推送到 Telegram；用户点选后，建议被封装成 **WorkOrder**，
> 由**分级执行层**真正执行 —— 轻活（调 API / 抓网页）在 DayPage 自建沙箱里跑，
> 重活（改代码 / 长任务）外包给 Claude Code / OpenClaw / Ralph，产物**回流**进任务树
> 形成飞轮。

**一句话定位**：DayPage 是大脑与编排器（Gateway + Evolver），Claude Code / OpenClaw / Ralph
是被它调度的执行后端；DayPage 自己只执行"无副作用 + 轻量"的活。

### 北极星用户故事（MVP 切片）

> 系统持续调度我的 Claude Code 项目 session，结合我的信息推理，每小时把一批
> "任务建议列表"推送到 Telegram，我点选我要做的，选中的就被真正派去执行。

### 现状基线（已具备，本 PRD 复用而非重建）

| 能力 | 现状 | 复用方式 |
|---|---|---|
| Durable Queue / 工作流 | ✅ Inngest（8 个 function） | Gateway/Evolver/Executor 作为新 Inngest functions |
| State Store | ✅ Postgres + pgvector(HNSW) + Drizzle | 任务树复用 `pages`/`page_links`，新增少量表 |
| 审计 | ✅ `change_log`(before/after/performed_by/reason) | Executor 每次派发/执行写审计 |
| token 预算 | ✅ `prompt_log` | 预算闸门读它做熔断 |
| 五环采集 | ✅ `ingest_sources`(telegram/email/rss/webhook/**api_claude**) | 出站通道复用同一抽象 |
| 限速 | ✅ Upstash Ratelimit | Executor 派发限速复用 |
| 时序知识图 | ✅ `page_links.valid_from/valid_to` | 演化"as-of"查询直接可用 |
| CC 单向写入 | ✅ `scripts/claude-code-hook.sh`（CC→DayPage） | 本 PRD 补**反向**：DayPage→CC 调度 |
| 聊天 agent | ✅ `agents` 表（wiki-grounded chat） | 与本 PRD 的"执行 agent"是两类，并存 |

---

## 2. Goals

1. **主动调度**：引入 Gateway + Scheduler，系统按用户设定时机（每小时/每日/事件）
   主动唤醒，不再只被动反应。
2. **任务演化**：Evolver 在任务树上跑 agentic loop，从碎片推理出"任务建议"（带理由、
   关联、预估、建议派给谁），支持长枝 / 剪枝 / merge。
3. **定时推送 + 用户选择**：把任务建议按时机推送到 Telegram（出站通道可扩展），
   用户在 IM 内点选 = 人工闸门，选中即派发。
4. **分级执行**：Executor 区分轻活（自建沙箱：终端/headless 浏览器/API）与重活
   （外包 CC/OpenClaw/Ralph），用统一 WorkOrder 契约 + 适配器派发。
5. **生产级**：幂等、重试、死信、token 预算熔断、CC session 生命周期管理、
   全链路可观测与审计 —— 系统随时可被杀死且可恢复。
6. **闭环飞轮**：执行产物回流为新 RawEvent，使任务树"每天往前长一格"。

---

## 3. User Stories

> Wave 划分：W0 地基 → W1 北极星闭环 → W2 演化引擎 → W3 自建沙箱执行 → W4 外包执行 → W5 生产硬化。
> 每个 Wave 可独立交付价值；北极星闭环（W0+W1）最小可用。

### Wave 0 — Gateway 地基与数据模型

#### US-001：任务树数据模型
新增表 `trees`（长期目标/repo）与 `tree_nodes`（commit/branch/leaf 节点），
节点引用 `pages`（知识图作记忆底座）。字段含 `kind`(goal|branch|leaf)、
`status`(growing|mature|merged|pruned)、`parent_id`、`heat`(热度)、`evidence_memo_ids`。
**复用** `page_links` 表达节点间关系，**复用** `change_log` 记录每次树变更。

#### US-002：Gateway 核心（调度注册表）
新增 `gateway_jobs` 表（job 状态机：queued|running|gated|done|failed|dead）含
`idempotency_key`、`tree_id`、`type`、`payload`、`attempts`、`gate_state`。
Gateway 是一个 Inngest function 集合 + 一层薄编排，持有所有 loop 的生命周期。

#### US-003：Scheduler（定时触发）
基于 Inngest cron（或 pg_cron）实现"每小时/每日/每周"触发 → enqueue 对应 job。
触发策略可由用户在设置中配置（见 US-013）。

#### US-004：Policy / Gate Engine（闸门·预算·限速）
统一闸门引擎：读 `prompt_log` 做 token 预算与熔断；分级 `gate`：
`auto`(无副作用直接放行) / `approve-first`(派发前审批) / `approve-result`(产物审批)。
连续失败触发 circuit breaker 暂停该后端。

### Wave 1 — 北极星闭环（每小时推 TG 建议 → 选择 → 执行）

#### US-005：CC session 只读调度（读进展）
反向 CC 集成第一步：DayPage 能读取指定 CC 项目 session 的进展摘要，作为 Evolver
推理输入。形态见 Open Questions Q-CC（本地读 transcript / 远端 API）。
封装为 `connectors/claude-code` 的 `readProgress()`。

#### US-006：Suggester（任务建议推理器）
一个 Inngest function：输入=任务树现状 + 最近 CC 进展 + 新 RawEvent，
输出=结构化 `TaskSuggestion[]`（title / rationale / linked_node_id / estimate /
suggested_target）。过 Policy（建议无副作用→放行）。写入 `task_suggestions` 表。

#### US-007：出站通道抽象 + Telegram 推送
新增 `notify` job 类型 + `connectors/outbound` 抽象（今天 TG，可扩展）。
Telegram adapter 把 `TaskSuggestion[]` 渲染成带 inline button 的消息推送。
**复用**现有 telegram webhook 基建（`/api/ingest/telegram`）。

#### US-008：Telegram 回调 → 闸门通过 → 派发
扩展 telegram webhook 处理 callback_query：用户点选 = 闸门通过 →
enqueue `dispatch` job。需幂等（防重复点击重复派发）。

#### US-009：Executor 最小派发（派给 CC）
Executor function：把选中的 `TaskSuggestion` 封装成 `WorkOrder`，经 Policy
（有副作用→检查预算）后，通过 `connectors/claude-code` 的 `dispatch()` 派给真实
CC session 执行。写 `change_log` 审计。

#### US-010：产物回流闭环
CC 执行产物 → 归一化成 RawEvent（`source: claude-code, channel: agent-return`）→
回 `/api/ingest` → 下一轮 Compiler commit 回对应 `tree_node` → 节点状态升级。

### Wave 2 — 演化引擎（Compiler 升级 + Evolver loop）

#### US-011：Compiler 升级（commit 进树）
现有 `compile-memo` 升级：除写 `pages` 外，判断每条 memo"推进了哪棵树"，
在对应 `tree_node` 下生成 commit、更新 `heat`、merge 证据。每日产出"树的 diff"。

#### US-012：Evolver loop（长枝/剪枝/merge）
Evolver function：在热度触发的树上跑 observe→plan→act。act 仅在树内（无副作用）：
长出新分支、标注枯枝建议剪枝、merge 殊途同归的分支。剪枝/派发停在闸门等用户。
loop 的"连续性"由 state + 重新 enqueue 保证，不靠长跑进程。

#### US-013：演化时机设置（Web 前端）
设置页新增"演化与推送时机"：每小时/每日时刻/事件驱动开关、推送通道选择、
每条树的预算上限。写 `user_settings`。

### Wave 3 — DayPage 自建沙箱执行（轻活自跑）

#### US-014：沙箱执行器（容器/隔离进程）
DayPage 后端起隔离沙箱（容器 / 受限子进程），供 agent 跑"轻活"。
**安全模型**：无网络默认拒绝、白名单出网、只读挂载、CPU/内存/时长配额、无密钥注入。

#### US-015：终端工具（沙箱内）
沙箱内提供受限 shell：允许的命令白名单（git read / 构建 / 测试 / 脚本），
禁止破坏性命令（rm -rf / 写外部 / 凭据访问）。每条命令过 Policy + 审计。

#### US-016：headless 浏览器工具（沙箱内）
沙箱内 Playwright headless：抓网页 / 填表读取 / 截图。默认只读导航，
表单提交等"副作用"动作需 `approve-first` 闸门。URL 白名单 + 反钓鱼检查。

#### US-017：轻活 WorkOrder 路由
Executor 判定 WorkOrder 副作用大小：无副作用 + 轻量 → 路由到自建沙箱；
有副作用 / 重量 → 路由到外包（W4）。判定规则写入 Policy。

### Wave 4 — 外包执行后端（重活外包）

#### US-018：WorkOrder 统一契约 + 适配器框架
定义 `WorkOrder { intent, context, output, gate, callback, budget }`。
适配器接口 `dispatch(wo) / poll(id) / collect(id)`。每个后端一个适配器。

#### US-019：Claude Code 适配器（双向完整）
完善 CC 适配器：远程调度一个 CC session 执行 WorkOrder（注入 context + 工作目录），
轮询进展，回收产物。含 session 生命周期管理（注册表/心跳/超时/重连）。

#### US-020：OpenClaw 适配器
接入 OpenClaw 的 per-session loop API 作为执行后端之一（被 DayPage 调用）。

#### US-021：Ralph 适配器
把成熟 `tree_node` 翻译成 Ralph `prd.json` 派发；Ralph 跑完产物回流。

### Wave 5 — 生产硬化

#### US-022：幂等与重试
所有 job 幂等键去重；失败指数退避重试；超限进死信队列 + 告警。

#### US-023：CC session 注册表与生命周期
`agent_sessions` 表：哪些 session 活着 / 属于哪个项目 / 上次心跳 / token 用量 /
状态。超时回收、断线重连、孤儿清理。

#### US-024：预算熔断与成本看板
按 user/tree/job 设 token 预算；后端连续失败熔断；`/insights` 新增"Agent 成本"维度
（读 `prompt_log` + `change_log`）。

#### US-025：可观测性
每个 job 状态 / 每次 LLM 调用 token·延迟·成本 / 每次派发审计可查。
**复用** Sentry（已集成）+ `api_logs`。

#### US-026：Web 前端 — Agent OS 工作台
`/agents`（或新 `/orbit`）升级为编排工作台：任务树可视化（复用 d3 graph）、
本周 diff、建议列表与闸门审批、执行流水与产物、成本看板。
iOS 端保持采集主场，不做演化 UI（沿用分工）。

---

## 4. Functional Requirements

### 数据模型（新增表）
- FR-1 `trees(id, user_id, title, status, created_at)`
- FR-2 `tree_nodes(id, tree_id, parent_id, kind, status, title, heat, evidence_memo_ids jsonb, page_id?, created_at, updated_at)`
- FR-3 `gateway_jobs(id, user_id, type, tree_id?, payload jsonb, status, idempotency_key unique, gate_state, attempts, last_error, created_at, updated_at)`
- FR-4 `task_suggestions(id, user_id, tree_node_id?, title, rationale, estimate, suggested_target, status(open|selected|dispatched|dismissed), payload jsonb, created_at)`
- FR-5 `agent_sessions(id, user_id, backend(claude-code|openclaw|ralph|sandbox), external_ref, project, status, last_heartbeat_at, tokens_used, created_at)`
- FR-6 `work_orders(id, user_id, suggestion_id?, intent, context jsonb, output_spec, gate, callback jsonb, budget_tokens, status, result_ref, created_at)`
- 复用：`pages` / `page_links`(时序) / `change_log`(审计) / `prompt_log`(预算) / `ingest_sources`(入站) / `memos`(RawEvent)

### 编排（Inngest functions，新增）
- FR-7 `scheduler.tick`（cron）→ enqueue `evolve` / `suggest` jobs
- FR-8 `compiler.commit`（升级 compile-memo）→ 碎片 commit 进树
- FR-9 `evolver.step`（事件/热度触发）→ 树内 observe-plan-act
- FR-10 `suggester.run` → 产 `TaskSuggestion[]` → notify
- FR-11 `notify.send`（出站通道）→ Telegram inline buttons
- FR-12 `executor.dispatch` → WorkOrder → 适配器（沙箱 or 外包）
- FR-13 `collector.collect` → 回收产物 → 回流 ingest

### 闸门（Policy Engine）
- FR-14 三级 gate：`auto` / `approve-first` / `approve-result`
- FR-15 token 预算检查（读 prompt_log），超限拒绝并告警
- FR-16 circuit breaker：后端连续 N 次失败 → 暂停派发
- FR-17 派发限速（复用 Upstash Ratelimit）

### 执行（分级）
- FR-18 副作用判定规则：树内变更 / 生成文本 = auto；调外部只读 = auto；
  外部写 / 改代码 / 发消息 = approve-first
- FR-19 自建沙箱：网络白名单、只读挂载、配额、无密钥、命令白名单
- FR-20 外包适配器：dispatch/poll/collect 统一接口 + session 生命周期

---

## 5. Non-Goals (Out of Scope)

- ❌ 无感知监听群聊他人对话（合规红线，永不做）；IM 仅 `from_me` + 转发/Saved
- ❌ iOS 端演化/编排 UI（iOS 仅采集，沿用分工）
- ❌ 自建 LLM 推理基础设施（复用 DashScope/现有 CompilationService）
- ❌ 重型消息队列（Kafka 等）首期不上，Inngest + Postgres 足够
- ❌ 多用户协作 / 树共享（远期）
- ❌ 沙箱内任意联网与任意命令（永久受限）

---

## 6. Design Considerations

- **任务树心智 = Git**：commit（推进）/ branch（探索路径）/ merge（殊途同归）/
  prune（剪枝）/ checkout（成熟出口）。UI 用此心智，不是看板。
- **session 边界 = per-tree**：每棵目标树一个独立 loop 实例，状态隔离，
  与 Git repo 心智同构。Gateway 调度"今天给哪几棵树分配预算"。
- **loop ≠ 长跑进程**：每次"跑一格" = 取一个 job → 读 state → 推理 → 写 state →
  可能再 enqueue。连续性由 state + 重入队保证，进程随时可杀可恢复（生产级关键）。
- **DayPage = OpenClaw 的上层**：OpenClaw 是被调用的执行后端之一。
- **前端复用**：任务树可视化复用现有 d3-force graph；建议列表复用 inbox 交互模式。

---

## 7. Technical Considerations

- **务实选型，单体起步**：分层是逻辑上的；物理上先单体 Next.js + Inngest + Postgres，
  因从一开始就是"队列 + 无状态 function + 唯一 state 源"，扛不住时按图拆进程零重构。
- **队列**：Inngest 已是 durable queue/工作流引擎，直接用，不引入新 MQ。
- **沙箱**：优先评估轻量隔离（容器 / firecracker / 受限子进程）；首期可先做
  "受限子进程 + 命令白名单"，容器化作为硬化项。
- **CC 调度形态**：见 Open Questions，本地读 transcript（MVP 快）vs 远端容器（可扩展）。
- **安全**：沙箱无凭据注入；外部写操作强闸门；URL/命令白名单；全程审计。
- **dev 依赖**：本地必须同跑 `npm run dev` + `npm run dev:inngest`（见 web/CLAUDE.md），
  否则 job 静默 no-op。

---

## 8. Success Metrics

- M1：每小时定时推送在 Telegram 稳定到达，inline 选择→派发端到端 < 10s
- M2：用户从"路上嘟囔一句"到"收到相关任务建议"的飞轮在 24h 内闭合
- M3：自建沙箱执行"轻活"成功率 ≥ 95%，无一次越界（联网/破坏性命令）
- M4：token 预算熔断有效：无单 user/tree 失控烧钱事件
- M5：系统重启/崩溃后，所有 in-flight job 可从 state 恢复，零丢失零重复
- M6：每次派发可在成本看板追溯（派了什么/给谁/花多少 token）

---

## 9. Open Questions

- **Q-CC**：CC 远程调度形态？(a) CC 跑本地/服务器 + 读 `~/.claude/projects/` transcript；
  (b) CC 跑远端容器 + API/SSH 调度。MVP 倾向 (a)，W4 演进 (b)。
- **Q-Sandbox**：自建沙箱首期用受限子进程还是直接容器化？取决于部署环境。
- **Q-Suggest 频率**：每小时是否对单用户过频？是否按"树有变化才推"做事件抑制。
- **Q-Tree 根**：任务树的根由用户手动开，还是 AI 从数据自动发现意图后立树？（影响 US-001/011）
- **Q-OpenClaw**：OpenClaw 实际接入 API 形态待调研后定（US-020）。

---

## 10. Wave 依赖与 Ralph 拆分指引

```
W0 (US-001..004)  ── 地基，无依赖
  └─▶ W1 (US-005..010)  北极星闭环，依赖 W0
        └─▶ W2 (US-011..013)  演化引擎，依赖 W1
              ├─▶ W3 (US-014..017)  自建沙箱，依赖 W2 的 Executor
              └─▶ W4 (US-018..021)  外包后端，依赖 W2 的 WorkOrder
                    └─▶ W5 (US-022..026)  硬化，依赖 W3/W4
```

转 Ralph 时：每个 US 作为一个可独立验证的 task；W0/W1 优先级最高（北极星）；
W3 沙箱类 task 必须带"安全验证"验收项（联网拒绝/破坏性命令拒绝/配额生效）。
