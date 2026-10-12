# Remote recovery — unpublished DayPage source (2026-10-12)

Status: integration record for recovering unpublished local source on a dedicated branch against `main`
for GitHub #928, with the #876 screenshot-capture work and one behavior-
preserving #332 design-system cleanup item. This document records what was
recovered, what was deliberately **not** applied, and which acceptance remains
device-only. It contains no raw logs, screenshots, vault content, or absolute
host paths. No TestFlight release is part of this work.

Plan of record: [`docs/superpowers/plans/2026-10-12-remote-recovery.md`](../superpowers/plans/2026-10-12-remote-recovery.md).
Decision record: [ADR-0012](../architecture/decisions/ADR-0012-action-button-screenshot-capture.md).

## Recovered source sets

1. **Screenshot capture (#876, ADR-0012).** `SaveScreenshotIntent`, the Share
   Extension (`DayPageShare/`), `ScreenshotCaptureStore`,
   `ScreenshotCaptureCoordinator`, `ScreenshotEvidenceExtractor`,
   `ScreenshotShareInbox`, `ScreenshotUnderstandingProvider`, the Today review
   card, and their host tests. Behavior follows the accepted ADR-0012:
   original-bytes-first durable ingest, exactly-one memo delivery, local Vision
   evidence before any optional cloud understanding, and confirmation-gated
   drafts.
2. **Portable local iOS gates.** `scripts/ci/ios-local.sh` + `Makefile`
   selectors, `scripts/ci/select_simulator.py` device policy, and
   `scripts/ci/tests/test_ios_local.sh`. Current-main Python script test
   discovery (`scripts/tests/test_*.py`) is preserved; the recovered
   `scripts/ci/tests/*.sh` and root `tests/test_*.py` locations are additive.
   Current-main's stronger CI/release workflow safeguards (release-tag checks,
   Supabase config checks, keychain migration) are untouched.
3. **#332 design-system cleanup (one item, behavior-preserving).** The 18
   legacy `DSColor` alias removal with exact alias expansion at every call
   site, and removal of four dead visual helpers with zero live callers. Live
   helpers (`SurfaceElevatedShadow`, `GlassErrorBannerOverlayModifier`, …) are
   retained. See [`docs/design/testflight-fidelity.md`](../design/testflight-fidelity.md).

New screenshot code was migrated to canonical `DSColor` values (e.g.
`onSurfaceVariant` → `DSColor.inkMuted`); no removed alias was reintroduced.

## Deliberately not applied (stale five-pass and audit material)

The recovered snapshot also contained an older "five-pass" experience patch and
audit commits. These were **not** applied:

- 21 of the five-pass diff files are stale against current `main`; most of
  those deltas would **revert newer protections** — the search rewrite, the
  keychain migration, and the release-tag/CI safeguards landed since the patch
  was produced. Reapplying them wholesale is a regression, not a recovery.
- 133 five-pass tracked files are already byte-equal to remote `main`, so the
  patch would be a no-op for them.
- Most of the untracked five-pass source already exists in `main` in newer
  form.
- The one unique artifact, the old `ios-five-pass.md`, is **historical test
  evidence**. It references raw runs and host-local paths and is intentionally
  kept out of version control; only its conclusions that remain true are
  reflected in current docs.

The recovered screenshot implementation was integrated conflict-by-conflict
against current `main` — newer main code (privacy, navigation, diagnostics,
crash recovery, test-host isolation, insight/related swipe actions) always won
over historical text, and recovered screenshot behavior was woven in around it.

## Hardening applied during recovery

The ~2000 recovered screenshot lines were reviewed against crash durability,
concurrency, consent, and vault-safety hazards. Confirmed defects were fixed
with failing regression tests first (observed failing, then fixed, then
passing — `DayPageKit/Tests/DayPageServicesTests/ScreenshotRecoveryTests.swift`):

1. **Single-Vault binding.** Every multi-step operation (receive, memo ingest,
   reconciliation, delete/undo finalization) captures one Vault root at entry
   and pins both store and `RawStorage` steps to it. A Vault root switch at any
   await boundary can no longer split original/manifest and memo across vaults
   or delete another vault's capture. Manifest-declared paths are additionally
   validated (canonical relative paths under `raw/assets/screenshots/`, no
   traversal, no symlink escapes) before any read or delete.
2. **Stale consent completions.** A provider response arriving after
   `keepLocal`/consent revocation (per-capture or global) is discarded, never
   accepted; the capture stays local-only. The epoch is captured before awaited
   preflight work; durable consent and live policy are checked after the last
   preflight await, immediately before dispatch. Response authorization is
   checked inside the atomic manifest mutation. Concurrent passes cannot issue
   duplicate requests for one capture.
3. **Crash-phase recovery.** Recovery adopts every state a crash can leave —
   `stored`/`ingestPending` memo gaps (including the memo-before-manifest
   window) and `ingested`/`extracting`/`understanding` gaps — idempotently by
   exact memo UUID. Foreground passes and explicit retries repair the memo gap
   before evidence extraction can advance the phase, delivering exactly one memo.
4. **Canonical wire/UI kind.** New captures use the standard `photo`
   attachment kind (accepted by the existing sync attachment schema and
   Memo Detail rendering); the manifest/memo UUID supplies screenshot
   provenance. Legacy `screenshot`-kind read compatibility remains in Today.
   The raw memo format and original screenshot bytes are unchanged.
5. **Strict provider schema.** The OpenAI Structured Outputs schema is closed
   at every level (`additionalProperties: false` everywhere); `draftFields`
   travels as a closed key/value entry array while the internal contract keeps
   the typed dictionary.
6. **QA isolation.** The screenshot share inbox resolves its App Group from
   the running bundle identity: Debug `qa-unit`/`qa-ui` app, widget, and Share
   extension identities resolve `group.com.daypage.qa-unit`/`group.com.daypage.qa-ui`
   and can never read or drain the production `group.com.daypage` inbox. Numbered
   `qa-ui-<1..12 ASCII digits>` sessions have separate groups and Keychain services;
   unknown/nil identities are refused before any shared-container lookup. The
   Share extension bundle identifier now honors `DAYPAGE_QA_BUNDLE_SUFFIX`
   like the app and widget. Staged item filenames are validated so tampered
   handoff metadata cannot escape the inbox directory.
7. **Share cancellation race.** An explicit Cancel wins against the
   item-provider callback: no staging starts after cancel, and a racing staged
   copy is removed instead of reported as success.
8. **Preferred-time-zone grouping.** Screenshot manifests group by the same
   preferred-time-zone day contract as `RawStorage`/Today, including after a
   setting change, and memo operations use the owning day key captured at
   ingest.
9. **Opt-in processing stays off by default.** `screenshot.cloudAnalysisEnabled`
   defaults to off and is gated behind the AI master switch; no provider
   credential or default AI service was changed.
10. **Cross-instance mutation and deletion ownership.** Bound store instances
    serialize complete read/mutate/write and deletion operations, preventing
    lost updates or a late update recreating a deleted manifest. A rapid second
    deletion retains the first deletion's persistence task and waits for its raw
    write before finalizing that screenshot; the newer record remains undoable.

## Verification performed (local, this recovery)

- `git diff --check` — clean.
- `make doctor check-agent check-scripts check-localization check-tokens` —
  pass (script suite includes `scripts/ci/tests/test_ios_local.sh` and
  `tests/test_ci_scripts.py` alongside current-main `scripts/tests`
  discovery).
- `swift test --package-path DayPageKit` (bounded `--jobs 2 --no-parallel`)
  — 349 XCTest + 75 Swift Testing host tests, 0 failures (3 pre-existing
  skips). Screenshot regression tests cover the items above with
  synthetic 1×1 PNG fixtures only — no personal vault, auth, live provider or
  network call, or permission prompt.
- Isolated `DayPage` Debug build-for-testing and affected Simulator tests:
  the initial broad pass ran 187 tests / 188 parameter executions, with 0 failures
  and 0 skips. This includes
  screenshot/Undo, four migration cases, LLM/Thread, Doubao, Whisper, diagnostics,
  Today, App Intents, accessibility and swipe contracts. Test host and embedded
  extension identities were checked against the QA namespace. Native manifests
  are compared to the persisted source and exact JSON bytes, accounting for the
  existing ISO8601 timestamp precision.
  The final ordering/atomicity fixes were rebuilt and verified with 58 affected
  tests / 59 parameter executions (Screenshot, Today and migration), again with
  0 failures and 0 skips; overlapping tests are not added to the broad-pass total.
- Independent review found and closed screenshot result-admission inversion,
  migration destination symlink mutation, incorrect native test boundary scripts,
  and Thread secret/test-vault coupling. Stronger gated Undo tests also exposed
  and closed canceled-finalizer orphaning. The final review also closed awaited
  consent revocation, cross-store mutation, interrupted retry and rapid deletion
  defects with observed failing regressions followed by passing results. Failed regressions and final passing
  receipts are retained privately; neither a worker checkpoint nor an unmatched
  test selector was counted as acceptance.
- Primary iPhone Simulator smoke used the dedicated `com.daypage.app.qa-ui-928`
  namespace and a synthetic seeded capture: Today card, canonical photo detail,
  full-screen original, real typed meaning save, local search of the edited text,
  Settings (AI and screenshot cloud both off), and ordinary text submission all
  worked. The resulting raw Markdown retained one screenshot memo, the standard
  separator, and the unchanged original-image digest. This is UI/rendering and
  storage evidence; seeded data is not Share or Action Button ingress evidence.
  Existing QA app data on Primary and Compact were preserved; no Compact layout
  acceptance is claimed. A fresh final-source build additionally verified actual
  screenshot deletion removes the memo, original and manifest, real text deletion
  Undo restores exactly one record, and the corrected consent copy is visible
  while both AI switches remain off. Screenshot Undo preservation is covered by
  the native suite; a late manual Undo attempt is not counted as a successful
  screenshot restoration. All raw evidence stays outside version control.

## Remaining acceptance and genuine limitations

- **Device-only #876 acceptance is NOT complete.** The Action Button/Shortcuts
  handoff, first-run screenshot permission, locked-device and first-unlock
  behavior, DRM/secure screens, landscape/dense-text matrix, disk-full and
  crash-window drills, and the Share Extension under the production App Group
  provisioning profile require a signed real-device run (iOS 18 through
  current). Simulator cannot truthfully sign these off. Issue #876 stays open
  until that matrix runs.
- QA builds resolve their own screenshot inbox namespace, but a QA container
  with the QA app groups must be provisioned for QA builds to have a *working*
  (not just isolated) share inbox; without it the inbox fails closed with
  "app-group unavailable" and never touches production.
- Issue #332 covers far more than the one behavior-preserving cleanup item
  delivered here; it remains open. No new TestFlight release is included.
- Remote CI binds the pushed PR head and is recorded on [PR #929](https://github.com/getyak/daypage/pull/929).
  Local passing results do not substitute for that head's remote checks.

## Second bounded privacy batch (#928, request-time AI switch enforcement)

Frozen policy: the EXISTING master AI switch is enforced at every actual new
request boundary. Defaults and the reachable consent UI are preserved; the old
v2 explicit-grant/version UI policy is deliberately NOT restored. Denials map
to the typed terminal `AIAuthorizationError` (→ `CompilationError.aiDisabled` /
`WeeklyCompilationError.aiDisabled`) so the existing quiet local-only,
no-retry classification stays effective.

1. **Shared LLM and thread conversation.** `AIRequestConsent` provides a small
   injectable `AIConsentChecking` policy (`LiveAIConsent`,
   `LiveScreenshotCloudConsent`, `AllowAllAIConsent` for transport-only tests).
   `LLMClient` checks it at entry, before EVERY retry attempt, and again
   immediately before the SSE connection opens (`streamSession` is injectable
   for a terminal `URLProtocol`). `ThreadConversationViewModel` now routes
   through the guarded client (prompt/context/storage behavior unchanged, with
   an injectable stream seam for tests).
2. **Voice/ASR boundaries.** `DoubaoFileASRClient` checks before work and again
   after the asynchronous file read, immediately before the HTTP send
   (injectable consent/read/transport seams). `DoubaoStreamASRClient` checks
   before config, audio, and terminal frames; a denial closes the connection
   once and the connection can never resume even if the toggle turns on again.
   `VoiceService` stops the denied mic pump, and Whisper re-checks after the
   file read and before every upload retry. Feedback temporary-audio isolation,
   exact-file cleanup, local retry, and on-device fallback are unchanged.
   Connectivity probes (`SettingsAIVoiceView` tests, `DoubaoConnectivityTester`)
   refuse while the switch is off, with no prompts.
3. **Backend-first authoring.** `BackendIntelligenceService.requestDaily/Weekly`
   check before the sync flush and AGAIN after the awaited flush before the
   remote request (injectable flush seam). OFF ⇒ zero flush, zero request, zero
   scheduled refresh; an OFF transition during the flush ⇒ zero request.
   Legitimate independent account sync and read-only derived `refresh()` stay
   ungated.
4. **Diagnostics epoch start floor.** `DiagnosticsConsent` persists an
   immutable (UUID, startedAt) pair inside the existing serialized transition:
   repeated grants/relaunches reuse it, revocation removes both, legacy/malformed
   pairs rotate conservatively. `DiagnosticsEventGate` is a pure admission
   helper (live consent + epoch match + non-nil finite timestamp ≥ floor, no
   pre-floor grace window). The real `options.beforeSend` is built by
   `SentryLive.makeBeforeSend` (a testable production seam) and rejects
   old/nil timestamps BEFORE the unchanged field scrubber; MainActor SDK
   lifecycle, cache-epoch isolation, the fixed endpoint/no-redirect transport
   gate, and the envelope allowlist are untouched. Continuous-consent
   prior-launch crashes after the persistent floor remain eligible.
   **Evidence boundary:** the deferred raw-crash admission hole is a
   SOURCE-PROVEN race in the locked Sentry 8.58.4 chain (queued sink block →
   current global Hub → original crash timestamp); no production upload has
   been observed or claimed, and no real SDK cache/event data was read.

## Screenshot capture follow-ups (parent review findings)

1. **Live request/admission guards.** The OpenAI adapter checks the live
   screenshot policy (master switch AND the default-off screenshot opt-in)
   immediately before send and before response acceptance; the coordinator
   re-checks before its provider call and at acceptance. Settings revocation
   (AI master or screenshot cloud) invalidates pending/in-flight capture epochs
   via `noteCloudConsentRevoked()` — no foreground event needed. Late failures
   can never overwrite durable `localOnly`/deleted state as
   `failed`/`pendingNetwork`.
2. **Vault-root path containment.** `ScreenshotCaptureStore` now validates
   every asset AND manifest read/write/delete/enumeration against the captured
   RESOLVED Vault root with an lstat component walk: traversal, whole-folder
   symlinks (screenshots or manifest directory), and symlinked files are
   refused; `/tmp`→`/private/tmp` root spelling stays legitimate. Asset paths
   must be the exact owning capture's generated original
   (`screenshot_<id>.png|jpg`) or derivative (`analysis_<id>.jpg|jpeg|png`),
   and a loaded manifest's embedded id must match both the requested UUID and
   the on-disk JSON basename. Tampered same-directory siblings can no longer
   read/delete a second capture. Share-inbox filenames are identity-bound to
   the staged item UUID (one JSON can never remove a second capture).
3. **Share handoff replay.** The staged item's stable UUID binds the durable
   capture identity (`ingest(..., stableID:)`); replay after a crash/remove
   failure reuses the same capture/memo/original even beyond the 30-second
   digest window, and memo delivery stays idempotent by memo UUID. A reused
   identity with changed bytes or a different source is rejected
   (`stableIDConflict`).
4. **Single-flight preflight.** Provider work is reserved by
   (resolved Vault root, capture ID) before the first awaited preflight step
   and released on every exit; overlapping startup/foreground/retry passes
   produce exactly one provider request, while a copied capture UUID in a
   second Vault processes independently.
5. **Undo finalization.** Today closes the deletion's Undo ownership on
   MainActor at window expiration BEFORE awaiting irreversible finalization,
   awaits the durable raw deletion first, and never clears a newer deletion's
   Undo state (generation guard). The finalizer honors cancellation and
   re-checks memo absence before deleting files, so an accepted Undo can never
   lose the original screenshot.

## Final integration fixes

- Copy and verification now share `VaultMigrationFileInventory`: canonical
  hidden screenshot manifests travel with raw memos and originals while unrelated
  hidden caches remain excluded. Every manifest is hashed, and destination extras
  cannot hide missing source files. Destination inventory and component checks run
  before the first write, with checks repeated after asynchronous progress updates;
  selected symlinks are refused before an outside file can be replaced. Settings
  commit is injectable so native tests never change a real vault preference.
- Coordinator admission now accepts an authorized successful result and discards
  a result after live revocation even without an epoch notification. Both cases
  were observed failing before the fix and pass in the final host suite.
- Expired screenshot deletion clears its timer handle before finalization awaits.
  A newer deletion cannot cancel the old finalizer or lose its own Undo state.
  Native tests gate the actual finalizer and inspect durable raw records and assets.
- Thread tests use explicit isolated roots and terminal recording SSE sessions;
  provider keys are resolved only on the production route after live authorization.
  Whisper and Doubao tests exercise the actual post-read/retry/open-socket boundaries
  with recording fakes and no live credentials.

## Partial acceptance links

- #928: this batch plus the first checkpoint close the source-proven request
  and admission gaps listed above; final acceptance is parent-owned (fresh
  independent review + native gates).
- #876: partially accepted (source recovered and hardened); the real-device
  matrix above remains open.
- #332: partial acceptance of one behavior-preserving design-system cleanup
  item only; the broader issue remains open.
