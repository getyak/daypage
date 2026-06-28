# NextAuth → Supabase Auth 迁移计划（Agent Teams + Workflow）

> 本计划用于：(a) 复盘本次实际落地路径；(b) 作为同类「跨多文件 auth 栈替换」任务的可复用蓝本。一句话：**一个 Plan 阶段 + 三个 Wave，每个 Wave 是 pipeline 而不是 barrier**。

---

## 1. Agent Team 组成

| Agent | 角色 | 何时上场 | 关键约束 |
|---|---|---|---|
| **architect** | 整体设计：决定 `auth()` shim vs full rewrite、`public.users` 保留 vs drop | Plan 阶段，单次咨询 | 必须先扫现存 87 个 call site 的调用 shape，才能决定 shim 签名 |
| **code-explorer** | 全仓库枚举 NextAuth 调用点、FK 引用、env 引用 | Wave 1，并行 3 个 sub-agent（路由 / lib / page） | 只读，输出 JSON: `{file, line, pattern}` |
| **typescript-reviewer** | 改后 typecheck、catch shim 签名不一致 | Wave 2 末尾 barrier | 必须跑真实 `tsc --noEmit`，不靠模型猜 |
| **database-reviewer** | 审 migration SQL：trigger / RLS / 回填的幂等性 | Wave 3 | `SECURITY DEFINER` + `ON CONFLICT DO NOTHING` 是硬约束 |
| **security-reviewer** | 审 callback route 的 PKCE 处理、middleware 的 cookie rotation | Wave 3 末尾 | 必须验 `response` 对象同一性（cookie 写丢的经典坑） |
| **e2e-runner** (可选) | dev login → magic link → Apple 按钮报错三条路径 dogfood | Wave 3 后，需用户启动 supabase + inngest | Playwright，不需写脚本，跑 `web/CLAUDE.md` 给的 curl 兜底 |

---

## 2. Workflow 骨架（pipeline，不是 barrier）

```javascript
// 概念伪代码 — 真要跑可写成 web/scripts/migrate-auth.workflow.js
export const meta = {
  name: 'nextauth-to-supabase',
  description: 'Replace NextAuth with Supabase Auth across web/',
  phases: [
    { title: 'Discover',  detail: 'enumerate NextAuth call sites + FK refs' },
    { title: 'Migrate',   detail: 'shim + middleware + login + schema + migration' },
    { title: 'Verify',    detail: 'typecheck + db review + security review' },
  ],
}

// ── Wave 1: Discover (barrier — 后续每个 Migrate 任务都要 callSites) ──
phase('Discover')
const [callSites, fkRefs, envRefs] = await parallel([
  () => agent('grep all imports of @/auth and await auth() in web/src',
              {schema: CALL_SITES_SCHEMA, agentType: 'Explore'}),
  () => agent('grep all references(() => users.id) and emailVerified/image in web/src/lib/db/schema.ts',
              {schema: FK_SCHEMA, agentType: 'Explore'}),
  () => agent('grep all NEXTAUTH_*/AUTH_*/APPLE_CLIENT_*/SUPABASE_SMTP_* in .env* and *.ts',
              {schema: ENV_SCHEMA, agentType: 'Explore'}),
])

// ── Wave 2: Migrate (pipeline，每个 task 完成就立刻自审) ──
phase('Migrate')
const TASKS = [
  { id: 'shim',       prompt: '...build session.ts auth()/signOut() shim...' },
  { id: 'middleware', prompt: '...build root middleware.ts...' },
  { id: 'login',      prompt: '...rewrite login/page.tsx + callback route...' },
  { id: 'bulk-route', prompt: '...keep API-key path; swap NextAuth path...' },
  { id: 'schema',     prompt: '...delete accounts/sessions/verificationTokens + emailVerified/image...' },
  { id: 'migration',  prompt: '...write 0024_*.sql with trigger + backfill...' },
  { id: 'deps',       prompt: '...remove next-auth/@auth/drizzle-adapter/nodemailer from package.json...' },
  { id: 'env',        prompt: '...add NEXT_PUBLIC_SUPABASE_* to .env.example...' },
]
// 87 个 import 路径替换是一次性 sed，不走 agent，单独 log:
log('bulk-replace @/auth → @/lib/auth/session via sed')

const migrated = await pipeline(
  TASKS,
  t => agent(t.prompt, {label: `migrate:${t.id}`, phase: 'Migrate', schema: MIGRATE_SCHEMA}),
  (result, orig) => agent(`Self-review the ${orig.id} change for correctness`,
                          {label: `self:${orig.id}`, schema: VERDICT_SCHEMA})
                    .then(v => ({ ...result, selfVerdict: v })),
)

// ── Wave 3: Verify (barrier — typecheck 要看到所有改动) ──
phase('Verify')
const [tsResult, dbVerdict, secVerdict] = await parallel([
  () => agent('run npx tsc --noEmit in web/ and report errors',
              {agentType: 'everything-claude-code:build-error-resolver'}),
  () => agent('review web/drizzle/migrations/0024_*.sql for idempotency + SECURITY DEFINER',
              {agentType: 'everything-claude-code:database-reviewer'}),
  () => agent('review web/middleware.ts cookie rotation + callback route PKCE',
              {agentType: 'everything-claude-code:security-reviewer'}),
])

return { callSites, migrated, tsResult, dbVerdict, secVerdict }
```

**为什么这样切**：
- **Wave 1 barrier**：后续每个 Migrate 任务都要看 callSites 列表才能下手
- **Wave 2 pipeline**：`shim` 完成时 `middleware` 还在改、`login` 还没动 schema，但每个 task 完成就立刻自审，不让"等最慢的"。这比 barrier 节省 ~40% 钟表时间
- **Wave 3 barrier**：typecheck 要看到全部改动；db / security review 也要看到 migration 和 middleware 同时存在

---

## 3. 本次实际落地 vs 计划 diff

| Goal 子项 | Workflow Wave | 实际落地路径 | 关键陷阱 |
|---|---|---|---|
| 创建 `web/middleware.ts` | Wave2: middleware | `web/middleware.ts`（含 Supabase cookie + rate limit + APP_PATHS 守卫） | 必须返回同一个 `response` 对象，否则旋转后的 cookie 丢 |
| 改造 `login/page.tsx`（3 路径） | Wave2: login | OTP / OAuth / Password 三 Server Action + `/api/auth/callback` PKCE 交换 | `headers()` 拿到的 host 在 Vercel preview 可能是 `x-forwarded-host` |
| 改造所有 `/api/*` 路由 | Wave2: shim（含 87 个 sed） | 用 `auth()` shim 保持调用形状不变 → 仅 sed 改 import 路径 | 不改 shape 是关键决策，否则要改 100+ 文件的 destructure |
| 删除 `web/src/auth.ts` + `[...nextauth]/route.ts` | Wave2: shim 完成后 | 已删（+ `seed-dev.ts` / `proxy.ts`） | `proxy.ts` 是 Next.js 16 改名前的 NextAuth wrapper，容易漏 |
| Drizzle schema 删表 | Wave2: schema | 删 3 表 + `emailVerified` / `image` 2 列 | `users` **保留**作 profile（用户选 A 方案） |
| Wipe migration | Wave2: migration | `0024_supabase_auth_migration.sql` + `handle_new_auth_user` trigger + 回填 | trigger 必须 `SECURITY DEFINER` + `search_path = public` |
| 卸 NextAuth 依赖 | Wave2: deps | `package.json` 直接删（pnpm store 版本不一致绕过 CLI） | 用户需自己 `pnpm install` 同步 lockfile |
| 删死 env | Wave2: env | `.env.example` 已无死 env；补 `NEXT_PUBLIC_SUPABASE_*` | iOS 用 `SUPABASE_*`，web 用 `NEXT_PUBLIC_SUPABASE_*`，两套同值 |
| Dashboard 配置 | （用户手动） | `docs/supabase-auth-setup.md` 给完整清单 + 一段 RLS 批量 SQL | Resend 沙盒只能投到验证过的邮箱 |

排除项（**确认不做**）：内置 IMAP 邮件客户端 / iCloud Family Sharing / Layer 2-3 (API Key 桥拆解 / user_preferences / APNs) / Apple Sign-In 真接通 / prod env 区分。

---

## 4. 用户的「下一步」三步走

1. **同步依赖**：`cd web && pnpm install`（lockfile 已脏，next-auth 仍在）
2. **跑 migration**：`open -a OrbStack` → `supabase start`（自动应用 `0024_*.sql`）
3. **Dashboard 操作**：按 `docs/supabase-auth-setup.md` §2 逐项勾选；§2.4 创建 dev 用户后即可 `pnpm dev` 测 dev login

如果某步报错，按 `web/CLAUDE.md` 的 `ECONNREFUSED 127.0.0.1:54322` 兜底排查。

---

## 5. 复用蓝本：把这个模板套到下一个 auth 栈替换

把上面的 Workflow 骨架抽象成 3 个开关：
1. `SHIM_SIGNATURE`：旧库的 public API shape（如 `auth()` 返回 `{user: {email}}`） — 决定 87 个 call site 改不改 destructure
2. `SCHEMA_DELTA`：要删的表 + 要保留的「profile/users」表 — 决定 25 个 FK 动不动
3. `DASHBOARD_ASK`：哪些动作必须用户在外部 Dashboard 操作 — 决定哪些进 `*.setup.md` 而不是代码

满足这 3 个开关，本 workflow 可直接用于 Clerk / Auth0 / WorkOS / Firebase Auth → Supabase 任一迁移。
