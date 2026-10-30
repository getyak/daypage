# Local iOS TestFlight Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, then an independent whole-branch review. The user authorized fixing CI/CD, merging, and publishing to TestFlight.

**Goal:** Publish the current local notebook as DayPage 0.5.0 to the existing TestFlight app.

**Architecture:** Keep the existing version/tag serialization, match credentials and asynchronous Apple-processing check. Replace archived-project inputs with the current local project and require both general and local-iOS CI at the exact candidate SHA.

**Tech Stack:** GitHub Actions, Fastlane/Ruby, Python regression harnesses, Xcode.

**Spec:** GitHub #944; ADR-0027-local-ios-notebook.md.

## Global Constraints

- Existing app: `com.daypage.app`; current project: `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`.
- No backend configuration, legacy extensions, new dependencies or user-data migrations.
- Preserve the exact build/version/tag identity and fail on collisions or failed CI.
- TestFlight only; no App Store submission, tester invitations or production backend changes.

## Review Focus

- General CI success cannot substitute for local-iOS CI success.
- A checked-in marketing-version increase must win over older release tags.
- Missing main-app provisioning must refuse archive and upload.
- The archived project and real notes must remain untouched.
- Upload success must be followed by the exact version/build's Apple VALID readback.

### Task 1: Restore current-project signing and version selection

**Files:** `fastlane/Fastfile`, `.github/workflows/testflight.yml`, `DayPageLocal/Info.plist`, existing release-signing/tag tests.

- [ ] Run baseline signing/tag tests.
- [ ] Change harness expectations to one local-app target, add actual version-write isolation and automatic version-floor cases; observe failures.
- [ ] Point all active release actions and version writes at the local project, remove cloud setup and extension signing; respect the project's 0.5.0 floor.
- [ ] Declare the existing OS-only encryption exemption in the new app's Info.plist.
- [ ] Run the signing/tag tests and Ruby syntax check.

### Task 2: Gate and publish the exact verified candidate

**Files:** `scripts/ci/wait_for_release_ci.py`, `scripts/tests/test_release_ci_gate.py`, `.github/workflows/ios-local.yml`, release docs.

- [ ] Add an API-boundary regression where general CI passes and local-iOS CI fails; observe the original gate incorrectly succeeds.
- [ ] Require both fixed workflow identities at the same main SHA, preserving bounded waits and failure handling.
- [ ] Run local-iOS checks for release-input changes; remove obsolete backend-workflow coupling tests while retaining legacy overlay behavior tests.
- [ ] Update current release documentation; run the complete standalone script suite and repository doctor.
- [ ] Independent review; fix confirmed release risks, commit, push and open a PR linked to #944 and GET-326.
- [ ] Wait for current-head applicable CI; merge. Track one automatic release without dispatching a duplicate.
- [ ] Read back signed IPA identity, tag/commit, Apple processing and changelog status; save a non-sensitive receipt.
