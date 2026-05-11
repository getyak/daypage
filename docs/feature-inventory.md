# DayPage Feature Inventory

**Generated**: 2026-05-11
**Snapshot**: `main` after PR #265 (V5 Codex web visual redesign) + working tree on `feat/v5-codex-redesign`
**Scope**: Two products coexist in one monorepo — **DayPage iOS App** (`DayPage/`) and **Daypage Web (V5 Codex)** (`web/`).

Status legend:
- ✅ Shipped, real data flow connected
- 🎨 Visuals complete, data not yet wired
- 🚧 Half-built / partial functionality
- ❌ Placeholder / not implemented
- 🐛 Known bug

---

## 0. Overview

### 0.1 The two products

| | DayPage iOS | Daypage Web (V5 Codex) |
|---|---|---|
| One-liner | Personal raw-capture journal: dump → AI compiles to daily page + entity wiki | Cross-device AI knowledge OS: memo → compile → wiki/concepts/synthesis, with chat-over-your-wiki |
| Storage | File system (`vault/raw/YYYY-MM-DD.md` + `vault/wiki/...`) on iCloud | Postgres via Supabase + Drizzle ORM |
| AI provider | **DeepSeek** (`deepseek-v4-pro`, OpenAI-compatible) — note: README/CLAUDE.md still say DashScope, which is stale | **Aliyun DashScope** (`qwen-plus`, OpenAI-compatible) |
| Background | iOS `BGAppRefreshTask` @ 02:00 local | Inngest functions on Vercel |
| Auth | Supabase Auth (Apple OAuth + email OTP) | NextAuth v5 + Drizzle adapter (Apple OAuth + Nodemailer magic link + dev Credentials) |
| Source of truth (currently) | The local vault on the device, optionally iCloud-mirrored | The Postgres DB |
| Data exchange between them | **None** — completely independent products today |

The PRD direction (commit `7058173`) is for them to **share one Postgres** so the iOS app reads/writes against the same memos/pages tables Web uses. That work is not yet started.

### 0.2 Health dashboard

| Module | Completion | Design fidelity | Risk | Notes |
|---|---|---|---|---|
| **iOS Today (composer + memo list)** | ~95% | n/a (own design lang) | low | 1037-line view, 909-line VM — production quality |
| **iOS Daily (compiled daily page)** | ~85% | n/a | low | 1813-line view, includes thread-reply (PR #261) |
| **iOS Archive (calendar + search)** | ~90% | n/a | low | 1229-line view |
| **iOS Graph** | ~60% | n/a | medium | CLAUDE.md says 18-line placeholder; actually 309-line force-simulation view — ahead of doc |
| **iOS Entity pages** | ~80% | n/a | low | Markdown-driven, 404-line view |
| **iOS AI compilation (DeepSeek)** | ~95% | n/a | medium | API-key risk; raw + hot context + structured parse + entity instructions |
| **iOS Background compilation** | ~95% | n/a | low | BG task + backfill + failure notification |
| **iOS Auth** | ~95% | n/a | low | Apple + email OTP, rate-limited |
| **iOS Voice / Photo / Location / Weather** | ~90% | n/a | low | All wired end-to-end |
| **iOS Watch companion** | ~70% | n/a | medium | `WatchReceiveService` exists, separate target `DayPageWatch/` |
| **iOS iCloud sync + conflict merger** | ~85% | n/a | medium | Atomic write via `NSFileCoordinator`, conflict monitor running |
| **Web `/login`** | 100% | 9/10 | low | 🐛 hydration warning (caret-color inline) |
| **Web `/(app)/home`** | 25% real / 100% visual | 9/10 | medium | All observations, recent activity, domain sparklines are mock data; no SSR fetch yet |
| **Web `/(app)/add`** | ~60% real / 100% visual | 9/10 | medium | Memo POST works; voice/file drop visuals only; SSE queue stream wired |
| **Web `/(app)/chat` + `/[id]`** | ~80% | 8.5/10 | medium | Server-side hydration + SSE streaming + RAG pages. Citations present but UI cite-rail not always populated |
| **Web `/(app)/wiki` + `/[slug]`** | ~80% | 8.5/10 | low | Pages render Markdown, source/backlink/annotation panes wired |
| **Web `/(app)/inbox`** | ~85% | 9/10 | low | 4 kinds with real list + resolve/dismiss/snooze API |
| **Web `/(app)/domain/[slug]`** | ~80% | 8.5/10 | low | Server-rendered pages grouped by type |
| **Web AI compile pipeline (Inngest)** | ~85% | n/a | medium | light/full/conflict-check + daily-page + schema-detect + orphan-detect; pgvector migration written but **not applied** |
| **Cross-product sync** | 0% | n/a | high | Designed in PRD, not started |

---

## 1. DayPage iOS

### 1.1 Data layer

#### 1.1.1 Storage

Flat-file vault at `<app sandbox or iCloud>/DayPage/vault/`:

```
vault/
  raw/
    YYYY-MM-DD.md         # multi-memo per day, separated by HTML-comment marker
    assets/               # voice .m4a, photo originals/thumbs
  wiki/
    daily/YYYY-MM-DD.md   # AI-compiled daily page
    places/<slug>.md
    people/<slug>.md
    themes/<slug>.md
    index.md              # entity index, kept in sync by EntityPageService
    hot.md                # rolling AI working memory
    log.md                # compile audit trail
```

Two `VaultInitializer` implementations: local container vs iCloud ubiquity. iCloud may return nil on cold launch; `DayPageApp.init` re-probes off the main thread and swaps the locator if iCloud becomes available later. Atomic writes go through `NSFileCoordinator` so iCloud Drive sees writes as coherent ops (`RawStorage.atomicWrite`, `RawStorage.swift:144`).

The memo separator changed from bare `---` to `<!-- daypage-memo-separator -->` (issue #227) because users' `---` in markdown was being misparsed; `RawStorage.parse` is backward-compatible with both legacy and current formats.

Writes are serialised through a `DispatchQueue` (`com.daypage.rawstorage.write`) to prevent races between voice transcription finishing and a manual send dropping one memo (`RawStorage.append`).

#### 1.1.2 `Memo` model (`DayPage/Models/Memo.swift`)

```
Memo {
  id: UUID
  type: text | voice | photo | location | mixed
  created: Date
  pinnedAt: Date?
  location: { name, lat, lng }?
  weather: String?
  device: String?
  attachments: [Attachment]
  body: String
}

Attachment {
  file: String
  kind: "photo" | "audio"
  duration: Double?   // audio only
  transcript: String? // audio only
}
```

Serialised as YAML front-matter + Markdown body. Hand-rolled `YAMLParser` in the same file — no external dependency. Risk: any field added on iOS without updating the parser silently drops on read.

#### 1.1.3 Persistent services

| Service | Persists what | Where |
|---|---|---|
| RawStorage | Raw memos | `vault/raw/*.md` |
| EntityPageService | Entity wiki pages + index | `vault/wiki/places\|people\|themes/*.md`, `wiki/index.md` |
| CompilationService | Daily pages + hot context + log | `vault/wiki/daily/*.md`, `wiki/hot.md`, `wiki/log.md` |
| FeedbackService | Pending feedback items | App support directory |
| OnThisDayIndex | Date → memo refs cache | App support directory |
| VoiceAttachmentQueue | Pending voice uploads | App support directory |
| AuthService (Supabase) | Session / refresh token | Keychain (via `KeychainHelper`) |
| AppSettings | UserDefaults keys | `UserDefaults.standard` |

### 1.2 Services layer (`DayPage/Services/`)

26 service files. Key ones:

**CompilationService** (`@MainActor singleton`). Reads today's raw file + `wiki/hot.md`, builds prompt, calls DeepSeek (`api.deepseek.com/v1`, model `deepseek-v4-pro`), parses structured output (daily page + entity update instructions + new hot cache), writes daily page (backup-on-overwrite), updates entities, rotates hot.md, appends `log.md`. Offline pre-check via `NetworkMonitor`; retries with `onRetry` callback; throws typed `CompilationError`.

**BackgroundCompilationService**. Registers `BGAppRefreshTask` (id `com.daypage.daily-compilation`), schedules next fire for 02:00 local, backfills up to 7 missed days on foreground, posts local notifications on failure with retry action, publishes `compilationDidStart/End/Fail` notifications consumed by `TodayViewModel`.

**EntityPageService**. Applies the LLM's entity update instructions: creates new `vault/wiki/<type>/<slug>.md` or appends under the right `## Section` heading on existing pages; keeps `wiki/index.md` grouped by type.

**AuthService** + **AuthRateLimiter** + **KeychainHelper**. Supabase Auth (Apple Sign In + email OTP). Custom `DPAuthError` type for user-facing errors, including `rateLimited(retryAfter:)`, `otpLocked(retryAfter:)`, `networkUnavailable`. Persists lockout state across launches.

**VoiceService**. AVAudioRecorder → m4a; sends to OpenAI Whisper via `whisper-1`; writes transcript onto the attached `Memo.Attachment`.

**PhotoService**. PhotosUI / PHPicker; EXIF extraction (aperture/shutter/ISO/focal length/GPS/timestamp); writes originals and thumbnails into `vault/raw/assets/`.

**LocationService** + **PassiveLocationService**. CoreLocation with reverse geocoding; passive monitoring kicks in only with "Always" permission. Recent fix (PR #262) auto-embeds GPS coords into the memo location field.

**WeatherService**. OpenWeatherMap free tier, 10-min cache, `zh_cn` locale.

**WatchReceiveService**. WCSession listener; eager init from `DayPageApp.init` so it activates on launch (otherwise lazy singleton missed transfers).

**iCloudSyncMonitor** + **iCloudConflictMonitor** + **ConflictMerger**. Detect iCloud sync activity and `.icloud` conflict files; auto-merge conflicting memo files.

**SearchService**, **OnThisDayIndex**, **OnThisDayScheduler**, **WeeklyRecapService**. Read-side aggregations driven by the raw/wiki files; surfaced in Today (`OnThisDayCard`, `WeeklyRecapSection`) and Archive (`SearchView`).

**SampleDataSeeder**. First-launch demo data for empty vault.

**VaultMigrationService**. 307-line forward-migrator that handles file-format upgrades (e.g. separator change, location-embed retrofit).

**FeedbackService** / **FeedbackViewModel** / **FeedbackContext**. In-app feedback UI; persists pending items locally and posts when online.

**DayPageLogger**, **NetworkMonitor**. Cross-cutting infra.

### 1.3 View layer (`DayPage/Features/`)

#### 1.3.1 App shell

`DayPageApp.swift` (131 lines) wires SentrySDK, font registration, vault init, BG-task registration, notification delegate, eager Watch session, deep-link `daypage://` handler for auth callbacks.

`RootView.swift` (173 lines) gates onboarding, welcome, auth (`fullScreenCover`), and the sidebar drawer. Tracks `showAuthSheet` on a stable boolean (issue #221 — derived bindings flickered).

`SidebarView.swift` (200 lines) — left drawer (280pt), entries Today / Archive / Graph / Settings, plus feedback opener.

`AppNavigationModel.swift` — `@Published` selection state for sidebar nav.

#### 1.3.2 Today (`Features/Today/`, 22 files, ~6k LOC)

Headline files: `TodayView.swift` (1037), `TodayViewModel.swift` (909), `InputBarV4.swift` (1036), `MemoCardView.swift` (976).

Capabilities:
- Composer (`InputBarV4` + `ComposerStateMachine`): text, voice (`PressToTalkButton`, `VoiceRecordingView`, `RecordingOverlayView`), photo (`CameraPickerView`), document (`DocumentPickerView`), lens strip (`InlineLensStrip`), smart templates (`SmartTemplateRow`).
- Memo list with swipe-to-delete (`SwipeableMemoCard`, PR #259/#260 polished the rubber-band spring and close gesture).
- DayOrb visual indicator of compile state (`DayOrbView`).
- Spotlight strip (`SpotlightStripView`), OnThisDay card, weekly recap section.
- Compile footer button + AttachmentMenu popover/sheet pair (popover on iPad, sheet on iPhone).

Status: ✅ shipped, recent fixes for voice card scroll blocking (PR #262), layout jitter (#257), and thread reply (#261).

#### 1.3.3 Daily (`Features/Daily/`)

`DailyPageView.swift` (1813 lines, largest in the codebase). Renders the AI-compiled daily page from `vault/wiki/daily/*.md` with inline mic button (`InlineMicButton`) and thread-conversation UI (`ThreadConversationView` + VM). Recent PR #261 added thread reply + freeform input for compiled pages.

Status: ✅ shipped.

#### 1.3.4 Archive (`Features/Archive/`)

`ArchiveView.swift` (1229) — calendar grid + chronological list. `DayDetailView`, `RawMemoView`, `SearchView` (494). Status: ✅.

#### 1.3.5 Graph (`Features/Graph/`)

`GraphView.swift` (309) — search field, filter toggle, zoom/pan via gestures, force-directed simulation timer (max 200 steps), `selectedNode` detail navigation to `EntityPageView`. `GraphViewModel.swift` (285) drives the node/edge model.

**Discrepancy from project doc**: CLAUDE.md states this is an 18-line placeholder and Post-MVP. The repo has a working force-simulation graph with filters. Either the docs are stale or this work landed without a doc update. Recommend updating CLAUDE.md.

Status: 🚧 working but probably not yet feature-complete; performance under large node counts unverified.

#### 1.3.6 Entity (`Features/Entity/`)

`EntityPageView.swift` (404) — Markdown rendering of `vault/wiki/<type>/<slug>.md`. Status: ✅.

#### 1.3.7 MemoDetail, Onboarding, Settings, Auth, Feedback

All standard SwiftUI features wired to their respective services. Settings includes `TimeZonePickerView` (writes to `AppSettings.preferredTimeZone`, picked up immediately by `RawStorage.dateFormatter`).

Auth flow: `AuthView` → `EmailAuthView` → `OTPVerificationView` + `OTPVerificationViewModel`. Account sheet under `AccountSheet.swift`.

### 1.4 iOS known issues / TODO

1. Docs are stale: README/CLAUDE.md claim DashScope (`qwen3.5-plus`), code actually calls DeepSeek (`deepseek-v4-pro`). Same docs claim Graph is an 18-line placeholder; it's 309 lines.
2. The `Memo` YAML parser is hand-rolled — any new field on disk silently drops on read unless the parser is updated.
3. `Memo.MemoType` enum uses `.mixed` but `MemoCardView`/serialisation drift hasn't been audited recently.
4. `TodayView` and `DailyPageView` exceed the 800-line cap from the project's coding standard (CLAUDE.md) — splitting deferred.
5. No DayPageTests target in Xcode project yet (`DayPageTests/` folder exists with files but the scheme/target needs to be confirmed).
6. iCloud cold-launch path: if the ubiquity container isn't ready on first launch, the locator swap happens off the main thread — race risk if user creates a memo within the first ~100ms.
7. Watch target (`DayPageWatch/`) compilation status uncertain — separate target, separate review.

---

## 2. Daypage Web (V5 Codex)

### 2.1 Drizzle schema (`web/src/lib/db/schema.ts`)

The schema is ambitious — 19 tables across 5 logical waves. Highlights:

**Auth & users**
- `users` (id, email, apple_sub, name, avatar_url, emailVerified, image, created_at, onboarded_at, settings jsonb)
- `accounts`, `sessions`, `verificationTokens` — verbatim NextAuth Drizzle adapter shape (camelCase column names — do **not** snake-case)

**Memos**
- `memos` (id, user_id, type enum[text/url/voice/photo/file], body, created_at, pinned_at, location jsonb, weather, device, source_url, ingest_mode enum[light/full], compile_status enum[pending/running/done/failed], origin enum[ios/web/api], vault_path, compile_error, **compile_step** (normalize/embed/recall/compile/apply/notify), **embedding** (text, JSON-encoded number[] — pgvector migration pending), updated_at)
- `memo_attachments` (memo_id, kind enum[audio/photo/file], storage_key, filename, mime_type, size_bytes, duration_sec, transcript, ocr_text, exif jsonb)

**Knowledge graph**
- `domains` (slug, label, color, position) — sidebar groups
- `pages` (id, slug, type enum[concept/source/entity/synthesis/daily], domain_id, title, status enum[draft/live/archived], body_md, body_html, metadata jsonb, embedding, version, source_count, backlink_count, last_compiled_at)
- `page_links` (from_page_id, to_page_id, via_memo_id, weight, rationale)
- `page_sources` (page_id, memo_id, contribution, weight)

**Annotations & chat**
- `annotations` (page_id, anchor jsonb, tag, note)
- `chat_threads` (title, status, synthesis_page_id)
- `chat_messages` (thread_id, role enum, content, citations jsonb, suggested jsonb, tokens_in, tokens_out)

**Inbox & activity**
- `inbox_items` (kind enum[contradiction/schema/orphan/compiled], title, body, payload jsonb, status enum[open/resolved/dismissed/snoozed], resolution jsonb, resolved_at, snooze_until)
- `activities` (verb, subject, target_type, target_id)

**Sync**
- `devices` (platform enum[ios/web/android], push_token, last_seen_at, metadata)
- `sync_state` (user_id+device_id PK, cursor)

**Telemetry / audit**
- `prompt_log` (kind, model, tokens_in, tokens_out) — used by the chat daily-token-cap (100k/day)
- `embed_cache` (body_hash unique, embedding) — 7-day TTL
- `change_log` (action_kind, target_type, target_id, before/after jsonb, reason, performed_by, agent_action_id) — agent/user mutation audit
- `schema_cluster_log` (cluster_signature, suggested_name, inbox_item_id) — schema-detect idempotency

Indexes are user-scoped (`memos_user_created`, `memos_user_status`, `pages_user_type`, `pages_user_domain`, `inbox_user_status`, `activities_user_created`, `schema_cluster_log_user`).

### 2.2 Migrations

Applied per `meta/_journal.json` (8 entries):

| File | Adds |
|---|---|
| 0000_unique_true_believers | Initial — users, memos, memo_attachments, domains, pages, page_links, page_sources |
| 0001_futuristic_apocalypse | annotations, chat_threads, chat_messages, inbox_items, activities, devices, sync_state |
| 0002_broken_king_bedlam | prompt_log |
| 0003_green_the_anarchist | embed_cache |
| 0004_medical_sister_grimm | change_log |
| 0005_conscious_lord_hawal | `memos.compile_step` column |
| 0006_medical_caretaker | schema_cluster_log |
| 0007_productive_oracle | `pages.version` column |
| 0008_great_centennial | NextAuth tables (accounts, sessions, verificationTokens) |

⚠️ **`0006_pgvector_hnsw.sql` exists in the migrations folder but is NOT in `_journal.json`** — it's named the same idx (6) as `0006_medical_caretaker`. This file converts `pages.embedding` from text-JSON to native `vector(1536)` and creates an HNSW index. It's been written but not applied. Until it is, all cosine-similarity is JS-side (see `cosineSim` in `compile-memo.ts` and `schema-detect.ts`).

### 2.3 API routes (`web/src/app/api/`)

26 route files. Grouped:

**Auth** — `/api/auth/[...nextauth]` — handled in `web/src/auth.ts`. Providers: Apple OAuth, Nodemailer magic link (via Supabase SMTP), and a dev-only `Credentials` provider toggled by `NODE_ENV=development` or `E2E_DEV_LOGIN=1`. Session strategy: `jwt` in dev (Credentials requires it), `database` in prod (Drizzle adapter). Pages: `signIn: /login`. ✅

**Memos**
- `GET /api/memos` — list with cursor pagination, `since` filter, `compile_status` filter, default 50/page. Returns `{ items, next_cursor, has_more }`. ✅
- `POST /api/memos` — create + insert attachments + send `memo/created` Inngest event. Rate-limited per email. ✅
- `GET /api/memos/[id]`, `PATCH /api/memos/[id]`, `DELETE /api/memos/[id]` — ✅
- `POST /api/memos/[id]/recompile` — re-enqueue compile. ✅
- `POST /api/memos/bulk` — batch operations. ✅

**Pages**
- `GET/POST /api/pages` — list/create. ✅
- `GET/PATCH/DELETE /api/pages/[slug]` — ✅ (recently renamed from `[id]` → `[slug]` per working-tree diff)
- `GET/POST /api/pages/[slug]/annotations` — ✅
- `GET /api/pages/[slug]/backlinks` — ✅
- `GET /api/pages/[slug]/sources` — ✅

**Annotations** — `/api/annotations` + `/api/annotations/[id]` — global counterpart to the per-page route. ✅

**Page links** — `/api/page_links` — list/create cross-page links. ✅

**Inbox**
- `GET /api/inbox` — list open items. ✅
- `POST /api/inbox/[id]/resolve` — moves to `resolved`, writes `resolution` jsonb. ✅
- `POST /api/inbox/[id]/dismiss` — ✅
- `POST /api/inbox/[id]/snooze` — sets `snooze_until`. ✅

**Domains** — `GET/POST /api/domains`, `PATCH/DELETE /api/domains/[id]`. ✅ (sidebar reads these via RSC in `(app)/layout.tsx`)

**Chat**
- `GET/POST /api/chat/threads` — list/create threads. ✅
- `GET/PATCH/DELETE /api/chat/threads/[id]` — ✅
- `POST /api/chat/threads/[id]/messages` — **SSE-streamed** assistant response. Pulls RAG pages via `retrievePages`, enforces a 100k tokens/day cap from `prompt_log`, builds a system prompt with `[1]…[n]` reference blocks, streams via `dashscope`, persists final message + citations. ✅

**Activities** — `GET /api/activities` — activity feed for the Home page (when wired up). ✅

**Stats** — `GET /api/stats` — counts for sidebar/home stat tiles. ✅

**Stream/compile** — `GET /api/stream/compile` — SSE stream of memo compile progress for the signed-in user. Polls memos changed in last 24h every 2s with 15s heartbeats. Pure DB-poll (not Inngest-aware), so progress is eventually consistent. ✅ but: heavy on DB for many concurrent clients.

**Inngest webhook** — `GET/POST /api/inngest` — the standard `serve(...)` endpoint for Inngest functions. ✅

### 2.4 Background tasks (`web/src/lib/inngest/functions/`)

Four functions:

**`compile-memo.ts`** — listens on `memo/created`. Two modes via `memos.ingest_mode`:

- **LIGHT**: builds a one-shot prompt (`compile-light.md`), expects `{ summary, keywords, suggested_domain }`. Cheap path for trivial inputs.
- **FULL**: hash → check `embed_cache` (7-day TTL) → embed memo → kNN over `pages.embedding` (JS-side cosine, top-K=8) → build prompt with retrieved pages (`compile-full.md`) → LLM returns `operations[]` (`update_page` / `create_page` / `create_link` / `extract_entity`) → apply ops in a Drizzle txn → run conflict-check on `update_page` results → write `change_log` rows → mark memo `done` and update `compile_step` through `normalize → embed → recall → compile → apply → notify`. ProviderError-tolerant with retry.

Three prompt files in `web/src/lib/ai/prompts/`: `compile-light.md`, `compile-full.md`, `conflict-check.md`, `daily-page.md` (loaded at module top via `fs.readFileSync`).

**`daily-page.ts`** — listens on a scheduled event. For each user, groups memos by their local date, calls DashScope with the day's memos (HH:MM UTC stamps), persists a `daily` page. Idempotent on `(user_id, date)`.

**`schema-detect.ts`** — every 50th new memo for a user, runs a kNN cluster over the last 200 memos. If a cluster of ≥8 memos with cosine ≥0.55 forms a stable signature not seen in the last 7 days, asks the LLM for a domain name and writes a `schema`-kind inbox item, deduped via `schema_cluster_log.cluster_signature`. Status: ✅ pipeline coded; production firing depends on Inngest cron config.

**`orphan-detect.ts`** — finds pages with `status != archived`, `backlink_count = 0`, `last_compiled_at` older than 90d (or null), `updated_at` older than 30d. Up to 5 suggestions per user → writes `orphan`-kind inbox items. Status: ✅ coded, runs from a per-user trigger.

### 2.5 Page routes & components

Auth gate: `(app)/layout.tsx` server-side `auth()` check → `redirect('/login')` if no session. Layout fetches sidebar data (domains list + open inbox count) inline.

**`/` (root, `app/page.tsx`)** — 7-line redirect to `/home`. ✅

**`/login`** (`app/login/page.tsx`, 79 lines) — Apple Sign In button + magic-link form + dev-only Credentials form gated by `NODE_ENV === 'development'`. Status: ✅ 9/10. 🐛 hydration warning (inline `caret-color` style on the dev input).

**`/(app)/home`** (`home/page.tsx`, 249) — Hero + 4-tile stats + observations card + recent activity card + 4-domain grid with sparklines. 🎨 **All visible data is static mock**:
- `observations` array hardcoded with "Raft / Paxos / Spanner" content
- `recent` array hardcoded with 6 fake events
- `domainsMock` and `sparks` hardcoded
- The `openInboxCount` constant is `4` not from DB

To wire real data: the API routes `/api/activities`, `/api/inbox` (count), `/api/stats`, `/api/domains` all exist. Just needs an RSC fetch and the mocks deleted. **Status**: 🎨 9/10 visual / 🚧 ~25% data flow.

**`/(app)/add`** (`add/page.tsx` + `UnifiedInput.tsx` + `CompileQueue.tsx` + `RecentlyCompiled.tsx`, 142 page lines). RSC fetches initial pending/running memos and the 8 most-recently-compiled, hydrates the client components.
- `UnifiedInput`: 4 chips (URL / File / Voice / Bookmarklet) + auto-grow textarea + drag-drop drop zone + save-draft localStorage. Real `POST /api/memos` via React Query mutation; URL detection via `/^https?:\/\//`. ✅
- `CompileQueue`: subscribes to `GET /api/stream/compile` SSE; renders status badges + `compile_step`. ✅
- `RecentlyCompiled`: SSR-hydrated list with linkified target. ✅
- 🚧 Voice chip is disabled (visual only). File-drop attaches the filename to the body but **does not upload the file**.

**Status**: 🎨 9/10 visual + ✅ memo create + ✅ SSE queue / 🚧 file uploads, voice.

**`/(app)/chat`** (`chat/page.tsx`, 174) — thread list sidebar + empty state main panel. RSC fetches up to 50 threads. ✅

**`/(app)/chat/[id]`** (`chat/[id]/page.tsx` + `ChatView.tsx`). RSC fetches thread + messages + side thread list. Client `ChatView` POSTs to `/api/chat/threads/[id]/messages` and renders the SSE stream. Citations are stored on `chat_messages.citations` (Citation[]). Right cite-rail rendering exists but data flow polish is uneven on edge cases. ✅ mainly.

**`/(app)/wiki`** (`wiki/page.tsx`, 142 + `WikiNav.tsx`) — three-column layout, 4-group nav (concept / entity / synthesis / source / daily) via `WikiNav`. Empty state when `pages.length === 0` invites user to add first memo or draft via chat. Supports `?id=<uuid>` redirect to `/wiki/<slug>`. ✅

**`/(app)/wiki/[slug]`** (`wiki/[slug]/page.tsx` + `AnnotationLayer.tsx`). Server-side fetches page row, page_sources (joined with memos), page_links (backlinks joined with from_page), annotations, domain label. Renders Markdown via `react-markdown` + `remark-gfm` + `rehype-sanitize`. Annotations overlay via client component. Status: ✅ ~80% complete.

**`/(app)/inbox`** (`inbox/page.tsx` + `InboxClient.tsx`, 90 + client). RSC fetches up to 100 open items + per-kind counts. Client view groups by 4 kinds; resolve/dismiss/snooze actions hit the corresponding `/api/inbox/[id]/...` routes. Status: ✅ ~85%.

**`/(app)/domain/[slug]`** (`domain/[slug]/page.tsx` + `DomainClientView.tsx`). Lists pages in the domain, grouped by type (concept → entity → synthesis → source → daily) with badges and relative timestamps. Stats card with this-week deltas. Status: ✅ ~80%.

**`/_design-demo`** — internal preview of design primitives. Dev only.

### 2.6 Design system (`web/src/components/ui/`)

| Component | Variants | Used by |
|---|---|---|
| `Btn` | 4 kinds (primary/soft/ghost/secondary) × 2 sizes (sm/md) × pill flag, optional `icon`, `iconRight` | Everywhere |
| `Chip` | 6 tones (accent / muted / success / warn / danger / neutral) + interactive flag | Inbox kind badges, Home observation header |
| `Card` | regular + sunken modifier | Home, Add, Inbox |
| `Icon` | wraps lucide-react `as={...}` with sized stroke | Everywhere |
| `SectionLabel` | uppercase tracking-wide label with right slot | All pages |
| `Sparkline` | inline SVG, color + fill props | Home domains grid |

App-shell components in `(app)/_components/`:
- `NavItem` + `NavItemLink` — sidebar entry with icon, badge, meta hint, active state via `usePathname`.
- `SystemRow` — bottom sidebar rows (Settings, account, sign-out).
- `TopbarDate` — client component showing `Sat 11 May` formatted via `Intl.DateTimeFormat`.

### 2.7 Global CSS (`web/src/app/globals.css`, 753 lines)

Sections (search for `=== `):
- Design tokens (CSS vars: `--accent`, `--accent-hover`, `--accent-border`, `--accent-soft`, `--bg-warm`, `--surface-white`, `--surface-sunken`, `--fg-primary`, `--fg-muted`, `--fg-subtle`, `--success`, etc.)
- `ds-*` typography classes (`ds-h1`, `ds-body-md`, `ds-body-sm`, `ds-section-label`, `ds-caption`, `ds-mono-11`)
- Surface-specific blocks: Wiki, Add, Inbox, Chat, Sidebar, Empty card, Focus-visible, Hover polish

### 2.8 Cross-cutting libs

- `lib/ai/dashscope.ts` — OpenAI-compatible client, default model `qwen-plus`, embedding model TBD; auto-logs prompts to `prompt_log`.
- `lib/ai/embed-utils.ts` — `chunkText`, `averageEmbeddings`, `hashText` (SHA-256).
- `lib/ai/rag.ts` — `retrievePages(userId, query)` for the chat endpoint.
- `lib/ai/provider.ts` — `ProviderError` discriminated union for retry logic.
- `lib/ratelimit.ts` — `checkMutationRateLimit(email)` backed by `@upstash/redis` in prod, no-op in dev (per Round-10 notes).
- `lib/inngest/client.ts` — Inngest singleton.
- `lib/schemas/memo.ts` + `lib/schemas/attachment.ts` — Zod validation for the API routes.
- `lib/db/client.ts` — Drizzle Postgres client.

### 2.9 Web known issues / TODO (aggregated from PR #265's R10)

1. 🐛 **`/login` hydration warning** — inline `caret-color` style on dev input; needs to move to CSS class.
2. 🎨 **`/home` mock data** — 100% mock; data flow not wired.
3. ❌ **`/settings/domains` doesn't exist** — the "+ New domain" link in the sidebar 404s.
4. 🚧 **Mobile layout** — sidebar is fixed 248px; no responsive collapse.
5. 🚧 **Voice chip** on `/add` is disabled — no recorder yet.
6. 🚧 **File drop** on `/add` only appends filename to body — does not upload to storage.
7. 🚧 **TypeScript errors** — ~23 pre-existing tsc errors (test mocking, drizzle types, `@upstash/redis` types). Build passes via Next's lenient mode.
8. ⚠️ **pgvector migration unapplied** — `0006_pgvector_hnsw.sql` exists but is missing from the journal. All similarity search is JS-side cosine on JSON-encoded vectors. Performance ceiling reached at ~1k pages per user.
9. 🚧 **Chat citations side rail** — data is persisted but the right-rail empty/loading state is uneven.
10. ⚠️ **Wiki content generation** — pages get created by `compile-memo` (FULL mode). Empty users see the empty state; until they post FULL-mode memos the wiki stays empty. There's no manual "create page" UI.
11. ⚠️ **`/api/stream/compile` is poll-based** — DB query every 2s per connected client. Fine for one user, expensive at scale.
12. ⚠️ Pre-commit migration `web/src/middleware.ts → web/src/proxy.ts` rename in working tree — the next.js v16 router-handler conventions have shifted (per `web/AGENTS.md`: "This is NOT the Next.js you know").

---

## 3. Cross-product status

### 3.1 Data flow today
Zero. iOS reads/writes a file vault; web reads/writes Postgres. The `memos` table has an `origin` enum including `ios` and a `vault_path` text column suggesting eventual ingestion, but nothing on the iOS side currently POSTs to `/api/memos`.

### 3.2 What the PRD (commit 7058173 — "V5 Codex blueprint") wants
A shared substrate where iOS captures into the same Postgres, the AI compile pipeline runs server-side (Inngest), and both clients re-render from the same `pages`/`memos`/`inbox_items` rows. The web schema is already provisioned for this: `origin: ios`, `devices.platform: ios`, `sync_state` table with `(user_id, device_id)` cursor.

The gap to close:
- iOS needs an "online mode" that mirrors raw memo writes to `POST /api/memos` with `origin: ios` after the local vault write succeeds.
- iOS needs to subscribe to `/api/stream/compile` (or replacement) to learn when compile completes server-side, then read back the daily page / wiki updates.
- The DeepSeek pipeline in iOS becomes optional — local-only fallback for offline use.

---

## 4. Tech stack one-pager

### 4.1 iOS
- Swift 5, SwiftUI, iOS 16.0+, Xcode 16+
- Apple SDKs only: AVFoundation, PhotosUI, CoreLocation, BackgroundTasks, UserNotifications, WatchConnectivity, CryptoKit
- Third-party (linked, not SPM): Supabase Swift, Sentry
- AI: DeepSeek `deepseek-v4-pro` (chat), OpenAI Whisper `whisper-1` (voice)
- Storage: Files in app sandbox or iCloud ubiquity container

### 4.2 Web
- Next.js 16.x (Turbopack), React 19.2, TypeScript
- Drizzle ORM, Supabase Postgres, pgvector (extension installed, schema migration pending)
- NextAuth v5 + `@auth/drizzle-adapter`
- Inngest (4 functions), `@upstash/redis` (rate limit, prod-only)
- TanStack Query (client mutations + cache), react-markdown / remark-gfm / rehype-sanitize
- lucide-react icons, Tailwind utility classes mixed with CSS variables
- AI: DashScope `qwen-plus`

### 4.3 Tooling
- pnpm workspaces (`pnpm-workspace.yaml` points to `web`); root has its own `package.json` for shared dev tooling
- Supabase CLI (`supabase/config.toml`)
- gh CLI with extensions (`copilot`, `stack`, `dash`, `branch`, `pr-review`, `fzf`)
- Fastlane for iOS shipping (`fastlane/`)
- xcodebuild with default simulator iPhone 17

---

## 5. Recommended next steps (ranked by user-perceptible impact / effort)

1. **Wire `/home` to real data** (S, high impact). The visuals are 9/10; users will notice the disconnect immediately. RSC fetch from `/api/activities` + `/api/stats` + `/api/inbox` (count) + `/api/domains` already exists.
2. **Fix `/login` hydration warning** (XS, low impact, easy win). Move inline `caret-color` to a CSS class.
3. **Implement `/settings/domains`** or remove the broken sidebar link (S). The "+ New domain" entry currently 404s.
4. **Apply pgvector migration** + index `pages.embedding` (M, perf-critical at scale). Currently kNN runs as JS cosine; will not scale past ~1k pages/user.
5. **Real file upload on `/add`** (M, frequently asked-for). Wire drop zone + file chip to a Supabase Storage POST + create `memo_attachments` rows.
6. **Voice chip on `/add`** (M). Use MediaRecorder → POST to a new `/api/voice/transcribe` route (server-side Whisper or DashScope ASR).
7. **Update CLAUDE.md** to reflect reality (XS): DeepSeek not DashScope on iOS, Graph is not an 18-line placeholder, file split caveats.
8. **iOS ↔ Web bridge phase 1** (L, the PRD's headline feature). Mirror iOS memo writes to `POST /api/memos` with `origin: ios`. Read-only first — server doesn't push down yet.
9. **Mobile responsive sidebar** on web (M).
10. **Replace SSE poll with Inngest event subscription** (M, perf). Use Inngest's realtime channel or Supabase Realtime instead of 2s polling.
11. **Annotate the Chat right-rail loading/empty states** (S).
12. **Split `TodayView.swift` / `DailyPageView.swift`** to land under the 800-line cap (M, code-health, no user impact).
13. **Add a real DayPageTests target** in the Xcode project (M). The `DayPageTests/` folder exists but the target wiring should be confirmed/created.
14. **Fix the 23 tsc errors** (M). Drizzle types and `@upstash/redis` types are the bulk.

---

## 6. Appendix

### 6.1 Key file paths

iOS:
- `DayPage/App/DayPageApp.swift` — app bootstrap
- `DayPage/App/RootView.swift` — top-level auth/onboarding gate
- `DayPage/Models/Memo.swift` — model + YAML serializer
- `DayPage/Storage/RawStorage.swift` — atomic file persistence
- `DayPage/Services/CompilationService.swift` — DeepSeek compile pipeline
- `DayPage/Services/BackgroundCompilationService.swift` — BGAppRefreshTask
- `DayPage/Services/EntityPageService.swift` — entity page CRUD
- `DayPage/Services/AuthService.swift` — Supabase Auth
- `DayPage/Features/Today/TodayView.swift` + `TodayViewModel.swift`
- `DayPage/Features/Daily/DailyPageView.swift`
- `DayPage/Features/Archive/ArchiveView.swift`
- `DayPage/Features/Graph/GraphView.swift` (309 lines, not the 18-line placeholder CLAUDE.md mentions)

Web:
- `web/src/auth.ts` — NextAuth config
- `web/src/lib/db/schema.ts` — Drizzle schema (19 tables)
- `web/drizzle/migrations/*.sql` — 8 applied + 1 unapplied (`0006_pgvector_hnsw.sql`)
- `web/src/app/(app)/layout.tsx` — sidebar shell with RSC data fetch
- `web/src/app/(app)/home/page.tsx` — 100% mock data home
- `web/src/app/(app)/add/page.tsx` + sibling client components
- `web/src/app/(app)/wiki/[slug]/page.tsx`
- `web/src/app/(app)/inbox/page.tsx`
- `web/src/app/(app)/chat/[id]/page.tsx`
- `web/src/app/api/chat/threads/[id]/messages/route.ts` — SSE chat stream
- `web/src/app/api/stream/compile/route.ts` — SSE compile progress
- `web/src/lib/inngest/functions/compile-memo.ts` — LIGHT/FULL compile pipeline
- `web/src/lib/inngest/functions/daily-page.ts`
- `web/src/lib/inngest/functions/schema-detect.ts`
- `web/src/lib/inngest/functions/orphan-detect.ts`
- `web/src/app/globals.css` (753 lines) — design tokens + per-surface styles

### 6.2 Screenshots (PR #265, R10)

Archived at `docs/screenshots/v5-codex/`:
- `00-login.png`
- `01-home.png`, `01a-home-viewport.png`
- `02-sidebar.png`
- `03-add.png`, `03a-add-input.png`, `03b-add-dragging.png`
- `04-wiki.png`
- `05-inbox.png`, `05a-inbox-hover.png`
- `06-chat.png`
- `07-focus.png` (focus-visible audit)

### 6.3 Commands

Web dev:
```
pnpm install
pnpm --filter web dev   # turbopack dev server
pnpm --filter web build
pnpm --filter web drizzle-kit generate
pnpm --filter web drizzle-kit migrate
```

iOS dev:
```
xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build
open -a Simulator &
```

### 6.4 PR history (last 10)

- `90e3b1e` feat(add): redesign capture flow + hover/focus polish + archive screenshots
- `6cd32f0` feat(design): apply Codex design system across all surfaces
- `bd49117` feat(routing): fix RSC crash on /chat, build /home, finalize slug migration
- `273b41f` chore(dev): unblock dev environment for e2e + add dev login bypass
- `f368e2e` feat: V5 Codex Web — 50/50 stories complete (#264)
- `7058173` docs(prd): V5 Codex blueprint — cross-device AI knowledge system terminal form
- `1697f46` fix(memo): auto-embed GPS location + fix voice card scroll blocking
- `74e71f1` feat(daily): thread reply + freeform input for compiled pages
- `9549508` fix(swipe): allow drag-to-close while delete panel is revealed (#260)
- `22e2fc4` fix(swipe): restore close gesture + rubber-band spring polish

---

*End of inventory. Total scan: 19 Drizzle tables, 26 web API routes, 4 Inngest functions, 10 web page routes, 26 iOS services, 11 iOS feature areas, ~18k LOC sampled across iOS Features+App, ~10k LOC across web src/app+src/lib.*
