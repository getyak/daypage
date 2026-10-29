# DayPage local notebook

Owner: GET-326. User request: archive the existing edition, simplify DayPage to local recording with personal AI configuration and note chat, keep only Archive / Feedback / Settings in the sidebar, refine the design with Figma, and push the result.

## Scope and decisions

The user confirmed iOS first. Implement iOS 16+ native SwiftUI; Web, Android, macOS, Watch and other surfaces remain outside this refactor. The existing cloud edition is preserved at commit `4cb0fced8265809648f1b0d952b86bc8a111b8c7` with a source-only GitHub archive release; this is not a new TestFlight binary. The repository itself stays writable. Historical worktrees and live services/databases are outside this task.

The new app has no login, backend, telemetry, hosted database, local database, automatic AI requests, graph, compilation, scheduling, or agent dashboard. Notes are ordinary files at the existing Documents/vault/raw/YYYY-MM-DD.md location. Existing assets stay at raw/assets. Existing raw files are never rewritten on launch. Shared core code uses Apple's Foundation, Security and CryptoKit, without external dependencies. The active project is DayPageLocal/DayPageLocal.xcodeproj; the original multi-client project stays unchanged so the iOS build cannot inherit the other clients' cloud package resolution.

## Approaches

1. Incrementally detach the existing cloud runtime: lower initial UI churn, but leaves a large dependency surface and many unnecessary startup side effects.
2. A small shared local core and a new native app entry: explicit file and network boundaries, fewer dependencies, easier to audit. This is the implementation choice for the user's requested simplification and fast delivery.
3. A separate repository: requires a new repository identity the user has not supplied, and fragments recovery history. No new repository is created here.

## Interaction and design

Archive is the launch screen. A prominent write action opens a draft editor; no account or AI setup is required to save. Search is local. A note detail shows the original content and local attachments. Chat can start from one note or from the archive; its context scope and selected model are visible before sending. Feedback opens a user-initiated local draft or external issue link without an app account. Settings contains AI connection, appearance and file/export information.

The sidebar contains exactly Archive, Feedback, Settings. A warm dark spine surface, subtle lighting, a quiet wordmark, a clearly bounded selected row and generous empty space replace the account/tools groups. Content remains warm paper with readable serif prose and native system control typography. Light/dark colors, Dynamic Type, Reduce Motion/Transparency, 44-point controls and keyboard actions are required. The existing Figma file is el5wnKFHTBcgln16ktEztU; new scoped frames must preserve older screens.

## File and AI boundaries

Retain the existing Memo YAML/Markdown model and both modern and legacy separators. Appends preserve existing bytes; edits retain untargeted records and unknown metadata, and reject duplicate IDs. Invalid blocks must remain intact and mutations must fail safely if they cannot identify the target. No automatic migration or deletion of original files. File operations are serialized and atomic. Tests use isolated temporary vaults. New builds use an isolated QA bundle for Simulator acceptance. Preserve original native bundle IDs. Some old installations store their Vault only in iCloud: provide an explicit folder import that copies the complete chosen Vault to a separate local namespace, leaves originals intact, avoids collisions with local notes, and fails without publishing a partial import when assets are unavailable. No automatic iCloud-to-local migration.

AI settings accept an OpenAI-compatible base URL, model, and optional API key. The key lives in a device-only Keychain item bound to the normalized service origin; changing services cannot reuse a key silently. No key appears in preferences, source, logs or chat files. HTTPS is required for non-local endpoints; local/LAN HTTP is explicit. Reject embedded credentials, query strings and fragments. Reject all redirects. Only an explicit send/test action may contact the configured endpoint. Settings explain that selected note text is sent to that endpoint; a local model can use a blank key. Requests have timeouts, bounded context/history and cancellation. Provider response bodies never become diagnostic logs. Treat note content as untrusted quoted context, never instructions; the chat transport has no tools or file/network capabilities beyond this one request.

Conversations and drafts are local files. Note context is selected in memory from local files, bounded in count and characters; no vector database or cloud search. Sending is disabled until configuration is valid. AI failure retains the user's question and leaves notes unchanged.

## Verification and recovery

Characterize original Memo serialization and both separators, then test concurrent appends, byte-preserving reads, unknown metadata, malformed records, safe editing, paths, context bounds, endpoint validation, request headers/redirects and restart persistence. Run the full new core suite on the host, build the iOS target, exercise first launch, save/relaunch/search, sidebar destinations, AI setup and mocked chat in Simulator, inspect dark and accessibility layouts, and obtain independent review. Push a scoped branch and an issue-linked PR. No production AI call, database deletion or TestFlight upload is included.
