# Shared web account reading — operations

Scope: the smallest usable shared-backend Web reading surface (issue #884):
standard email/password login, safe `/memos` landing, exact imported tag
catalogue / membership filtering / display, preserved keyset pagination,
authenticated attachments, and local-only logout. Everything here is
placeholders and procedure — no real credentials, no real project values.

## Configuration — one paired public env

The web app reads exactly these two public variables (server factory, client
factory, proxy and the attachment route all use the same pair):

| Variable | Placeholder | Value |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | `<SUPABASE_PROJECT_URL>` | `https://<project-ref>.supabase.co` of the target project |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `<SUPABASE_PUBLISHABLE_KEY>` | the **same** project's publishable/anon key |

- The pair MUST come from the same Supabase project. Injecting only one, or a
  mixed pair, fails closed (reads are refused or redirected to login).
- The new publishable key goes into the existing `NEXT_PUBLIC_SUPABASE_ANON_KEY`
  name. `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` is not read by current code.
- No service-role key, no `DATABASE_URL`, no SQL password is required for the
  reading surface. The tag schema (`user_tags`, `memo_tag_links`, canonical
  migration 0036) is already deployed with own-SELECT RLS.

## Build-time vs runtime

- `NEXT_PUBLIC_*` values are frozen into the client bundle at **build** time.
  Changing only runtime/container env does not switch the realm — the web
  bundle must be rebuilt with the new pair.
- Keep the build-time pair and the runtime pair identical.
- Never commit env values. Do **not** copy the repository root `.env` into
  `web/.env.local` or into an image; never `COPY` a full private env file.

## Local development run (commands for the parent operator)

1. Prepare an ignored `web/.env.development.local` containing ONLY the pair
   above. Do not copy the root `.env`. Resolution order:
   process env → `.env.development.local` → `.env.local` → `.env.development` → `.env`.
2. Check the port first — the web dev server listens on **13000** (not 3000):

   ```sh
   lsof -nP -iTCP:13000 -sTCP:LISTEN
   ```

   Reuse an instance only when it is yours and built from this source with the
   same pair; otherwise start a fresh one.

3. Start (from `web/`):

   ```sh
   env -u NEXT_PUBLIC_SUPABASE_URL -u NEXT_PUBLIC_SUPABASE_ANON_KEY DATABASE_URL= npm run dev -- --hostname 127.0.0.1
   ```

   The explicit empty `DATABASE_URL` keeps any legacy DB out of the picture.
4. Open `http://127.0.0.1:13000/login?callbackUrl=%2Fmemos` and sign in with the
   shared account's email + password. Password and magic-link sign-in both land
   on `/memos` by default; a safe same-origin `callbackUrl` is honored.

## New project / new realm login

- Supabase session cookies are per-project. Do **not** copy, rename or
  transplant cookies between projects; sign in freshly on the new project
  (a full browser reload clears stale client singletons).
- Logout is local-only (this device/browser). Other surfaces stay signed in.
- Two projects or two owners never share cookies in one browser profile.

## Deployment notes (parent-owned)

- `deploy/deploy.sh` copies the root `.env` over `web/.env.local`; it is not
  part of this cutover and must not be used to configure the shared realm.
- Supplying the public pair at image build time and keeping runtime in sync is
  a separate, explicitly authorized change. This batch changed no deployment
  scripts and no default env.
- Local acceptance needs no Docker, Inngest, seed or DB migration.

## Verification checklist (parent-owned; not executed in this batch)

- Real account password login → lands on `/memos`; wrong password shows one
  generic error (no credentials or raw Auth errors echoed); logout works locally.
- `/memos` paginates past 1000 memos via “Older memos” with original
  `created_at` values; no duplicates or gaps at the boundaries.
- `?tag=` filters exact labels — `#a,b`, `#父/子`, `#Case` vs `#case`, literal
  `%`/`_` — metadata-only (body text never matches); the selector lists unused
  catalogue labels; chips and selector round-trip exact bytes.
- One text, one photo, one audio and one file memo render; images open,
  audio/video seek via Range, unsupported codecs still download as originals.
- Anonymous `/memos?tag=…` and `/memos/[id]` deep links return to the same URL
  after login.

## Private local acceptance

Set `DAYPAGE_PRIVATE_PREVIEW=1` only in the owned preview process when verifying real imported notes. This disables Next development request/browser logging and its development MCP log file (`logging:false`, `experimental.mcpServer:false`). The parent launcher discards raw process output as an additional guard. It does not change authentication, RLS, paired public configuration or production defaults. Keep credentials/content out of console output, screenshots and aggregate receipts.
