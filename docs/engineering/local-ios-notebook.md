# Local iOS notebook

Open `DayPageLocal/DayPageLocal.xcodeproj`, scheme `DayPage`. This is the active iOS app. The root `DayPage.xcodeproj` remains the legacy multi-client project.

The application stores notes as Markdown at `Documents/vault/raw/YYYY-MM-DD.md`, with attachments under `raw/assets`. It does not require a DayPage account, backend or database. It reads existing local files without migration. Import in Settings copies a downloaded older Vault into a separate namespace; the source stays untouched. Exports contain original files, imported notes and local conversations. Keep an independent copy of an old iCloud Vault until the imported result has been checked.

Configure a compatible AI address and model in Settings. Leave the key blank for anonymous local servers; enter a key for services that require one. Keys are device-only Keychain items scoped to service origin, and changing the model does not change that origin. For a model running on a computer, use the computer's LAN address rather than the iPhone's localhost. Local HTTP must be explicitly enabled. A connection test sends no notes. Note chat displays the excerpts that will be sent and opens a network request only after Send.

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

## Verification recorded for GET-326

- Complete DayPageCore suite: 29 tests passed, including legacy separators, unknown YAML preservation, 80 concurrent appends from two stores, invalid import isolation, nested export/import recovery, chat editor leases, Chinese retrieval, endpoint boundaries and request shape.
- Primary iPhone Simulator: 6 UI tests passed on the final source, including offline save/relaunch/edit, sidebar destinations, dark archive, accessibility-size navigation, unconfigured chat and explicit loopback chat/reopen persistence.
- Active-project dependency contracts: 2 tests passed. Repository doctor, local iOS facade checks and 24 CI script tests passed.
- Independent review: no remaining P0/P1/P2 findings after regression fixes.
- Compact iPhone was not run: the shared-session tool refused to start it while an already-running Primary iPhone was present. That shared device was preserved.

No physical device, real provider, signed-device Keychain, real iCloud File Provider migration or new TestFlight distribution was accepted in this task. The old [cloud source archive](https://github.com/getyak/daypage/releases/tag/archive/cloud-2026-10-30) is separate from the new app's build evidence.
