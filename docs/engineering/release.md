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

See `.agents/workflows/release.md`. Never place credentials or private release evidence in
the repository.
