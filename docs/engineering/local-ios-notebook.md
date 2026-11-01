# Local iOS notebook

Open `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`. This is the active iOS app. The root `DayPage.xcodeproj` remains the legacy multi-client project.

The application stores notes as Markdown at `Documents/vault/raw/YYYY-MM-DD.md`, with attachments under `raw/assets`. It does not require a DayPage account, backend or database. It reads existing local files without migration. Import in Settings copies a downloaded older Vault into a separate namespace; the source stays untouched. Exports contain original files, imported notes and local conversations. Keep an independent copy of an old iCloud Vault until the imported result has been checked.

Choose an AI provider and enter its API key in Settings; the app supplies the address and defaults to automatic model updates where supported. Fixed models and custom/local servers remain available. See [personal AI setup](local-ai-setup.md) for provider, region, model, privacy and recovery behavior. Keys are device-only Keychain items scoped to service origin. Local HTTP requires explicit permission. Connection tests send no notes; note chat previews excerpts and sends them only after explicit Send.

## Development

```sh
swift test --package-path DayPageCore --jobs 2
python3 scripts/tests/test_local_ios_contract.py
xcodebuild -project DayPageLocal/DayPageLocal.xcodeproj \
  -scheme DayPage -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

On a managed local host, use its `dev-ios-session` wrapper for builds and Simulator tests. Use the existing Primary iPhone pool and serial testing. The project spec is `DayPageLocal/project.yml`; regenerate only when needed:

```sh
xcodegen generate --spec DayPageLocal/project.yml --project DayPageLocal
```

Debug uses `com.daypage.app.localqa`; Release keeps `com.daypage.app`. The UI tests also pass `-qaNotebookSession` and use only `Documents/qa-GET-326/vault` plus a separate preferences suite. Reset/seed/mock-endpoint arguments have no effect in a normal session or Release build. Do not point tests at a real Vault. The task fixture binds only to `127.0.0.1:18763`:

```sh
python3 scripts/qa/local_notebook_ai_fixture.py
```

The chat UI test checks the fixture's health marker before sending synthetic data; it skips that case when this task-owned fixture is absent. A full run with the fixture exercises actual HTTP request/response handling, scoped note context and chat persistence across reopening/relaunch. It is not a real-provider or signed-device credential test.

## Simulator Keychain verification for GET-351

`CODE_SIGNING_ALLOWED=NO` is sufficient for compilation, but the resulting Simulator app may lack an application identifier and Keychain access groups. iOS 26.5 then returns `-34018` for actual Keychain reads and writes. Do not treat those rejected operations as successful saves or remove the storage assertions.

For Keychain runtime tests, let Xcode build the task-owned Debug Simulator product with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES`. The Simulator SDK requires simulated Mach-O entitlements as well as an ad hoc signature. Manually adding device-style entitlements with `codesign` is not equivalent and produced an app that this iOS 26.5 Simulator refused to launch.

Verify `CFBundleIdentifier == com.daypage.app.localqa` and read back the generated QA application identifier/access group before installing through the managed session. With this repository's development team, the expected group is scoped to `6RG2F8YY59.com.daypage.app.localqa`; never grant the QA app access to `com.daypage.app`'s production group. This needs no distribution certificate or Apple-account provisioning change. Retain the build and entitlement receipts with test artifacts.

The unentitled build is also useful as an explicit negative test: opening AI setup must show inline Retry, keep the typed key/question and avoid a root alert. Confirm the `ai-key-unavailable-inline` test attachment and retry activity before claiming that branch ran. The properly entitled QA run separately exercises real Simulator Keychain save, delete and reopen behavior. Neither is physical-device Keychain acceptance.

When the managed local device is occupied, the existing Local iOS notebook workflow has an optional `native_ui` manual input. It runs the same unsigned recovery and fully signed UI matrix on an isolated macOS runner using `scripts/qa/run_local_native_ci.sh`, a runner-owned loopback fixture and synthetic QA data. It is disabled for ordinary PR/push runs. Receipts and XCTest evidence are retained for seven days; build products, real credentials and distribution steps are excluded. Run it explicitly with `gh workflow run ios-local.yml --ref <branch> -f native_ui=true` and check the exact-source receipt before accepting the result.

## Verification recorded for GET-326

- Complete DayPageCore suite: 29 tests passed, including legacy separators, unknown YAML preservation, 80 concurrent appends from two stores, invalid import isolation, nested export/import recovery, chat editor leases, Chinese retrieval, endpoint boundaries and request shape.
- Primary iPhone Simulator: 6 UI tests passed on the final source, including offline save/relaunch/edit, sidebar destinations, dark archive, accessibility-size navigation, unconfigured chat and explicit loopback chat/reopen persistence.
- Active-project dependency contracts: 2 tests passed. Repository doctor, local iOS facade checks and 24 CI script tests passed.
- Independent review: no remaining P0/P1/P2 findings after regression fixes.
- Compact iPhone was not run: the shared-session tool refused to start it while an already-running Primary iPhone was present. That shared device was preserved.

No physical device, real provider, signed-device Keychain, real iCloud File Provider migration or new TestFlight distribution was accepted in this task. The old [cloud source archive](https://github.com/getyak/daypage/releases/tag/archive/cloud-2026-10-30) is separate from the new app's build evidence.
