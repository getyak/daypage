# ADR-0027: A local-only iOS notebook

Status: Accepted for GET-326, following the user's October 30, 2026 request and explicit iOS-first scope.

## Decision

The active iOS application is `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`. It builds only `DayPageLocal` and the dependency-free `DayPageCore` package. Keep the existing multi-client project and sources for the other clients; they are outside this iOS refactor. In particular, the new app does not resolve, link or initialize Supabase, Sentry, the legacy sync/agent runtime, app extensions, cloud accounts, or any database.

A separate project is deliberate: Xcode resolves package dependencies for the entire legacy project even when its selected iOS target no longer links those products. Keeping the local app's project separate makes its dependency and startup boundaries explicit and prevents macOS-only cloud packages from becoming an iOS build prerequisite.

The previous edition is recoverable from [the cloud source archive](https://github.com/getyak/daypage/releases/tag/archive/cloud-2026-10-30), exact commit `4cb0fced8265809648f1b0d952b86bc8a111b8c7`. This is a source archive, not a new installable distribution. No live database, existing deployment, historical worktree, or real Vault is removed.

## Files and upgrades

Release builds preserve `com.daypage.app`. Debug/Simulator builds use the isolated `com.daypage.app.localqa` identifier. The default Vault remains `Documents/vault`, with canonical `raw/YYYY-MM-DD.md` and `raw/assets` paths. Existing files are read without rewriting. The existing Memo YAML codec and both separators are retained; edits preserve the original header and untargeted raw blocks. Duplicate IDs, ambiguous separators and stale mutations fail before writing.

Some old installations use an iCloud Vault. The new app does not silently choose a stale local copy or migrate cloud data. Settings explains how to download and select an old Vault in Files. Import copies into a new UUID namespace, validates the staged copy before publication and preserves the source. Namespaced imports can be exported and re-imported, including notebooks containing only imported notes. No account is needed for recording, search, import or export.

## AI and chat

AI is opt-in through a user-supplied OpenAI-compatible address and model. Device-only Keychain items are scoped to normalized origins; preferences contain only non-secret configuration and whether a key is used. Anonymous local services never access Keychain. Key-based mode rejects a missing credential before opening the request. Service changes do not carry a key to a new origin. HTTPS is required except explicitly permitted localhost/private IPv4/`.local` HTTP. The app rejects embedded URL credentials, query strings, fragments and all redirects. There is no default provider, built-in credential, model discovery request, startup probe or automatic note processing.

Only an explicit Send or connection-test action opens a request. The test sends no notes. Chat shows its source excerpts before sending, caps selection at 12 notes / 18,000 characters, caps conversation request history, and treats note content as untrusted quoted material. The client has no tools. Requests and response bodies have size/time limits. Provider error bodies are not shown or logged. Chats and drafts are local files; note-scoped conversations are isolated from whole-notebook conversations. Reopened chat editors get a new persistence lease so older pending writes cannot overwrite them.

For endpoint compatibility and platform transport behavior, see [LM Studio's server documentation](https://lmstudio.ai/docs/developer/core/server) and [Apple's local-network ATS documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking). The settings screen explains that an iPhone's localhost is the iPhone, and a desktop model needs the computer's LAN address.

## Navigation and design

The initial navigation and visual choices below were corrected by
[ADR-0028](ADR-0028-local-product-continuity.md) after the user rejected the 0.5.0
experience. Preserve the established Today stream, capture dock and mature local
note operations; the three drawer destinations remain unchanged.

The sidebar has exactly Archive, Feedback and Settings. Archive contains local search, writing and note chat. There is no login, graph, daily compilation, agent dashboard, scheduling or sync destination in this app. Feedback drafts remain local until the user opens a share or GitHub submission interface.

The editable [Figma refinement](https://www.figma.com/design/el5wnKFHTBcgln16ktEztU/?node-id=420-1331) uses a warm paper canvas and a dark green notebook spine. SwiftUI adapts its spacing to safe areas, smaller screens and Dynamic Type; SF Symbols are native, and the existing bundled reading fonts are reused. Figma's cloud renderer could not render its SF Pro text reliably, so its editable CJK labels use Noto Sans/Serif SC; native controls retain system typography and prose uses the bundled Source Han Serif / Source Serif fonts.

## Gates and limits

Run the complete DayPageCore host suite, active-project dependency contracts, an unsigned iOS build and isolated Simulator UI flows. QA launch arguments require both the dedicated Debug bundle and `-qaNotebookSession`; tests use `Documents/qa-GET-326/vault` and a separate preferences suite, so reset does not touch the normal notebook. Independent review covers storage and credential boundaries. A loopback fixture verifies the real transport without a production provider or user key. Simulator evidence does not establish signed-device Keychain, real-provider, real iCloud-provider or TestFlight acceptance. New iOS binary distribution remains an explicit separate action.
