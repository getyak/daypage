# Release safety

Release is a separate, explicitly authorized workflow. A feature, fix, refactor, test run,
or PR does not imply permission to tag, merge, deploy, upload TestFlight, migrate a
production database, or clean branches/worktrees.

Before any release:

1. Resolve the exact commit, artifact, environment, account, and destination.
2. Confirm user authorization for the named action.
3. Run release gates on that exact candidate.
4. Review configuration, privacy, migration, rollback, and monitoring.
5. Perform only the authorized action and verify deployed state.

The iOS beta/release lanes run `scripts/ci/validate_release_supabase_config.sh` before
archive. The gate requires a real HTTPS `SUPABASE_URL` and a publishable/legacy anon
client key, and rejects placeholders plus `sb_secret`/`service_role` credentials.

## Privacy & data-safety release gates (issue #922)

Release candidates must keep these user-safety invariants verifiable:

1. **Clear local data is fail-closed.** The danger action may only delete the
   canonical local vault; it must refuse (preserving vault, keys, and
   preferences) whenever the active vault is iCloud-backed or noncanonical, or
   a cloud account session is authenticated. The policy lives in
   `DayPageKit/Sources/DayPageServices/LocalDataResetPolicy.swift` and is
   re-evaluated immediately before any mutation.
2. **Crash diagnostics are opt-in and default OFF.** The live Sentry SDK starts
   only with persisted `DiagnosticsConsent` plus a DSN; revoking consent closes
   the SDK and the `SentryReporter` event gate refuses every future event.
   Events already uploaded cannot be recalled from the device — never claim
   otherwise in release notes.
3. **The in-app Privacy & Data screen is the current disclosure** (Settings →
   About): local-first notes/attachments, optional iCloud and signed-in account
   sync (not end-to-end encrypted), configured voice providers (Doubao /
   Whisper) and AI context, opt-in crash diagnostics. `daypage.app/privacy` is
   not published (404) — release metadata and UI must not link to it.

Host-side verification before handoff to the native session:
`swift test --package-path DayPageKit`, `bash scripts/check_localization_parity.sh`,
and `git diff --check`; run the iOS build and Simulator gates through
`dev-ios-session` with registered artifacts and an isolated QA identity.

## TestFlight version integrity

The workflow serializes automatic and manual releases in one concurrency group.
It chooses an unused numeric version before archive and uses that same version
for the binary, Git tag, release and changelog. If the tag becomes occupied after
upload, the workflow fails instead of renaming the uploaded build. A rejected tag
push also fails; no alternate version is published. Inspect App Store Connect for
the partially uploaded build before retrying with a fresh version. The isolated
real-Git regressions run via `scripts/tests/test_testflight_release_tags.py`.

## Release signing regression (host-side)

`scripts/tests/test_release_signing_profiles.rb` loads a copy of `fastlane/Fastfile`
into an isolated synthetic temporary directory (it never reads the repository root
`.env`), captures the lane DSL blocks, and executes the real beta/release match,
Release signing configuration, and export-option assembly against recorded no-op
doubles. The harness refuses shell, keychain, xcodebuild, App Store Connect, match
remote, and upload operations, so nothing signs, archives, or uploads. System Ruby
with its bundled minitest is enough — no Fastlane gem, credentials, or network:

```sh
ruby scripts/tests/test_release_signing_profiles.rb
```

Set `TMPDIR` to a registered scratch directory to pin where the synthetic fixtures
are created. A pass means the host-side assembly is correct; it is local
preparation only and never evidence of a TestFlight publish, an App Store
submission, or a physical-device fix.

## iOS release checklist

1. **All four bundle identifiers are provisioned through match.** Both the beta and
   release lanes must fetch match `appstore` profiles for exactly these identifiers
   and wire each corresponding Xcode target — `com.daypage.app` (DayPage),
   `com.daypage.app.DayPageWidget` (DayPageWidget), `com.daypage.app.watchkitapp`
   (DayPageWatch), `com.daypage.app.share` (DayPageShare). Each Release target must
   receive its own generated profile name with manual signing (`Apple Distribution`),
   and the export options `provisioningProfiles` map must contain exactly these four
   entries. A missing Share mapping must fail the lane before archive/upload. Verify
   on the host with `ruby scripts/tests/test_release_signing_profiles.rb` and
   `ruby -c fastlane/Fastfile`.
2. **Recheck CI `ENV_FILE` provenance before each release.** During the 2026-10-17
   investigation, its metadata showed a 2026-07-15 update, predating the shared
   backend created on 2026-10-16. This is historical evidence, not a live status
   check; the workflow writes that secret to `.env` before running fastlane.
3. **During a separately authorized deployment**, set the required repository secrets
   `DAYPAGE_SUPABASE_URL` and `DAYPAGE_SUPABASE_PUBLISHABLE_KEY` from the approved
   public configuration source. After writing the existing `ENV_FILE`, the workflow
   runs `scripts/ci/apply_release_supabase_overlay.py .env`: it replaces all three
   public Supabase fields (including legacy anon duplicates), preserves other bytes,
   and atomically writes mode 0600. Missing/invalid pairs refuse publication. The
   existing Supabase/Sentry validator runs again before signing; syntax validation
   alone does not prove the URL/key pair is live or belongs to the intended project.
4. **Never overwrite the full CI `ENV_FILE` with a stripped QA `.env`.** The stripped
   file lacks the required Sentry field and potentially other fields; replacing the
   full secret with it would silently drop them.
5. Keep private values and absolute personal paths out of repository documentation.
   Runtime evidence belongs outside version control. The standalone script runner
   discovers `test_*.rb` and executes the isolated signing regression in CI.

## Exact-candidate CI prerequisite

The publishing workflow retains its Apple-input push filters, but its Ubuntu
`candidate-ci` job must succeed before the macOS deploy job starts. Automatic and
manual publication both require `refs/heads/main`. The gate checks the fixed
`ci.yml` workflow in the same repository, for a main push at exactly `GITHUB_SHA`.
It checks the latest run/attempt only: missing or queued runs have a bounded wait;
failure, cancellation, skipped conclusion, malformed/API error or timeout refuses
publication. Each API request is bounded to 30 seconds and the total wait to one
hour. Both jobs check out the exact SHA. No branch protection is bypassed.

Before merging, separately verify all applicable checks on the final PR head,
including Maestro. Existing Maestro runs only for PR/schedule events; a main or
merge-group CI success does not mean that UI job ran. After upload, verify the
exact version/build reaches Apple `VALID` (the asynchronous changelog workflow
records this) and confirm tester availability separately. Upload success alone
does not prove processing, installation or physical-device login.

Offline boundary regressions:

```sh
python3 scripts/tests/test_release_supabase_overlay.py
python3 scripts/tests/test_release_ci_gate.py
```

## Web candidate checks

CI runs Web lint, every unit-test file under `web/src`, and a production Webpack
build on the candidate commit. The build uses an `.invalid` Supabase URL and an
explicit synthetic public key; it does not access a database or authenticate a
real account. These checks verify compilation and local regressions, not hosted
login, cloud sync, attachment ownership with real sessions, or deployment.

The built English/Chinese public landing pages also run in Chrome on desktop
and mobile, with both motion preferences repeated five times. CI uses the
runner's preinstalled Chrome and saves screenshots/failure traces for seven days.
For a local run, set `DAYPAGE_MARKETING_OUTPUT_DIR` to a registered task artifact
directory and use `web/playwright.marketing.config.ts`; the config starts the
already-built product on `127.0.0.1:13000` and refuses to reuse another server.

See `.agents/workflows/release.md`. Never place credentials or private release evidence in
the repository.
