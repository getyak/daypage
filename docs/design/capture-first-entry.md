# Capture-first entry

Scope: [GET-255](https://linear.app/getyak/issue/GET-255), tracked in
[GitHub #935](https://github.com/getyak/daypage/issues/935).

The capture surface starts with an invitation, a large writing area or an explicit
writing action, and voice only where a working implementation exists. Queue counts,
weather, streaks and compiled-page totals do not lead the screen. Formatting is a
secondary action. Journal and knowledge content require an explicit organization
action; raw notes, drafts and recovery states keep their existing owners.

## Platform boundaries

| Surface | Capture | Organization and recovery |
| --- | --- | --- |
| iOS Today | `写下来` opens the existing WriteSheet; `说一段` starts the existing native recorder. Both actions use the existing draft and recording owners. The layout can stack at large text sizes. | `查看整理` reveals the existing summary, daily page and history. Offline, storage/submit errors, sync conflicts and retry stay outside the organization gate. Upcoming reminders remain visible. |
| macOS Today | The existing text editor is larger. Working formatting commands live in `更多格式`; unfinished attachment/mention controls are omitted. | Save/refresh handlers are unchanged. Errors wrap rather than truncating to one line. Archive remains in the sidebar. App-managed voice is not implemented here. |
| Android Today | A quiet heading, larger multiline text field and the existing local save action. The sync status follows capture. | Vault/Room/save contracts and recent-note access are unchanged. There is no app-managed voice implementation in this client. |
| Web `/add` | A large editor and visible browser speech control. Unsupported speech and permission failures explain the recovery path; completed speech results append once. Formatting stays under more options. | Pending capture remains below the editor; recently compiled content is in a closed disclosure. Failed saves keep the draft and retry. |
| Mobile Web `/today` | Reuses the same actual Composer as `/add`, including its draft, speech and save behavior. The former timer-only recording sheet is no longer reachable from this page. | A successful capture refreshes the raw feed. Journal/knowledge content is linked explicitly; the summary, weekly spine and unlock dashboard are absent from Today. |

## Web account boundary

The site permission policy permits microphone use on this origin only, subject to
the browser's user permission. Camera, location and third-party microphone access
remain denied. Speech availability still depends on browser/provider support.

The capture endpoints (`POST /api/memos`, `GET /api/today/memos`) still use the
existing legacy Drizzle database and email-to-user lookup. The account-scoped
`/memos` reading surface uses the paired Supabase realm. This visual change does
not migrate capture between them or change the existing post-login destination.
Do not claim shared-account capture or cross-client data parity from UI fixtures.
Real capture acceptance must verify the active account and configured capture
database first; see [shared account reading](../operations/shared-web-account-reading.md).

## Verification contract

- Inspect a cold empty capture screen and a populated raw inbox. Confirm that
  writing and supported voice are immediately identifiable, and that organized
  content remains reachable through its explicit action.
- Exercise keyboard/focus, recovered drafts, narrow width, large text and reduced
  motion. Failed saves and denied microphone access must leave writing usable.
- iOS changes require the running app on the shared allowlisted Simulator through
  `dev-ios-session`. Android and macOS require their applicable compilation gates.
- Web browser fixtures can verify component layout, speech lifecycle and draft /
  retry behavior using synthetic responses. They do not verify account identity,
  durable backend writes, provider transcription or deployment.
- Run the hydration regression and updated `/add` design contracts. E2E uses
  explicitly supplied `DAYPAGE_E2E_EMAIL` / `DAYPAGE_E2E_PASSWORD` in the configured
  realm, without printing credentials or capturing private notes.

The direction is informed by Day One's
[Menu Bar Quick Entry](https://dayoneapp.com/guides/day-one-for-mac/menu-bar-quick-entry/)
and Apple's [text input guidance](https://developer.apple.com/design/human-interface-guidelines/text-fields).
These references guide hierarchy; they do not establish feature parity.

## Quiet Web capture and reading (GET-285)

`/add` and `/today` hide the permanent sidebar and repeated topbar actions.
Navigation remains available through the navigation drawer at every viewport.
The capture editor stays flat on focus and occupies at least half the viewport;
voice, more input options, save feedback and retry remain with the Composer.
Opening New domain from the drawer uses a separate modal focus boundary and
returns focus to its trigger when closed.

Wiki pages use a readable single column. Browse pages, Page options, and Sources
and backlinks disclose supporting controls and provenance on request. The graph
remains an optional view, includes a native page selector for keyboard use, and
offers retry after a failed request. Selecting a page preserves the graph layout;
reduced motion stops the force animation while keeping selection and drag usable.

Project-scoped Impeccable guidance is installed under `.cursor/skills/impeccable/`;
`web/PRODUCT.md` records the product constraints. Run its detector on the touched
capture, chrome and Wiki files when refining those surfaces. A clean detector is
only a mechanical gate; rendered interaction and responsive checks are required.
