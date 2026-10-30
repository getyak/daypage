# Release safety

Release is a separate, explicitly authorized workflow. A feature, fix, refactor,
test run or PR does not itself authorize TestFlight upload or App Store submission.
The opt-in workflow is documented in `.agents/workflows/release.md`.

Before release, resolve the exact candidate, account, destination and artifact;
verify the candidate's gates and privacy/configuration boundary; preserve rollback
references; perform only the authorized action; then read back deployed state.
Keep credentials, personal notes and private runtime evidence out of Git.

## Current local iOS edition (ADR-0027)

The active project is `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`.
Both Fastlane `beta` and `release` archive that project. Local iOS signing covers
`DayPage` / `com.daypage.app` only; the repository retains other legacy Apple targets.
The beta lane uploads to TestFlight; the release lane
submits to App Store review only when separately authorized.

The local app has no backend, database, account, telemetry or legacy extension
dependency. Its release does not write `ENV_FILE`, generate provider secrets, apply
a Supabase overlay, or provision Widget/Watch/Share profiles. Legacy source and
backend-validation tools remain available for the archived clients; those cloud
gates must not be reintroduced as local-app prerequisites.

The app uses Apple's system networking and Keychain, with no proprietary
cryptography. Its Info.plist declares `ITSAppUsesNonExemptEncryption = false` to
avoid an unanswered compliance questionnaire blocking beta availability. See
[Apple's encryption guidance](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations).

## Candidate CI and signing

`testflight.yml` keeps automatic publishing for current app/build inputs and a
manual beta/release fallback. Release-input changes also trigger `ios-local.yml`,
so every automatic publication candidate has the required local-app check.

The Ubuntu `candidate-ci` job must pass before the macOS deploy job starts.
Automatic and manual publication require `refs/heads/main`. Both fixed workflows,
`ci.yml` and `ios-local.yml`, must have a successful latest main-push run/attempt
in the same repository at exactly `GITHUB_SHA`. A general-CI success cannot
replace local-iOS CI. Missing/queued runs wait within a shared one-hour budget;
failure, cancellation, skipped conclusion, malformed/API error or timeout refuses
publication. Requests are bounded to 30 seconds. Both jobs check out the exact SHA.

The existing signing secrets belong to the existing App Store Connect app and
match repository. Match's exact generated profile name is applied to the local
Release target with manual `Apple Distribution` signing and used in export
options. Missing main-app provisioning fails before archive/upload.

Before merging, verify all applicable checks on the final PR head, including
Maestro. Maestro runs for PR/schedule events; a main-push success does not imply
that UI job ran. The local-iOS workflow tests DayPageCore, checks the active
project boundary and builds the unsigned Release simulator app.

Host-side assembly and failure regressions:

```sh
ruby -c fastlane/Fastfile
ruby scripts/tests/test_release_signing_profiles.rb
python3 scripts/tests/test_testflight_release_tags.py
python3 scripts/tests/test_release_ci_gate.py
bash scripts/ci/run_script_tests.sh
```

The signing harness executes an isolated Fastfile copy against recorded no-op
external actions. It never loads the repository .env, signs, archives, contacts
Apple or uploads. Set TMPDIR to a registered artifact directory. A pass proves
host-side preparation only; native compilation/signing and Apple acceptance need
their own evidence.

## Version and publication integrity

Automatic releases choose the next unused numeric patch after the newest release
tag, respecting a higher checked-in local-project MARKETING_VERSION as a floor
(the local edition begins at 0.5.0). A manual override must be numeric and unused.
Automatic and manual releases share one non-cancelling concurrency group.

Fastlane writes version/build settings only in the local project. The binary,
Git tag, release and changelog share that version; the build number is the exact
candidate's Git commit count. If a tag becomes occupied after upload, fail rather
than relabel the uploaded binary. A rejected push also fails without publishing
an alternate version. Inspect Apple for a partially uploaded build before retry.

The publishing workflow uploads quickly without waiting for processing. The
separate `update-changelog.yml` resolves the same commit/version/build, waits for
Apple `VALID`, and writes What to Test. Read that exact-build result before
claiming TestFlight processing completed. Tester availability, external Beta
review, installation and physical-device behavior remain separate checks.
Retain the previous binary/source tag as a rollback reference; this workflow
does not migrate, rewrite or delete user data.

## Other surfaces

The shared-backend overlay/validator and legacy privacy/data-safety gates remain
relevant when explicitly releasing an archived cloud client. They are not gates
for the dependency-free local iOS app. Web/MCP/backend publishing requires its own
candidate and destination verification; iOS release evidence does not apply to
those surfaces.

Web CI uses synthetic public configuration for lint/unit/production-build and
marketing-browser checks. It does not prove hosted login, cloud synchronization
or production deployment. See the testing guide for those separate gates.
