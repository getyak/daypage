# Shared Account — Native Email/Password Login (iOS + Mac)

Batch under GitHub #884: standard email/password sign-in on iOS and Mac, plus
the missing iOS QA SDK session namespace. Magic-link and Apple sign-in paths
are preserved unchanged.

## User flow

- **iOS** (`AuthView` → email sheet `EmailAuthView`): the sheet opens in
  **password mode** — email + `SecureField` password, keyboard submit, correct
  AutoFill content types (`.username` / `.password`), typed privacy-safe errors,
  scroll/keyboard support and an always-available cancel. A segmented picker is
  the explicit **Password vs Email Link** selection; email-link mode keeps the
  existing two-stage magic-link flow (send → resend/change email).
- **Mac** (`MacAuthView` account center): password is likewise the initial mode
  via the same explicit picker; the email-link flow is retained. Apple sign-in
  is unchanged on both platforms.
- No fixed address/password, no automatic login. Passwords are never trimmed or
  normalized; email is normalized only by the existing app rule (trim +
  lowercase, then the existing pattern — including its pre-existing quirks).

## Password handling boundary

- Password exists only as transient form state (`EmailAuthViewModel.password`,
  `MacAuthView.password`); it is cleared on successful SDK response, on mode
  change, and when the form disappears. No `UserDefaults`/Keychain persistence,
  no logging, no telemetry.
- Missing (empty) password is rejected on-device before any request and never
  logged. Provider payload/error text never reaches UI, logs or telemetry:
  password errors map through typed codes only
  (`AuthService.mapPasswordSignInError`, `MacCloudAuthService.userFacingMessage`).
- No new signup-strength policy is imposed on existing credentials.

## Session ownership

- `supabase.auth.signIn(email:password:)` (pinned Supabase Swift 2.55.2,
  `async throws -> Session`) is called with the returned `Session` discarded:
  **`authStateChanges` remains the only writer of session state** and the
  existing realm/session installer path (iOS `SyncQueueObserver` installer, Mac
  lease installation) is unchanged. No new config or session installer exists.

## QA namespace boundary (iOS only)

- In `AuthService`, **both** the real and the placeholder `SupabaseClient` are
  built with options resolved *before* the SDK initializes
  (`AuthService.makeClientOptions`).
- DEBUG iOS bundles with IDs starting `com.daypage.app.qa-` use
  `KeychainLocalStorage(service: bundleID + ".supabase.gotrue.swift",
  accessGroup: nil)` via `SupabaseClientOptions(auth: .init(storage: …))`.
  Everything else (production, Release builds) keeps the SDK default options
  and service.
- The decision is a pure, tested resolver
  (`NativeAuthFlow.qaSessionStorageServiceName`); no Keychain access in tests,
  no session migration/enumeration/deletion. **Mac is intentionally not
  isolated** — its client keeps default storage and this doc makes no Mac
  namespace claim. `SystemActionSharedSummaryStore`'s resolver is untouched.

## Secrets and configuration

- Supabase URL/publishable key and any account credentials are **parent-owned**
  (local ignored config/`Secrets`); nothing is embedded in code, tests or this
  doc. The shared backend was authorized by the user with the same default
  DayPage email; provisioning and cloud settings stay with the parent.

## Signed-in account sync settings (presentation follow-up)

Presentation-only follow-up on the same batch; no session, installer, OAuth,
Keychain, namespace, schema or backend-default change:

- The signed-in **Sync & Data** page shows a compact account cloud section
  before the optional iCloud settings: account email, the current sync status,
  pending/media states when meaningful, and a **Sync Now** button (stable
  accessibility id `account-sync-now-button`). The button is a direct
  synchronous MainActor `SyncQueueService.requestFlushIfOnline(reason: .manual)`
  call — no host outer Task — with busy/offline disabled state and matching
  accessibility hints. Attachment transfers keep the existing cellular-media
  policy inside the shared sync queue.
- Status copy is resolved once by a small shared helper (`AccountCloudStatus`)
  from the existing `AccountSyncStatus.resolve` inputs and the shared
  `completion.isFullySynced` proof, with the same guards and precedence as
  `AccountSheet`: “synced” is never claimed from anything weaker. The signed-in
  Settings hub summary consumes the same helper's copy as the detail section.
- The legacy server URL / API-key configuration form is hidden while an
  authenticated session is present; signed-out legacy behavior and stored
  values are unchanged. Legacy server credentials are not read at all while
  signed in (the form values load only on appear for signed-out use), and the
  legacy configuration-dependent pending/synced rows and footer are likewise
  signed-out only — an authenticated shared account never sees "waiting for
  setup" copy and never touches `SyncSettings.isConfigured` (which can read
  the old Keychain API key). The signed-in branch keeps only the generic
  cellular-media policy toggle and provider-encryption disclosure.
- New strings are complete in English and Chinese with no duplicate keys.

## Verification performed here (local, no network)

- `python3 -B scripts/tests/verify_native_password_host.py --artifact-root /private/tmp/ai-test-daypage-native-password-host.xLA4ej`
  — compiles and executes the **actual** `NativeAuthFlow.swift` in a
  Foundation/CryptoKit/Security host harness (49 checks, no mirrored code, no
  networking/Keychain calls), plus `swiftc -frontend -parse` syntax-only
  receipts for every changed Apple file. Syntax-only ≠ full build.
- `git diff --check` — clean.
- `DayPageKit/Tests/DayPageServicesTests/NativeAuthFlowTests.swift` extended
  with shared rule tests (email validation/normalization boundaries, password
  preservation, QA namespace resolver) using synthetic data only.

## Gates still unexecuted (parent-owned)

- `swift test --package-path DayPageKit` and full iOS/Mac app builds.
- Live native email/password login against the real shared Supabase backend,
  real QA Keychain isolation on Simulator/devices, AutoFill and UI/a11y flow
  verification, and Apple/magic-link regression passes.
- Account sync settings follow-up: full iOS/Mac SDK builds and affected
  `DayPageTests`, Simulator/device UI verification of the signed-in account
  cloud section, hub summary, legacy-form hiding and VoiceOver behavior, plus
  the real-device sync-now flow. Local evidence is bounded to hermetic Kit
  tests and syntax-only parsing; `ready_for_review` is not all-platform
  delivery.
