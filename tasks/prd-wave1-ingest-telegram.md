# PRD: Wave 1 — 集成地基（API Key 鉴权 · 通用 Ingest · Telegram）

> 关联蓝图：`docs/PRD-vNext.md` 决策二 + Epic A（A1/A2）。本 PRD 为可执行规格。
> Web 在 `web/`。所有外部源最终都产出一条 memo，复用现有 `memo/created` → Inngest 编译管道。

## 1. Introduction / Overview

DayPage 目前没有任何机器对机器鉴权（28 个端点只认 NextAuth session cookie），因此外部信息源无法写入。本 Wave 建立外部集成的地基：
1. **Personal API Key（PAT）**机制——让 bot/hook/webhook 能鉴权写入。
2. **统一 Ingest Gateway**（`POST /api/ingest`）——所有外部源的标准摄入口，带幂等去重。
3. **Telegram 集成**——第一个真实外部源，用户转发/发送消息即成 memo。

## 2. Goals

- 用户可在 Settings 生成、命名、撤销 API key（明文只显示一次）。
- 任何外部系统可用 `Authorization: Bearer dp_xxx` 调 `/api/ingest` 创建 memo。
- 用户私有 Telegram bot：转发文本/链接/语音/图片 → 自动成对应 type 的 memo → 编译。
- 同一外部条目重复推送不产生重复 memo（幂等）。

## 3. User Stories

### US-101: api_keys 表与迁移
**Description:** As a developer, I need to store hashed API keys so external sources can authenticate.

**Acceptance Criteria:**
- [ ] 新增 `api_keys` 表：`id, user_id(FK CASCADE), name, key_hash, prefix, scopes(jsonb), last_used_at, created_at, revoked_at`
- [ ] `key_hash` 存 sha256，明文不入库；`prefix` 存前 8 位用于展示
- [ ] 生成并运行 drizzle 迁移成功
- [ ] Typecheck passes

### US-102: API key 鉴权中间件
**Description:** As a developer, I need a reusable way to authenticate Bearer-token requests so ingest endpoints can identify the user.

**Acceptance Criteria:**
- [ ] 新增 helper：解析 `Authorization: Bearer dp_xxx`，sha256 后比对 `api_keys.key_hash`
- [ ] 解析出 user_id + scopes 注入请求上下文；无效/已撤销 key 返回 401
- [ ] 命中后更新 `last_used_at`
- [ ] 复用现有 Upstash 限流（`web/src/lib/ratelimit.ts`），按 key 维度限流
- [ ] Typecheck passes

### US-103: API key 管理端点
**Description:** As a user, I want to create and revoke API keys via API.

**Acceptance Criteria:**
- [ ] `POST /api/keys`（session 鉴权）：创建 key，**响应中明文仅此一次返回**，库里只存 hash
- [ ] `GET /api/keys`：列出当前用户的 key（只返回 prefix/name/last_used/created，不返回明文）
- [ ] `DELETE /api/keys/[id]`：撤销（置 revoked_at）
- [ ] 所有端点强制 user 隔离
- [ ] Typecheck passes

### US-104: Settings 页 API Key 管理 UI
**Description:** As a user, I want to manage my API keys in settings so I can connect external tools.

**Acceptance Criteria:**
- [ ] Settings 新增 "API Keys" 区块
- [ ] 生成按钮 → 弹窗显示一次性明文 key（含复制按钮 + "只显示一次"警告）
- [ ] 列表显示已有 key（name / prefix / last used），每行有撤销按钮（带确认）
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-105: 统一 Ingest 端点
**Description:** As an external system, I want to POST content to DayPage so it becomes a memo.

**Acceptance Criteria:**
- [ ] `POST /api/ingest`(PAT 鉴权，scope `memo:write`)
- [ ] 接受 NormalizedInput 子集，最少 `{ body }`；zod 校验、大小限制、HTML 清洗
- [ ] 落 memo 时 `origin='api'`，记录 `source_channel`
- [ ] 创建后发 `memo/created` 事件触发编译
- [ ] 无效 key 返回 401；超限返回 429
- [ ] Typecheck passes

### US-106: memo 幂等去重字段
**Description:** As a developer, I need memos to be idempotent per external source so retries don't duplicate.

**Acceptance Criteria:**
- [ ] 新增 `memos.source_channel`(text, nullable)、`memos.external_id`(text, nullable)
- [ ] 建唯一索引 `(user_id, source_channel, external_id)`（external_id 非空时）
- [ ] `/api/ingest` 带 `external_id` 时，重复推送返回已存在 memo（不新建）
- [ ] 生成并运行迁移成功
- [ ] Typecheck passes

### US-107: ingest_sources 表与源配置
**Description:** As a developer, I need to store external source bindings so each user's Telegram/RSS/email connections persist.

**Acceptance Criteria:**
- [ ] 新增 `ingest_sources` 表：`id, user_id(FK CASCADE), channel, config(jsonb, 敏感值加密), enabled, created_at`
- [ ] `GET/POST/PATCH/DELETE /api/sources`（session 鉴权，user 隔离）
- [ ] config 中的密钥（如 telegram token）加密存储，不明文落库
- [ ] 生成并运行迁移成功
- [ ] Typecheck passes

### US-108: Telegram webhook 端点 + Adapter
**Description:** As a user, I want messages I send to my DayPage bot to become memos.

**Acceptance Criteria:**
- [ ] `POST /api/ingest/telegram`，用 Telegram `secret_token` 校验来源（拒绝无效）
- [ ] Adapter 归一化 Telegram update：纯文本→text memo；含 URL→url memo（填 source_url）；语音→`getFile` 下载→audio attachment→走 Whisper 转写；图片→photo memo（含 caption）
- [ ] 通过 `telegram_chat_id` 在 `ingest_sources` 中查到绑定的 user_id；未绑定的 chat_id 被拒
- [ ] 复用 `/api/ingest` 内部逻辑落 memo（origin=api, source_channel=telegram, external_id=telegram message id 做幂等）
- [ ] 不引入重型 telegram SDK，直接用 Bot API + fetch
- [ ] Typecheck passes

### US-109: Telegram 绑定流程
**Description:** As a user, I want to connect my Telegram account to DayPage securely.

**Acceptance Criteria:**
- [ ] Settings "连接 Telegram"：生成一次性绑定码，提示用户发 `/start <code>` 给 bot
- [ ] bot 收到 `/start <code>` 后，把 telegram_chat_id 与 user_id 绑定写入 `ingest_sources.config`
- [ ] 绑定成功后 Settings 显示已连接状态，可一键解绑（删除 ingest_source）
- [ ] 绑定码有过期时间，用过即失效
- [ ] Typecheck/lint passes
- [ ] Verify in browser using dev-browser skill

### US-110: 端到端验证 Telegram → memo → 编译
**Description:** As a user, I want my forwarded Telegram content to be compiled into my knowledge base.

**Acceptance Criteria:**
- [ ] 转发文本/链接/语音/图片各能正确落对应 type 的 memo
- [ ] memo 进入编译管道并最终 compile_status=done
- [ ] 在 `/add` 队列或 memo 详情页能看到该 memo（origin=telegram）
- [ ] 同一 message 重复推送不产生第二条 memo
- [ ] Verify end-to-end with a real test bot

## 4. Functional Requirements

- FR-1: 系统提供 PAT 鉴权，密钥只存 hash、可撤销、按 key 限流。
- FR-2: `POST /api/ingest` 是所有外部源的统一摄入口，落 memo + 触发编译。
- FR-3: memo 支持 `(user_id, source_channel, external_id)` 幂等去重。
- FR-4: Telegram bot 支持文本/链接/语音/图片，经绑定的 chat_id 鉴权。
- FR-5: 外部源配置存 `ingest_sources`，敏感密钥加密。
- FR-6: 用户可在 Settings 管理 API key 与 Telegram 绑定。

## 5. Non-Goals (Out of Scope)

- 不在本 Wave 做 Claude Code hooks / MCP / RSS / Email（属 Wave 2/4）。
- 不做 Telegram bot 的对话式交互（仅单向摄入，不做问答）。
- 不做多 bot / 团队共享（单人单 bot）。
- 不实现 OAuth 式第三方授权（仅 PAT + 绑定码）。

## 6. Design Considerations

- Settings UI 复用现有组件（Btn/Card/Chip）。
- API key 明文展示弹窗需明确"只显示一次"的强提示。

## 7. Technical Considerations

- NormalizedInput 契约见 `docs/PRD-vNext.md §5.1`。
- Telegram 语音需先 `getFile` 拿 file_path 再下载，再走现有 Whisper transcribe（LLM 层已支持）。
- secret_token 通过 Telegram `setWebhook` 的 `secret_token` 参数设置并在 webhook header 校验。
- 加密：config 敏感字段用对称加密（密钥来自 env），不明文入库。

## 8. Success Metrics

- 用户能在 5 分钟内完成"生成 key → 连接 Telegram → 转发一条消息 → 看到它被编译"。
- 重复推送 0 重复 memo。
- 外部写入全部带 `origin=api` + `source_channel`，可被 Wave 3 统计区分。

## 9. Open Questions

- API key 是否需要细粒度 scope（如只读/只写/特定源），还是初期只有 `memo:write`？
- Telegram 语音转写成本：是否对超长语音设上限或降级？
- ingest_sources.config 的加密密钥轮换策略？
- 是否需要"ingest 审计日志"（谁、何时、从哪个 key 写入），还是复用 change_log？
