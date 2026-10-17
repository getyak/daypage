# ADR-0022: Account-scoped read-only web memo history and media

- **Status:** Accepted
- **Date:** 2026-10-16
- **Issue:** [#884](https://github.com/getyak/daypage/issues/884)
- **Extends:** [ADR-0016](ADR-0016-revisioned-attachment-sync.md)

## Context

The flomo import needs full-history reading on the web: `/home` and `/today`
only surfaced today, there was no history route, `/api/img` was permanently
404, and memo detail showed only the first photo with no audio/file display.
The web read path also resolved identity by email through Drizzle/`DATABASE_URL`,
which may point at an old database realm while the new same-project backend
(Auth + Postgres + private Storage) is what actually holds the imported
accounts. Legacy edit/delete/pin/share actions on detail could therefore mutate
an unrelated realm.

## Decision

### Read-only, account-scoped boundary

New history/detail/media reads are **read only**. They use the existing
cookie-bound Supabase SSR client (`web/src/lib/supabase/server.ts`) with the
verified `auth.getUser().id` — never email, never Drizzle/`DATABASE_URL` —
combined with RLS and explicit `user_id` predicates and `deleted_at is null`
tombstone exclusion. No service key, schema, SQL or dependency changes. Legacy
edit/delete/pin/share/recompile actions are not wired on the new detail page.

### History reads

`GET /api/memos/history` and the SSR `/memos` page share one repository
(`web/src/lib/memos/`). The query surface is strictly validated before any
PostgREST filter is composed: `q` literal substring search (top-level `imatch` with PostgreSQL `***=`
literal mode, including quotes/stars/backslashes; control characters rejected),
optional `type` and `from`/`to` created-time filters (Asia/Shanghai day
windows), bounded page size, and stable descending `(created_at, id)` keyset
pagination. Cursors carry the **original database timestamp string**, so
microsecond precision is never truncated by `Date.toISOString()`. Cursor dates,
time fields and timezone offsets are validated semantically before any query. Attachments
are fetched in one batched query per page (no N+1). The legacy `GET /api/memos`
timestamp-cursor contract is untouched. All data is request-scoped: no
cross-user cache exists in this slice, and any future client query cache key
must contain the user ID.

### Same-account identity

Identity is the Supabase auth uid even when the account has no email. The app
layout's reads moved to the same uid/RLS contract (domains only); the
server-private inbox count is not client-readable under the new RLS, so the
badge is omitted — deferred, not fabricated as zero — instead of widening
backend policies. Anonymous history requests preserve their intended
destination in the login redirect when a path-carrying request header is
available; a Server Component layout cannot observe the URL directly, so full
destination capture needs the parent-owned proxy to forward the path (documented
gap below).

### Markdown rendering

Memo bodies render their **original Markdown** through the already-installed
react-markdown + remark-gfm + rehype-sanitize: raw HTML never executes,
dangerous URL protocols are stripped, remote image embeds are not rendered, and
links are never nested. Conventional hashtags (including multi-level paths,
with trailing ASCII/Chinese punctuation excluded) link to `/memos?q=%23…` text
search; code spans/blocks and link destinations are untouched. Existing safe
mention links remain. This batch does **not** claim exact flomo taxonomy:
unused/catalog punctuation tags and exact per-memo tag associations require the
parent's later account-catalog contract. No source bodies are rewritten and no
entity mentions are invented.

### Streaming media proxy

`GET/HEAD /api/memos/[id]/attachments/[attachmentId]` authenticates first,
validates UUIDs, then loads the owned non-tombstoned memo and its exact
attachment ID. The object key comes only from trusted DB metadata and must be
owner-prefixed and traversal/control-character/URL free; the request never
supplies a key or target. The proxy performs an authenticated GET or HEAD against the
**same** configured Supabase project's private `memo-attachments` bucket with
the verified user's access token and the API key kept server-side; `fetch` runs
with `redirect: "manual"` so the Bearer token can never follow a redirect to
another host. Bytes are streamed (never buffered) with abort propagation to the
upstream fetch.

Single HTTP byte ranges are supported (`206`/`Content-Range`/`Accept-Ranges`);
malformed, multi and out-of-range requests are rejected with `416` and a safe
`Content-Range: bytes */size` when the size is known, and inconsistent upstream
partial responses fail closed. Only safe response headers are forwarded with
`private, no-store` + `nosniff`. Inline preview is limited to the supported
safe image/audio/video MIME pairs (the seven legacy kind/MIME pairs plus the
parent-reviewed `audio/aac` and `video/quicktime`); other files download with a
CRLF-safe RFC 5987 filename. Wrong-user/missing/tombstoned/unsafe-key all
return one uniform `404`, unauthenticated returns `401`, and backend failures
return a generic error that exposes no tokens or object paths.

## Consequences and gaps

- **Read-only slice:** edit/delete/pin/share, upload, and any memo mutation on
  web stay out of scope; they must land with their own reviewed contract
  against the new backend before being wired to UI.
- **Taxonomy:** flomo tag catalog semantics (unused/punctuation tags, exact
  per-memo associations) are explicitly deferred to the parent's
  account-catalog contract; current hashtag links are conventional
  text-search links only.
- **Legacy attachment rows** whose stored key fails the owner-prefix check are
  shown honestly as unavailable (never dropped, never "verified"); serving them
  requires a data-migration decision owned by the parent.
- **Deferred counts:** the sidebar inbox badge is omitted until a client-readable
  count exists; the layout fails loudly on backend errors rather than rendering
  fabricated-empty state.
- **Login destination:** the shared `(app)` layout cannot observe the request
  URL in a Server Component, so destination-preserving redirects need the
  parent-owned proxy to forward `x-pathname` as a request header (or gate
  `/memos` with `callbackUrl` like `/oauth/consent`); page-level redirects
  already preserve full search state where they run.
- **Web-only:** no iOS/Android/MCP surface changed; no schema, SQL, storage or
  dependency change accompanies this ADR.

Parent review corrections: top-level filter wire values are tested through the installed Supabase SDK; regex literal semantics were separately checked against PostgreSQL. Range responses must match the complete requested interval (including suffix/open/clamped end) and byte length; discarded upstream streams are cancelled, and consumer cancellation propagates. Actual component rendering remains a separate acceptance gate.
