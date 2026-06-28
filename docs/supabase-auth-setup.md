# Supabase Auth — Dashboard 配置 & 本地启动清单

> 配合 PR `feat/unified-auth-supabase`。代码改造（middleware / login / API 路由 / schema / migration / 依赖卸载）已落地；下列是**用户手动操作**才能跑通的部分。

---

## 1. `.env` 必填项（已加入 `.env.example`）

| 变量 | 用途 | 取值位置 |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `@supabase/ssr` 浏览器/服务端客户端 | Supabase Dashboard → Project Settings → API → Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | 同上 | 同上 → anon public key |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | iOS 端继续使用 | 与上面同值，保持一致 |
| `RESEND_API_KEY` | （供 Supabase Dashboard 配置 SMTP 用） | resend.com → API Keys |
| `RESEND_FROM_EMAIL` | 发件人地址 | 例如 `onboarding@resend.dev`（沙盒）或自有域名 |

> Resend 的 API key / from email **不直接被 web 代码读取**。`@supabase/ssr` 走 Supabase 平台的邮件下发，所以 SMTP 凭据填到 **Supabase Dashboard 而不是 web app**。把 `.env` 里的 `RESEND_API_KEY` / `RESEND_FROM_EMAIL` 当作"自己以后查回时找得到"的备份即可。

---

## 2. Supabase Dashboard 操作清单（按顺序）

### 2.1 Auth → Providers
- [ ] 启用 **Email**（默认勾选）。Confirm email 建议开启；Allow new users to sign up 保持开启。
- [ ] **Apple** provider 暂时**不启用**：login 页保留按钮但点击会报错，符合 goal 文字"点了报错可接受，issue 备注"。后续真接通时再回来配 Services ID + Team ID + Key ID + .p8 私钥。

### 2.2 Auth → SMTP Settings（填 Resend）
- [ ] 打开 "Enable custom SMTP"
- [ ] Sender email: `RESEND_FROM_EMAIL` 的值（沙盒可用 `onboarding@resend.dev`）
- [ ] Sender name: `DayPage`
- [ ] Host: `smtp.resend.com`
- [ ] Port: `465`（TLS）
- [ ] Username: `resend`
- [ ] Password: `RESEND_API_KEY`（粘贴整个 `re_...` token）
- [ ] Minimum interval between emails: 默认即可
- [ ] Save

> ⚠️ 沙盒发件人 `onboarding@resend.dev` 只能投递到**注册 Resend 时验证过的邮箱**。要给任意邮箱发 magic link，必须在 Resend → Domains 验证一个自有域名，再把 `RESEND_FROM_EMAIL` 换成 `noreply@yourdomain.com`。

### 2.3 Auth → URL Configuration
- [ ] **Site URL**: `http://localhost:3000`
- [ ] **Redirect URLs** 白名单加入：
  - `http://localhost:3000/**`
  - 部署上生产环境后再加生产域名

### 2.4 Auth → Users（创建本地 dev 账号）
- [ ] Add user → Create new user
  - Email: `dev@daypage.local`
  - Password: `devpassword`
  - Auto Confirm User: ✅（不发确认信，直接可登）
- [ ] 创建后，DB 的 trigger `on_auth_user_created`（来自 migration `0024`）会自动在 `public.users` 插一条 profile 行。

### 2.5 业务表 RLS（auth.uid() = user_id）
所有持有 `user_id` 字段的业务表都要开 RLS。在 Database → Tables 里逐张表 "Enable RLS"，然后跑下面这段 SQL（SQL Editor → New query）：

```sql
-- DayPage business tables: scope every row to its owner.
do $$
declare
  t text;
  tables text[] := array[
    'memos','memo_attachments','pages','page_links','annotations',
    'inbox_items','domains','trees','tree_nodes','agents','agent_sessions',
    'work_orders','task_suggestions','chat_threads','chat_messages',
    'ingest_sources','api_keys','api_logs','user_settings'
  ];
begin
  foreach t in array tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'drop policy if exists "owner_all" on public.%I; '
      'create policy "owner_all" on public.%I '
      'for all using (auth.uid() = user_id) with check (auth.uid() = user_id)',
      t, t
    );
  end loop;
end$$;
```

> 表名以仓库当前 `web/src/lib/db/schema.ts` 为准。若你的 supabase project 上某张表不存在（migration 还没跑），先 `pnpm --filter ./web db:migrate` 一遍再回来执行。

---

## 3. 本地启动验证

1. 启动 OrbStack / Docker → `supabase start`（自动跑 `web/drizzle/migrations/*.sql`，包括新 `0024_supabase_auth_migration.sql`）。
2. `cd web && pnpm install` 让 lockfile 同步（next-auth / @auth/drizzle-adapter / nodemailer 已从 package.json 删除）。
3. `pnpm dev`（:3000）+ `pnpm dev:inngest`（:8288）—— 见 `web/CLAUDE.md`，少一个都不行。
4. 浏览器开 `localhost:3000/login` → "Dev login (no email)" → 自动跳 `/home`。
5. 退出登录 → 用真实邮箱发 magic link → 收件箱（Resend 沙盒规则下需是已验证邮箱）。

---

## 4. 不在本次 PR 范围（确认已排除）

- 内置 IMAP/SMTP 邮件客户端（用户在 goal 中明确排除）
- iCloud Family Sharing 账户共享
- Phase 2 / Phase 3：拆 API Key 桥、`user_preferences` 同步、APNs 推送
- Apple Sign-In 真接通（按钮可点但会报错——goal 中可接受）
- 生产环境 envvar 区分（仅 dev / preview / prod 走同一套 Supabase Project）
