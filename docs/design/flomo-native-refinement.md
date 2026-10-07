# Flomo-native DayPage refinement — design & acceptance

Status: implementation verified; release candidate tracked by #925. This document records the
design, the acceptance mapping, the **explicit current limits**, and the verification
commands for this user-requested native refinement. It is not an architecture decision
(no storage/auth/sync/schema change is involved); related tracking context is #332
(design-system convergence), #816 (gestures/motion) and #327 (native chat/inbox). This scoped delivery and TestFlight update are tracked by #925.

Scope of the change: Today's swipe drawer + memo row, the memo-anchored chat sheet,
the sidebar first screen, Archive, Search, and the shared insight-strategy helpers in
`DayPageKit`. No vault format, storage, auth, sync, project-file or dependency change.

## 1. Design

### 1.1 Swipe drawer (`SwipeableMemoCard`)

- RIGHT swipe reveals two actions with complete localized labels: **洞察** (quiet
  accent — deep `accentAmber`, not the loud primary amber) and **相关记录**
  (neutral). LEFT keeps share + delete. `SwipeAction.Tone` gained `.accentQuiet`.
- A RIGHT **full swipe** commits the outermost action = insight. That action only
  opens the insight chooser sheet; it never calls an AI backend and never persists
  anything. `SwipeableMemoCard.commitActionKind(for:)` encodes the mapping
  (trailing → `.share`, leading → `.insight`) and is contract-tested.
- Gesture model unchanged: UIKit `HorizontalPanGesture` arbitration (horizontal
  follows the finger, vertical scrolling untouched), one drawer open at a time via
  `.memoCardDidBeginSwipe`, selection mode disables gestures and force-closes panels,
  Reduce Motion keeps the guarded fallback curves, all thresholds/widths in
  `SwipePhysics` untouched (panel 2×76 pt, commit 236 pt …). Action columns keep
  ≥44 pt hit targets; labels now wrap to two centered lines so the English
  "Related records" stays complete inside the 76 pt column.
- Pin / more stay reachable in the row's long-press menu (which gained a "更多操作"
  entry into the existing confirmation dialog) and in the dialog itself; the card's
  VoiceOver action list keeps share/pin/more/delete and gains insight + related.

### 1.2 Memo-anchored chat (`MemoChatView`, `TimelineRow`)

- `TimelineRow` (the memo row wrapper) hosts the sheet: `onInsight`/`onRelated`
  callbacks on `SwipeableMemoCard` open `MemoChatView` via `.sheet(item:)` anchored
  to the exact memo (entity display names are derived from wiki frontmatter when
  resolvable, otherwise an empty dictionary). Every TimelineRow surface (Today,
  Archive raw, Daily) gets the same anchored chat.
- `MemoChatEntryMode`: `.insight` expands the lens chooser and leaves the keyboard
  down; `.related(question:)` prefills a suggested question into the input and is
  **never auto-submitted** (no fabricated results, no silent cloud calls).
- Empty conversation shows a compact expandable **洞察视角** selector: 3 stable
  builtins (重复模式 / 挑战假设 / 下一个小步骤) plus create / edit / delete for
  custom strategies, and one explicit **开始洞察** button. Selecting, creating,
  editing or deleting a lens is a pure local preference operation.
- Free chat, streaming status, source chips, cancel-by-dismissal and retry flows are
  preserved. In-flight asks/retries/insight runs hold a `Task` handle that is
  cancelled on close / `onDisappear`.
- `.insight` does not resume today's existing session (old turns would hide the
  chooser); the session remains reachable in the chat river. Ordinary free chat keeps
  the `--continue` resume behavior.

### 1.3 Insight strategies (`DayPageKit/Sources/DayPageServices/InsightStrategy.swift`)

- `InsightStrategy` (stable builtin IDs `builtin.patterns`,
  `builtin.challenge-assumption`, `builtin.next-small-step`; custom = title +
  instructions), `InsightStrategyDraft.validated` (trim, reject empty, cap 40 / 600
  chars) and `InsightStrategyStore` (injected `UserDefaults`, keys
  `insight.customStrategies.v1` + `insight.selectedStrategyID.v1`, JSON of
  title/instructions only). Deleting the selected strategy (or a dangling stored ID)
  resets the selection to the first builtin and persists the repair.
- Strategy defaults store **only** titles/instructions/selection ID — never memo
  contents, evidence or credentials. No vault/schema change.
- A strategy is composed into the **user** question (`composedInstruction()` →
  `MemoryChatService.ask(insight:)`) — never into the system prompt, so it cannot
  override evidence/privacy rules.

### 1.4 Bounded evidence + bounded retrieval (`MemoryChatService`)

- `systemPrompt` now appends `boundedEvidenceRule`: observation → dated evidence →
  tentative interpretation **plus a plausible alternative** → one small
  experiment/question; no summary-only or flattering answers; no diagnosis; no
  unsupported "repeated pattern" claims; insufficient evidence must be admitted;
  facts and inference stay separated; a user lens cannot override these rules.
- Retrieval query is separated from the analysis question: retrieval is exact folded
  keyword matching (GraphRetriever → SearchService), **not** semantic search, so long
  strategy prompts never become retrieval queries. `ask(_:retrievalQuery:)` keeps the
  old default (question as query); `ask(insight:)` derives a bounded topic (≤40 chars
  from one entity clue or a locally tagged body noun, entity seeds passed separately) and
  `retryLast()` reuses the exact query of the first run. The insight/related sheet exposes a ≤40-character keyword field; bounded noun extraction runs off the main actor, and entity names are resolved once in a retained row-opening task. When nothing matches, the
  evidence rule requires saying so instead of fabricating relationships.
- Cancellation: reject already-cancelled requests before appending a turn; checks after every paced sleep and immediately before the LLM call;
  cancelled runs leave no hidden error message and never append or persist assistant
  output; a run-generation guard stops a superseded run's late streaming chunks or
  completion from mutating newer state. Reset/resume invalidates the generation; an old completion cannot clear the newer responding state or persist into the new session.

### 1.5 Sidebar (`SidebarView`)

- Calm first screen: identity row (single sync action) → Today / Archive / Graph →
  「和过去对话」. The duplicate sidebar search row is removed (Search lives in the
  Today/Archive headers and the existing deep links).
- Activity heatmap + recent days live in ONE collapsed **记录足迹** disclosure below
  primary navigation (default closed, persisted, VoiceOver toggle state).
- Action center + schedule live in ONE collapsed **工具** disclosure (default
  closed); the collapsed row keeps the upcoming-reminder count badge and the action
  center (approvals) stays one tap inside — nothing is hidden irretrievably. No live
  approval count is claimed (the current model does not inject one).
- Feedback stays in the footer, settings stays a direct footer row. The decorative
  all-caps "REVIEW" pill is gone; the previously hardcoded Chinese labels became
  localized keys (locale parity). All rows keep ≥44 pt targets. A cancellable task keyed to sidebar visibility covers first insertion and delays the background scan until the opening transition settles.

### 1.6 Archive (`ArchiveView`)

- Default mode is the list; the chosen mode persists via `@AppStorage("archive.viewMode")`.
  The toggle labels are localized (记录 / 日历; List / Calendar) — no CAL/LIST.
- Truthfulness: the list is **month-scoped** — month navigation stays, the current
  month is shown, and no global-timeline claim is made (the pre-scanned index is not
  used to synthesize full-history rows).
- One concise month header (days · entries · photos · voice · places) replaces the
  duplicated digest pillars and the per-month digest card; the export overflow menu
  stays. Ledger rows got readable 2-line dynamic serif excerpts with equal inkPrimary weight for raw/compiled content, bounded accessibility excerpts, plus a quiet metadata line
  (photos / places / voice minutes) and no decorative card stack.
- Calendar lightened: the tinted enclosing glass panel is removed; day tiles are
  fixed 48 pt tall (even 7-column geometry; width depends on viewport and is not guaranteed ≥44pt at 320pt) instead of huge squares, and
  empty future days use a whisper fill. Today / compiled / raw / empty distinctions
  and their VoiceOver labels are unchanged; loading, empty month, filters and the
  date jump keep working. Month animations (buttons, swipe, picker) are now Reduce
  Motion guarded.

### 1.7 Search (`SearchView`)

- Search stays in Today/Archive headers and deep links. Cancelling a Today-launched search returns to Today; selecting a result opens the true memo in Archive.
- Filter affordance shows the active filter count and keeps the expandable advanced
  panel (date range / type / place). Counts represent active dimensions, not both endpoints or each selected type separately. Quick scopes have an upper bound at today so future entries are excluded. The empty-query state shows recents, quick date
  scopes (今天 / 本周 / 本月) and memo-type toggles — all writing into the existing
  `SearchFilters` — plus frequent entities, laid out as wrapped rows instead of
  competing horizontal rails. Recent-search persistence is untouched.
- Result source semantics are untouched (raw memo bodies, voice attachment
  transcripts, location names, date strings, exact filter semantics, 100-hit cap).
  The empty-state hint now names voice transcripts and claims nothing more.

## 2. Acceptance mapping

| # | Acceptance | Where implemented | Covered by |
| --- | --- | --- | --- |
| 1 | Swipe right = 洞察 / 相关记录, full-swipe opens chooser only | `SwipeableMemoCard.swift`, `TodayViewComponents.swift` | `SwipePolishContractTests` (commit mapping, ≥44 pt columns) |
| 2 | Insight mode + strategy store + bounded evidence | `MemoChatView.swift`, `InsightStrategy.swift`, `MemoryChatService.swift` | `InsightStrategyTests`, `MemoryChatInsightTests` |
| 3 | Sidebar calm first screen | `SidebarView.swift` | localization parity check; visual pass parent-owned |
| 4 | Archive list default / truthful / lightened calendar | `ArchiveView.swift` | visual pass parent-owned |
| 5 | Search audit + honest scope + density | `SearchView.swift`, `SearchService.swift` (doc comment) | `SearchServiceCorrectnessTests` |
| 6 | en/zh-Hans parity, iOS 16, DS tokens, docs | `Localizable.strings`, this doc | `plutil -lint` + key parity script |

## 3. Explicit current limits

- **Search scope**: raw memo bodies, voice attachment transcripts (both the scanner
  and the indexed fast path), location names and date strings. **Compiled daily page
  bodies are not searched** — compilation state is only reported as a badge on hits.
  There is no semantic search, no photo OCR, and no remote/backend search.
- **Retrieval for insight/related** is exact keyword matching over a short derived
  topic (≤40 chars) plus entity seeds — not semantic retrieval. When the bounded
  query finds nothing, the required behavior is to state insufficient evidence, not
  to invent relationships.
- **Archive list is month-scoped** (month navigation + current month). It is not a
  global all-history timeline.
- **Sidebar 工具** surfaces the schedule count only; live approval counts are not
  claimed because the current model does not inject them (the action center remains
  one tap away inside the disclosure).
- **Insight lenses** are local preferences (title + instructions in `UserDefaults`).
  They carry no memo text and are sent only when the user taps 开始洞察.
- **Verification at integration**: 37 focused host XCTest cases passed (0 failures), including real GraphRetriever/SearchService historical keyword matching, selected-strategy persistence/fallback, and cancellation/reset races. The final native build-for-testing succeeded and 154 targeted simulator tests passed with no failures or skips. UI verification covered Chinese/English, dark mode, accessibility-large, strategy CRUD, search/filter recovery and month/day navigation on Primary iPhone. Physical drag was not reliably automated: drawer screenshots use an exact-memo DEBUG local-QA preview, followed by actual button interaction. No real-model or true-device smoothness claim is made. DayPage Figma was unavailable.

## 4. Verification commands

Run from the repository root:

```sh
# whitespace / conflict-marker check
git diff --check

# host package tests for the touched services (fake LLM + fake retrieval,
# private temp vaults; no provider traffic)
swift test --package-path DayPageKit \
  --scratch-path <task-scratch>/KitBuild \
  --filter "Insight|MemoryChat|SearchService|GraphRetriever"

# strings syntax + en/zh-Hans key parity
plutil -lint DayPage/Resources/en.lproj/Localizable.strings \
             DayPage/Resources/zh-Hans.lproj/Localizable.strings
```

Completed integration gates: `DayPage` build-for-testing and targeted `DayPageTests` test-without-building (154 cases). The final test result bundle and screenshot evidence are kept in the local delivery report, not in the repository. Reduce Motion guards were inspected, not toggled in the live simulator.

## 5. Files changed

- `DayPage/App/AppNavigationModel.swift`, `DayPage/Features/Today/TodayView.swift`, `DayPageTests/AppIntentsTests.swift` — global search origin/cancel/result navigation.
- `DayPageKit/Sources/DayPageModels/MemoMarkdown.swift`, `DayPageKit/Sources/DayPageServices/GraphRetriever.swift` — read-only transcript-aware preview, retrieval snippets and deduplication for voice-only anchors.
- `DayPage/App/SidebarView.swift` — disclosures 记录足迹 / 工具, search row removed,
  localized labels, no REVIEW pill.
- `DayPage/Features/Today/SwipeableMemoCard.swift` — insight/related drawer actions,
  quiet accent tone, a11y actions, label wrapping, commit mapping helper.
- `DayPage/Features/Today/TodayViewComponents.swift` — `TimelineRow` hosts the
  anchored chat sheet, related-question derivation, 更多操作 menu entry.
- `DayPage/Features/Ask/MemoChatView.swift` — entry modes, 洞察视角 chooser,
  strategy editor, retained/cancelled chat task.
- `DayPage/Features/Archive/ArchiveView.swift` — list default + preference,
  localized mode toggle, single month header stats, lightened calendar, Reduce
  Motion guards, ledger row excerpts/metadata.
- `DayPage/Features/Archive/SearchView.swift` — filter count, quick scopes, wrapped
  chip layouts, honest empty-state hint.
- `DayPageKit/Sources/DayPageServices/InsightStrategy.swift` (new),
  `MemoryChatService.swift` (bounded evidence rule, bounded retrieval query,
  cancellation + run generation), `SearchService.swift` (truthful scope comment).
- `DayPageKit/Tests/DayPageServicesTests/InsightStrategyTests.swift`,
  `MemoryChatInsightTests.swift`, `SearchServiceCorrectnessTests.swift` (new).
- `DayPageTests/SwipePolishContractTests.swift` — updated full-swipe contract +
  action-plan/width tests (executed by the parent's native test gate).
- `DayPage/Resources/en.lproj/Localizable.strings`,
  `DayPage/Resources/zh-Hans.lproj/Localizable.strings` — matching keys for all of
  the above.
