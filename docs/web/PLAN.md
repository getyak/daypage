# DayPage Web (Codex) — 完整架构与实施方案

> 状态：**已 approved，进入实施** · 作者：Claude · 日期：2026-05-10
> 设计来源：Anthropic Claude Design 导出包 `daypage-system/` (Codex 原型)

## 🔒 已锁定决策（2026-05-10）

| 维度 | 决策 |
|---|---|
| 域名 | `app.daypage.io` 暂定（不实际购买/解析） |
| 数据库 | Supabase（PostgreSQL 16 + pgvector） |
| Supabase 部署 | **本地 Docker + supabase-cli**（开发） → 后续上 Supabase Cloud（生产） |
| 文件存储 | **Supabase Storage**（替代 R2/S3） |
| 认证 | **Auth.js v5 beta**（next-auth@5.0.0-beta.31）+ Apple Sign-In + Email magic link |
| 租户 | 单租户（schema 仍带 `user_id` 字段，便于后续扩展） |
| 离线 | Web 端做 PWA + Service Worker 离线缓存 |
| iOS 改造 | 同意把 iOS AI 调用迁到后端代理 |
| 首发模式 | 直接公开（不走 preview 期） |

## 📦 锁定版本（2026-05-10 npm latest）

| 包 | 版本 |
|---|---|
| next | **16.2.6** |
| react / react-dom | **19.2.6** |
| typescript | **5.9.x**（npm latest 6.0.3 是 nightly，用 5.9 LTS） |
| tailwindcss | **4.3.0** |
| @supabase/supabase-js | **2.105.4** |
| @supabase/ssr | **0.10.3** |
| next-auth | **5.0.0-beta.31** |
| drizzle-orm | **0.45.2** |
| @tanstack/react-query | **5.100.9** |
| @trpc/server / client | **11.17.0** |
| zod | **4.4.3** |
| lucide-react | **1.14.0** |
| react-markdown | **10.1.0** |
| inngest | **3.x**（compile worker） |

**注意 2026 新世代变更**：
- Next 16 默认 Turbopack（dev + build），不需要再开 `--turbo`
- React 19 全面 Server Components / Server Actions
- Tailwind 4 新 CSS-first 配置（`@theme` 替代 `tailwind.config.ts`）
- Auth.js v5 用 `auth()` helper 替代 `getServerSession()`

---

## 0. 一句话总览

把 DayPage 的「**raw capture → AI compile → wiki/graph**」从 iOS 单机扩展为「**iOS + Web 双端，后端为唯一数据源**」的生产级知识系统。Web 端按 Codex 原型 1:1 复刻设计语言（warm-archival 美学），但**功能必须真实、无硬编码**——所有 API 真接 PostgreSQL，所有 AI 调用真走 DashScope。

---

## 1. 设计稿（Codex 原型）的功能盘点

读完 `Codex.html` + 9 个 jsx + 1172 行 CSS 后的功能矩阵：

| 视图 | 核心功能 | 数据依赖 |
|---|---|---|
| **Sidebar** | 5 个固定项（Home / Add / Chat / Wiki / Inbox）+ 动态 Domains 列表 + Inbox 数字徽标 + 用户信息区 | `domains[]` + `inbox unread count` + `user` |
| **Home** | "What the system noticed"（AI 主动观察卡片，含动作按钮）、Recent activity、Domains at a glance（含 sparkline）、统计数（sources/pages/domains/backlinks） | `observations[]` + `recent_activity[]` + `domains[]` + 全局计数 |
| **Add** | 统一输入（URL / 文本 / 文件 / 语音自动识别）、实时 compile queue（带进度条 + FULL/LIGHT 模式切换）、Recently compiled 列表 | `ingestion_queue[]` + `recent_compiled[]`，需要后台 worker 跑实际编译 |
| **Chat** | 对话线程（用户问 + AI 答带数字引用 `{1}`）、右栏 References Cards（点引用高亮）、Suggested follow-ups、Save as synthesis page | `chat_threads / messages / citations`，AI 流式输出 |
| **Wiki** | 左栏分组导航（Concepts / Sources / Entities / Synthesis）+ List/Graph 切换 + 搜索；中栏 page 内容（带 highlight annotations）+ 右栏 Sources / Backlinks / Provenance；Graph 模式渲染知识图谱 | `pages` + `entities` + `links` + `annotations` |
| **Inbox** | 4 类待办：CONTRADICTION（矛盾，含 old/new 对比）/ SCHEMA（建议建新 cluster）/ ORPHAN（孤立内容建议归档）/ COMPILED（编译完成通知）；过滤 chips；每条带 1-4 个动作按钮 | `inbox_items[]`，由 AI 后台 worker 生产 |
| **Onboarding** | 3 步：选 domain seeds → 投喂第一份内容 → 实时 compile 进度条 | `user.onboarded` + 第一次 compile |

**设计语言关键点**：
- 暖色档案美学：`#FAF8F6` 暖白底、`#5D3000` 琥珀棕主色、`#F5EDE3` accent-soft
- 三套字体：Space Grotesk（display/headline）、Inter（body）、JetBrains Mono（meta/timestamps）
- 12px 圆角卡片 + 1px 细边框 + 极淡阴影；强调"档案/手工"质感
- 大量 ALL-CAPS 微排版作为 section label 与 metadata
- 248px 固定侧边栏 + 主区流式布局
- 视口锁定 1280px（设计稿 viewport meta）→ Web 端目标 ≥1280px 桌面优先，1024-1280 自适应，<1024 给降级单栏视图

---

## 2. 与现有 iOS 数据模型的对齐

### 2.1 iOS 端现状（必须兼容）

iOS 持久化在 `vault/raw/YYYY-MM-DD.md`，每文件多 memo 用 `\n\n---\n\n` 分隔。每个 memo 是 YAML front-matter + Markdown body（实际字段定义见 `DayPage/Models/Memo.swift:77-130`）：

```yaml
---
id: <UUID>
type: text|voice|photo|location|mixed
created: 2026-05-10T09:42:00.000Z
pinned_at: ...                    # optional
location:
  name: "..."
  lat: 31.23
  lng: 121.47
weather: "..."
device: "..."
attachments:
  - file: "assets/voice-...m4a"
    kind: audio
    duration: 42.5
    transcript: "..."
---
<body markdown>
```

iOS 还有 `EntityPageService`、`OnThisDayIndex`、`SearchService`、`WeeklyRecapService` 等，所以本地已有部分 entity / page 概念，但都是文件系统上的衍生数据，没有 schema 化。

### 2.2 Codex 模型 vs DayPage 模型 的映射

| Codex 概念 | DayPage 对应 | 说明 |
|---|---|---|
| `source` (PDF / URL / voice / text) | `Memo` | Memo 即 source 的最小单元；Codex 的「source」是一组相关 memo 的逻辑聚合 |
| `page` (Concept / Synthesis / Entity) | `EntityPage` (iOS 已有) + 新增 ConceptPage | iOS 已有 entity，Codex 新增 concept / synthesis 类型 |
| `domain` | 顶层 cluster（新概念，iOS 暂无） | 用户/AI 定义的高层主题分类 |
| `link` (backlinks) | iOS 已隐式存在（entity ref） | 显式建图，记录 `(from_page, to_page, source_memo)` |
| `annotation` | iOS 没有 | 用户在 page 文本上的高亮 + 标签 |
| `chat_thread / message / citation` | iOS 没有 | 全新 RAG 问答 |
| `inbox_item` | iOS 没有 | AI 主动产出的待决策事项 |
| `observation` | iOS 没有 | Home 页的「the system noticed」卡片 |

### 2.3 数据迁移策略

**核心原则**：vault 文件仍是 iOS 的 source of truth（不破坏离线性），后端把它当作 *上游数据流* 持续 sync 进 PostgreSQL。Web 端的所有写操作（chat、annotation、inbox 决策）只写后端；iOS 通过订阅 API 拿这些「派生」数据。

```
iOS 写 memo → vault/raw/*.md (本地 + iCloud)
                    ↓ (上传 sync API)
            后端 PostgreSQL (memos 表)
                    ↓ (AI compile worker)
            pages / entities / links / inbox_items
                    ↑                      ↓
                  Web 读写          iOS 订阅 API 显示
```

---

## 3. 整体架构

```
┌──────────────────────────────────────────────────────────────────┐
│                         Cloudflare CDN                           │
└──────────────────┬─────────────────────────────┬─────────────────┘
                   │ static                       │ /api/*
                   ▼                              ▼
        ┌─────────────────────┐       ┌──────────────────────┐
        │  Next.js Web (Vercel)│       │  Next.js API Routes  │
        │  React Server Comp   │       │  + tRPC / REST       │
        │  Tailwind + tokens   │       │  next-auth (JWT)     │
        └──────────┬───────────┘       └──────────┬───────────┘
                   │                              │
                   └──────────────┬───────────────┘
                                  ▼
                  ┌────────────────────────────────┐
                  │   PostgreSQL (Neon / Supabase) │
                  │   + Drizzle ORM                │
                  │   + pgvector (embeddings)      │
                  └────────┬───────────────────────┘
                           │
              ┌────────────┴──────────────┐
              ▼                           ▼
      ┌──────────────┐          ┌────────────────────┐
      │  R2 / S3     │          │  Compile Worker    │
      │  (assets)    │          │  (Inngest / BullMQ │
      │  voice m4a   │          │   Vercel Cron)     │
      │  photos      │          │  调 DashScope API  │
      └──────────────┘          └────────────────────┘
                                          │
                                          ▼
                              ┌──────────────────────┐
                              │  阿里云 DashScope    │
                              │  qwen-plus / qwen-vl │
                              │  text-embedding-v3   │
                              └──────────────────────┘

        iOS App ──── 同样调 /api/* ─── (sync vault → backend)
```

### 3.1 技术栈定稿

| 层 | 选型 | 理由 |
|---|---|---|
| 前端框架 | **Next.js 14 App Router** | SSR + RSC + API routes 一站式；Vercel 一键部；社区最大 |
| 语言 | **TypeScript 5（strict）** | 全栈类型安全，配合 tRPC 端到端推断 |
| 样式 | **Tailwind CSS + CSS variables** | tokens.css 直接搬入 globals.css 作为 CSS 变量；Tailwind 写 utility |
| UI 库 | **自研 primitives（不用 shadcn 全套）** | 设计稿的视觉很特定，shadcn 默认风格会冲；只用 Radix UI 的 headless 部分（Dialog / Dropdown / Tabs） |
| 字体 | **next/font 加载** Space Grotesk / Inter / JetBrains Mono | self-host，零 CLS |
| 图标 | **lucide-react** | 设计稿用的就是 lucide |
| 数据获取 | **TanStack Query (React Query)** + **tRPC v11** | 类型安全 + 乐观更新 + 缓存 |
| 表单 | **React Hook Form + Zod** | 服务端共享 schema |
| 富文本/Markdown 渲染 | **react-markdown + remark-gfm + rehype-highlight** | wiki page 渲染 |
| 图谱 | **react-force-graph-2d** 或自研 SVG（设计稿是固定坐标 SVG，先静态版 → 后期升 force） | MVP 走静态 SVG 跟设计稿一致 |
| 后端 ORM | **Drizzle ORM 0.45** | 比 Prisma 轻、SQL-first、edge-friendly |
| 数据库 | **Supabase（PostgreSQL 16 + pgvector）** | 本地 supabase-cli + Cloud 生产；自带 Auth/Storage/Realtime |
| 认证 | **Auth.js v5 beta** + Apple OAuth + Email magic link | Auth.js 表存 Supabase；session 走 JWT cookie |
| 任务队列 | **Inngest** | compile worker、向量化、定时任务；本地 dev server + Cloud |
| 文件存储 | **Supabase Storage** | 一站式，与 DB RLS 同源；voice m4a + photo + 文件 |
| 实时推送 | **Server-Sent Events (SSE)** | chat 流式输出 + compile 进度推送（无需 WebSocket） |
| 部署 | **Vercel** (web + api) + **Neon** (db) + **Inngest Cloud** (worker) | 全 serverless，按量付费 |
| 监控 | **Sentry** + **Vercel Analytics** + **PostHog**（产品分析） | 你已经有 Sentry→Linear pipeline |
| CI/CD | **GitHub Actions** → Vercel Preview → Production | PR-based |

### 3.2 monorepo 还是 polyrepo？

**推荐 monorepo**（pnpm workspaces）：

```
daypage/                                ← 现仓库
  DayPage/                              ← iOS app（保持原样）
  DayPage.xcodeproj/
  web/                                  ← 新增 Next.js
    app/                                  ← App Router
    components/
    lib/
    server/                               ← API + db schema
    public/
    package.json
  packages/
    shared-types/                       ← Memo / Page / Entity / Inbox 类型 + Zod schema
                                          （iOS 用 Swift 端独立定义，Web/后端共享 TS 版本）
  pnpm-workspace.yaml
  package.json
  turbo.json                            ← Turborepo（可选，加速构建）
```

iOS 不动；shared-types 暂时只服务 Web/后端，避免引入 Swift-TS 代码生成的复杂度。等 schema 稳定后可以再用 OpenAPI 生成 Swift client。

---

## 4. 数据库 schema（核心表）

```sql
-- ========== USER ==========
CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT UNIQUE NOT NULL,
  apple_sub     TEXT UNIQUE,                       -- Apple Sign-In subject
  name          TEXT,
  avatar_url    TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  onboarded_at  TIMESTAMPTZ,
  settings      JSONB DEFAULT '{}'::jsonb          -- domains 偏好、视图布局等
);

-- ========== MEMO (raw input, 1:1 与 iOS Memo) ==========
CREATE TABLE memos (
  id            UUID PRIMARY KEY,                  -- 与 iOS 的 UUID 直接一致
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  type          TEXT NOT NULL CHECK (type IN ('text','voice','photo','location','mixed','url','file')),
  body          TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL,
  pinned_at     TIMESTAMPTZ,
  location      JSONB,                             -- {name, lat, lng}
  weather       TEXT,
  device        TEXT,
  source_url    TEXT,                              -- web 端 URL 抓取后保留
  ingest_mode   TEXT DEFAULT 'full' CHECK (ingest_mode IN ('full','light')),
  compile_status TEXT DEFAULT 'pending' CHECK (compile_status IN ('pending','running','done','failed','skipped')),
  compile_error TEXT,
  word_count    INT,
  origin        TEXT NOT NULL CHECK (origin IN ('ios','web','watch','api')),
  vault_path    TEXT,                              -- iOS 来源时的 vault/raw/YYYY-MM-DD.md
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX memos_user_created ON memos(user_id, created_at DESC);
CREATE INDEX memos_user_status  ON memos(user_id, compile_status);

CREATE TABLE memo_attachments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  memo_id       UUID NOT NULL REFERENCES memos ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('audio','photo','file','link_preview')),
  storage_key   TEXT NOT NULL,                     -- R2 key
  filename      TEXT,
  mime_type     TEXT,
  size_bytes    BIGINT,
  duration_sec  REAL,
  transcript    TEXT,
  ocr_text      TEXT,
  exif          JSONB,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ========== DOMAIN (top-level cluster) ==========
CREATE TABLE domains (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  slug          TEXT NOT NULL,                     -- 'distsys'
  label         TEXT NOT NULL,                     -- 'Distributed systems'
  color         TEXT NOT NULL,                     -- '#5D3000'
  position      INT DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, slug)
);

-- ========== PAGE (compiled artifact: concept / source / entity / synthesis) ==========
CREATE TABLE pages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  slug          TEXT NOT NULL,                     -- 'concept/raft.0a4'
  type          TEXT NOT NULL CHECK (type IN ('concept','source','entity','synthesis','daily')),
  domain_id     UUID REFERENCES domains,
  title         TEXT NOT NULL,
  status        TEXT DEFAULT 'live' CHECK (status IN ('live','draft','archived','cold')),
  body_md       TEXT NOT NULL DEFAULT '',         -- Markdown
  body_html     TEXT,                              -- 缓存渲染后 HTML（含 <mark> 标记）
  metadata      JSONB DEFAULT '{}'::jsonb,         -- entity: {role, org}; concept: {summary}; etc.
  embedding     VECTOR(1536),                      -- pgvector
  source_count  INT DEFAULT 0,
  backlink_count INT DEFAULT 0,
  last_compiled_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, slug)
);
CREATE INDEX pages_user_type ON pages(user_id, type);
CREATE INDEX pages_user_domain ON pages(user_id, domain_id);

-- ========== LINK (page ↔ page, with provenance) ==========
CREATE TABLE page_links (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  from_page_id  UUID NOT NULL REFERENCES pages ON DELETE CASCADE,
  to_page_id    UUID NOT NULL REFERENCES pages ON DELETE CASCADE,
  via_memo_id   UUID REFERENCES memos ON DELETE SET NULL,
  weight        REAL DEFAULT 1.0,
  rationale     TEXT,                              -- AI 生成的「为什么这条边」
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (from_page_id, to_page_id, via_memo_id)
);

-- ========== PAGE_SOURCES (page ← memos, contribution 字段) ==========
CREATE TABLE page_sources (
  page_id       UUID NOT NULL REFERENCES pages ON DELETE CASCADE,
  memo_id       UUID NOT NULL REFERENCES memos ON DELETE CASCADE,
  contribution  TEXT,                              -- 'core protocol' / 'failure-mode framing'
  weight        REAL DEFAULT 1.0,
  PRIMARY KEY (page_id, memo_id)
);

-- ========== ANNOTATION (用户在 page 上的高亮) ==========
CREATE TABLE annotations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  page_id       UUID NOT NULL REFERENCES pages ON DELETE CASCADE,
  anchor        JSONB NOT NULL,                    -- {section_idx, char_start, char_end, text}
  tag           TEXT NOT NULL,                     -- 'important' / 'questionable' / 自定义
  note          TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ========== CHAT (RAG over wiki) ==========
CREATE TABLE chat_threads (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  title         TEXT NOT NULL,
  status        TEXT DEFAULT 'active' CHECK (status IN ('active','archived','synthesized')),
  synthesis_page_id UUID REFERENCES pages,         -- "Save as synthesis page" 后填
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE chat_messages (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id     UUID NOT NULL REFERENCES chat_threads ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
  content       TEXT NOT NULL,                     -- raw markdown w/ {n} citation tokens
  citations     JSONB,                             -- [{n, page_id, memo_id, excerpt, type}]
  suggested     JSONB,                             -- [string]
  tokens_in     INT,
  tokens_out    INT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ========== INBOX (AI 产出的待决策项) ==========
CREATE TABLE inbox_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('contradiction','schema','orphan','compiled','observation')),
  title         TEXT NOT NULL,
  body          TEXT NOT NULL,
  payload       JSONB NOT NULL,                    -- {conflict: {old,new}} / {target_page_id} / {actions: [...]}
  status        TEXT DEFAULT 'open' CHECK (status IN ('open','resolved','dismissed','snoozed')),
  resolution    JSONB,                             -- {action, at, by}
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  resolved_at   TIMESTAMPTZ
);
CREATE INDEX inbox_user_status ON inbox_items(user_id, status, created_at DESC);

-- ========== ACTIVITY (Home 的 Recent activity feed) ==========
CREATE TABLE activities (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  verb          TEXT NOT NULL,                     -- 'compiled' / 'linked' / 'drafted' / 'merged' / 'promoted' / 'archived'
  subject       TEXT NOT NULL,                     -- 主体描述
  target_type   TEXT,                              -- 'page' / 'memo' / 'inbox'
  target_id     UUID,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX activities_user_created ON activities(user_id, created_at DESC);

-- ========== DEVICE (iOS / Web 设备注册，用于 push) ==========
CREATE TABLE devices (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users ON DELETE CASCADE,
  platform      TEXT NOT NULL CHECK (platform IN ('ios','web','watch')),
  push_token    TEXT,
  last_seen_at  TIMESTAMPTZ,
  metadata      JSONB,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ========== SYNC_STATE (vault 增量同步游标) ==========
CREATE TABLE sync_state (
  user_id       UUID NOT NULL,
  device_id     UUID NOT NULL,
  cursor        TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (user_id, device_id)
);
```

**关键决策**：
- `memos.id` 与 iOS UUID 直接复用 → 无 ID mapping
- `pages.body_html` 缓存渲染结果（含 user annotation 的 `<mark>`）→ wiki 页秒开
- `pgvector` embedding 用于 chat 的 RAG 检索（语义查相关 page）
- 所有写操作都记 `activities` → Home 的 feed 现成

---

## 5. API 设计

REST + tRPC 双模式：iOS 用 REST（更稳定、易调试），Web 用 tRPC（端到端类型）。两者底层共享同一组 Zod schema 与 service 层。

### 5.1 资源端点

```
# Auth
POST   /api/auth/apple              Apple Sign-In token 交换
POST   /api/auth/email              magic link 发送
GET    /api/auth/session            当前会话

# Memos (iOS sync)
GET    /api/memos?since=...&cursor=...
POST   /api/memos                   单条创建（web 也用）
POST   /api/memos/bulk              iOS 批量上传（vault diff）
GET    /api/memos/:id
PATCH  /api/memos/:id
DELETE /api/memos/:id
POST   /api/memos/:id/recompile     强制重新编译

# Attachments (signed upload)
POST   /api/attachments/sign        返回 R2 直传 URL
POST   /api/attachments/finalize    上传完成回调

# Domains
GET    /api/domains
POST   /api/domains
PATCH  /api/domains/:id
DELETE /api/domains/:id

# Pages
GET    /api/pages?type=&domain=&q=
GET    /api/pages/:slug
POST   /api/pages                   创建 synthesis page
PATCH  /api/pages/:id               改 title / domain / status
DELETE /api/pages/:id
GET    /api/pages/:id/sources
GET    /api/pages/:id/backlinks
GET    /api/pages/:id/graph         单 page 局部图谱

# Annotations
POST   /api/annotations
DELETE /api/annotations/:id

# Chat (SSE 流式)
POST   /api/chat/threads            新建 thread
GET    /api/chat/threads
GET    /api/chat/threads/:id        含 messages
POST   /api/chat/threads/:id/messages   SSE stream
POST   /api/chat/threads/:id/synthesize 转为 synthesis page

# Inbox
GET    /api/inbox?kind=&status=
POST   /api/inbox/:id/resolve       {action: '...', payload?: {...}}
POST   /api/inbox/:id/snooze
POST   /api/inbox/:id/dismiss

# Activity (Home feed)
GET    /api/activities?cursor=...

# Stats (Home hero)
GET    /api/stats                   {sources, pages, domains, backlinks, deltas}

# Search (跨 page + memo)
GET    /api/search?q=

# Compile (manual trigger / status)
GET    /api/compile/queue           当前 user 的 queue
POST   /api/compile/trigger         指定 memo_id

# SSE
GET    /api/stream/compile          实时 compile 进度
GET    /api/stream/inbox            新 inbox 项推送
```

### 5.2 RAG 检索算法（chat）

1. 用户提问 → embed query (DashScope `text-embedding-v3` 1536-d)
2. `pages` 表按 `cosine similarity` 取 top-20，再用 metadata filter（domain）剪枝到 top-8
3. 把 page bodies 拼成 context（每段截断到 800 tokens），加上引用编号 `[1] page_id=...`
4. system prompt：「只能基于 context 回答；不知道就说不知道；引用必须用 `{n}` 格式对应 references」
5. 调用 qwen-plus 流式生成 → 边生成边 SSE push 给前端
6. 解析 `{n}` token → 写 `chat_messages.citations` JSONB
7. 三条 suggested follow-ups：单独调一次 qwen 短 prompt 生成

### 5.3 Compile worker 流水线

```
new memo (status=pending)
  ↓
worker pick up
  ├─ 转录（如果是 voice）→ Whisper API
  ├─ OCR（如果是 photo）→ qwen-vl
  ├─ 抓取（如果是 URL）→ readability + cheerio
  ├─ 切块 + embed → 写 memo embedding
  ├─ AI compile：
  │    LIGHT 模式 → 只生成摘要，挂到 source page
  │    FULL 模式  → 召回 top-K 已有 page → 让 qwen 决定：
  │                 • 更新哪些既有 page（diff patch）
  │                 • 是否新建 concept page
  │                 • 是否抽出新 entity
  │                 • 是否产生 contradiction（→ inbox）
  ├─ 应用 patch：写 pages / page_links / page_sources
  ├─ 写 activity log
  ├─ 触发 schema 检测（每 N 条跑一次）→ 是否提议新 cluster → inbox
  └─ status = done，SSE push
```

---

## 6. Web 端项目结构

```
web/
  app/
    layout.tsx                      ← root, 字体加载, providers
    globals.css                     ← tokens.css 的内容直接搬入（CSS 变量）
    page.tsx                        ← 重定向到 /home
    (auth)/
      login/page.tsx
      onboarding/page.tsx           ← 3-step flow
    (app)/
      layout.tsx                    ← Sidebar + Topbar 包裹
      home/page.tsx
      add/page.tsx
      chat/page.tsx                 ← thread list
      chat/[id]/page.tsx            ← single thread
      wiki/page.tsx                 ← list mode
      wiki/[slug]/page.tsx          ← page detail
      wiki/graph/page.tsx           ← graph mode
      inbox/page.tsx
      domain/[slug]/page.tsx        ← 单 domain 视图
      settings/page.tsx
    api/                            ← API routes
      [...]
  components/
    ui/                             ← Btn / Chip / Card / Icon / Sparkline / SectionLabel（搬 primitives.jsx）
    layout/
      Sidebar.tsx
      Topbar.tsx
    home/
      HeroBlock.tsx
      ObservationCard.tsx
      ActivityFeed.tsx
      DomainGrid.tsx
    add/
      UnifiedInput.tsx
      CompileQueue.tsx
      RecentCompiled.tsx
    chat/
      ThreadView.tsx
      MessageBubble.tsx
      CitationCard.tsx
      ChatComposer.tsx
    wiki/
      WikiNav.tsx
      WikiPage.tsx
      WikiGraph.tsx
      AnnotationLayer.tsx
      ProvenancePanel.tsx
    inbox/
      InboxFilters.tsx
      InboxCard.tsx
      ContradictionCompare.tsx
  lib/
    auth.ts
    db.ts                           ← drizzle client
    schema.ts                       ← drizzle schema = 上面 SQL 的 TS 版
    ai/
      dashscope.ts                  ← OpenAI-compatible client
      compile.ts                    ← compile pipeline
      rag.ts                        ← retrieval
    sync/
      vault-importer.ts             ← 解析 iOS 的 .md 文件
    sse.ts                          ← Server-Sent Events helper
    upload.ts                       ← R2 signed URL
    fonts.ts                        ← next/font 配置
  server/
    routers/                        ← tRPC routers
      memos.ts
      pages.ts
      chat.ts
      inbox.ts
      ...
    trpc.ts
  hooks/
    useStream.ts                    ← SSE 订阅
    useObservation.ts
    ...
  styles/
    tokens.css                      ← 完整 token 定义
  public/
    fonts/                          ← 自托 woff2
  middleware.ts                     ← auth 守卫
  drizzle.config.ts
  next.config.js
  tailwind.config.ts                ← 把 tokens 暴露成 utility
  package.json
```

---

## 7. 同步策略（iOS ⇄ Web ⇄ Backend）

### 7.1 写入路径

- **iOS 写 memo**：先写 vault `.md`（保证离线）→ 后台 sync 任务 push 到 `/api/memos/bulk`
  - 后端 upsert by `id`（UUID 是 iOS 生成的）
  - 把 attachment 文件经 R2 直传上传
- **Web 写 memo**：直接 POST `/api/memos`（无 vault 概念）
  - iOS 拉到这条新 memo 后，**写回**本地 vault `.md` 文件（保持 iOS 端 vault 完整）

### 7.2 拉取路径

iOS 启动 / 切回前台时：
```
GET /api/memos?since={last_sync_cursor}
GET /api/pages?since={last_sync_cursor}
GET /api/inbox?since={last_sync_cursor}
```
返回新增/修改的资源 + 新游标。

### 7.3 冲突处理

- Memo 是 append-only（不允许编辑 body 后 sync），冲突场景极少
- `pinned_at` / `compile_status` 这类可变字段：last-write-wins，以 `updated_at` 为准
- 若 iOS 的 vault 与 backend 不一致（用户手动改了 .md），iOS 端保留本地，给用户一个「重新上传覆盖」的入口

### 7.4 离线

- iOS：vault 即离线缓存，所有读写本地优先
- Web：用 React Query + IndexedDB（`@tanstack/react-query-persist-client`）做读缓存；写操作离线时排队，恢复后重发

---

## 8. AI 密钥与成本控制

- **DashScope API key 只放 Vercel 环境变量**（`DASHSCOPE_API_KEY`），永远不下发到客户端
- 浏览器调 `/api/chat/...` → 后端代理到 DashScope，response 流式转发
- iOS 也走同一后端代理（不再像现在直接持有 key）→ key 旋转无需发 App Store 更新
- 成本守门：
  - 每用户每天 chat tokens 上限（默认 100k tokens / day，可配）
  - Compile worker 启用 batch 模式，多条 memo 合一次 prompt
  - Embeddings 缓存 7 天
  - 重要：所有 LLM 调用都记 `tokens_in / tokens_out`，运营后台查询用量

---

## 9. 安全与合规

- **认证**：Apple Sign-In（与 iOS 共用 Apple ID）+ Email magic link 兜底；JWT 短期 + refresh token
- **授权**：所有 query 强制带 `where user_id = current_user.id`；用 Drizzle 的 RLS-like helper 包装
- **XSS**：Markdown 渲染走 `react-markdown` 默认 sanitize；`dangerouslySetInnerHTML` 只在 server 端用 DOMPurify 后才允许
- **CSRF**：next-auth 自带 CSRF token，所有 mutation 用 POST + token
- **R2 直传**：用 presigned URL，每个 URL 限定 mime/size/有效期 5 min
- **Rate limit**：`@upstash/ratelimit` 做 per-user 限流（chat: 60 req/min, mutation: 30 req/min）
- **审计**：所有写操作落 `activities`，审计/回溯方便
- **PII**：location 字段属敏感数据，DB 字段加密（pgcrypto）；用户可一键 export + delete account

---

## 10. 里程碑（粗估时间，单人投入）

| Wave | 范围 | 产出 | 估时 |
|---|---|---|---|
| **W0 · 准备** | monorepo 改造、Vercel/Neon/R2/Inngest 接入、CI、Sentry | 空壳能跑 | 2 天 |
| **W1 · 后端骨架** | Drizzle schema + 迁移、auth、`/api/memos` `/api/pages` `/api/inbox` `/api/stats`、R2 upload | iOS 能 sync 到云 | 4 天 |
| **W2 · vault 导入** | iOS vault → backend 一次性导入脚本 + 增量 sync 客户端改造 | 现有数据全在云上 | 2 天 |
| **W3 · Web 骨架 + Home** | Next.js shell、tokens、Sidebar、Topbar、Home view（真数据） | Home 页可看 | 3 天 |
| **W4 · Add view + compile worker** | UnifiedInput、上传、queue、Inngest worker、LIGHT/FULL pipeline、SSE 进度 | 端到端编译 | 5 天 |
| **W5 · Wiki view（List 模式）** | WikiNav、page renderer、annotation、provenance 侧栏 | 可读可标注 | 4 天 |
| **W6 · Wiki Graph 模式** | force-graph 渲染、节点交互、局部展开 | 图谱可看 | 2 天 |
| **W7 · Chat (RAG)** | embedding pipeline、检索、SSE 流式、引用解析、suggested follow-ups | 问答可用 | 4 天 |
| **W8 · Inbox + Observations** | 4 类生成器（contradiction/schema/orphan/compiled）、observation worker、Home 卡片 | AI 主动卡片可见 | 4 天 |
| **W9 · Onboarding + 设置** | 3 步 onboarding、settings 页、domain 编辑、export | 新用户可跑通 | 2 天 |
| **W10 · 生产化** | E2E（Playwright）、a11y 审、性能（lighthouse ≥90）、文档、监控告警 | 可发布 | 3 天 |

**合计 ~35 工作日**。这是真实的生产级估时——不是 hello world。

---

## 11. 风险与开放问题

| 风险 | 应对 |
|---|---|
| Vault 数据迁移可能不一致 | W2 写一个 `vault-doctor` CLI，反向校验 backend ↔ vault hash |
| qwen-plus context window 不够大 page 全文 | RAG 检索按段落级 chunk + rerank；page 长时只送 section heading |
| Compile worker 失败导致 inbox 堆积 | 每个 worker step 幂等 + 死信队列 + 用户后台查看 |
| Web 端 Graph 节点数 >500 渲染卡 | 默认只显示 1-hop，按需懒展开；超 1000 节点用 Canvas |
| iOS 端密钥要从客户端拿掉 | 改造 iOS `CompilationService` 走后端代理，老版本兼容期保留两条路径 |

**开放问题已全部锁定**（见顶部「已锁定决策」表）。后续若有新分歧，再单独提出。

---

## 12. 立即下一步

如果你 review 通过这份方案，我会按这个顺序动手：

1. 在 `web/` 起 Next.js 14 项目脚手架（pnpm + TS strict + Tailwind + tokens.css）
2. 落地 `lib/schema.ts`（drizzle schema）+ 第一份迁移
3. 写 `app/(app)/layout.tsx` + `Sidebar` + `Topbar`，把视觉骨架立起来
4. 接 next-auth + 一个能登录的页面
5. 实现 Home view 用真 API（先返回空数据也行，端到端跑通）

**第 1-5 步 = W0 + W3 的一半，预计 2-3 天，做完发给你看 preview**。然后再继续 W1 / W4。

> 我**不会**一次性写完 35 天的所有代码再交给你。每个 wave 跑完一轮，我把可见的成果发给你 review，你说继续就推进，你说回头改就回头改。
