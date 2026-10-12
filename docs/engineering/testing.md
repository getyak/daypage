# Testing and evidence

`make check` aggregates non-Simulator repository gates. Use scoped gates during
implementation and run the full relevant integration gate before handoff.

| Scope | Stable command |
|---|---|
| Agent/docs contracts | `make check-agent` |
| Script fixtures | `make check-scripts` |
| DayPageKit | `make check-kit` |
| Web | `make check-web` |
| Android | `make check-android` |
| MCP server | `make check-mcp` |
| Cross-platform wire contracts | `make check-contracts` |
| Agentry | `make check-agentry` |
| Localization | `make check-localization` |
| Design tokens | `make check-tokens` |
| iOS build/test | `make check-ios` |
| iOS build only | `make build-ios` |
| Non-Simulator aggregate | `make check` |

Direct focused commands remain useful:

```sh
swift test --package-path DayPageKit
pnpm --filter daypage-web lint
pnpm --filter daypage-web typecheck
(cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug)
pnpm --filter daypage-mcp-server test
(cd agentry && go test ./... && go vet ./... && go build ./...)
```

## iOS reliability regressions

Use an isolated temporary Vault for mutation/recovery tests. Today persistence
tests await `waitForMemoPersistence()` and submission completion before removing
the Vault; `observeChanges: false` disables unrelated global notifications in
unit fixtures. Simulator UI verification keeps normal observers enabled.

- `TodayViewModelTests` and `MemoRecordStoreTests` cover ID-based mutation,
  concurrent append preservation, ordered undo, captured Vault roots and failed
  writes. Delete undo restores the record actually removed from disk.
- `InflightDraftStoreTests` cover retained recovery records, occupied composers,
  attachment-only recovery and exact acknowledgement after durable saves.
- `RemoteApplyRecoveryTests` interrupt each durable conflict boundary and replay
  from disk, including moved-day records and startup outbox reconciliation.
- `AccountSyncStatusTests` distinguish an empty upload queue from a verified
  push-and-pull pass, and cover failure, retry and restart.
- `check-localization` checks locale parity, static dotted-key references and
  supported printf placeholders. Dynamic keys and raw display text remain outside
  this static check. Its fixture tests run in `check-scripts`.

## iOS Simulator gates

`make check-ios` and `make build-ios` route through `scripts/ci/ios-local.sh`
so every local macOS invocation shares one device policy:

| Action | Destination | Notes |
|---|---|---|
| `make check-ios` | one selected Simulator | single worker, XCTest `-only-testing` optional |
| `make build-ios` | `generic/platform=iOS Simulator` | never selects or boots a device |

`check-ios` always passes `-parallel-testing-enabled NO` and
`-maximum-concurrent-test-simulator-destinations 1`, writes into the explicit
`DERIVED_DATA` path, and only adds `-resultBundlePath` when
`IOS_RESULT_BUNDLE_PATH` is set. `IOS_ONLY_TESTING` runs a single explicit
selector; leaving it unset keeps the scheme's full default test scope (which
includes the `DayPageTests` target).

```sh
# Full scheme test action on the daily primary device.
make check-ios

# One affected selector while iterating.
make check-ios IOS_ONLY_TESTING=DayPageTests/SomeTests/testExample

# Registered artifact path for the parent to collect.
make check-ios IOS_RESULT_BUNDLE_PATH=build/TestResults.xcresult

# Serialized build only; no Simulator is selected or booted.
make build-ios DERIVED_DATA=build/DD
```

### Device profiles and selection policy

`scripts/ci/select_simulator.py` picks the daily primary device:

- Numbered modern iPhones (`iPhone 16`, `iPhone 17 Pro`, ...) are preferred over
the `iPhone SE` line, even when the SE is on a newer runtime.
- Within the numbered pool the runtime is ranked descending first, then the
numeric model, then a stable natural-name tie-break. The SE pool is only used
when no numbered iPhone is available.
- Booted and unavailable devices still have to be iPhones; iPads never enter the
default phone pool.
- An unknown, unavailable, or wrong-family device never falls back to another
device or to `--fallback-name`; the remote CI `--fallback-name` path is
unchanged for a payload with no iPhone at all. Non-iOS runtimes are ignored.
- `--profile ipad` requires an actual iPad, so the default phone pool is never
silently broadened. An explicit iPhone SE is still allowed for the standalone
primary profile; the shared host policy constrains the session device separately.

Profiles are `primary` (default daily), `compact` (smaller device), and `ipad`.
The shared session helper owns profile-specific device selection and exports the
chosen device as `IOS_SIMULATOR_ID`; the selector only validates that choice and
provides the CI fallback.

### Shared device-session helper (opt-in)

On a macOS host the wrapper looks for the shared helper at `$DEV_IOS_SESSION_BIN`
or `~/.local/bin/dev-ios-session`. When present:

- An explicit `DEV_IOS_SESSION_BIN` must be executable, otherwise the gate
fails closed instead of falling back to another helper or running unguarded.
- Implicit `~/.local/bin/dev-ios-session` discovery only happens on Darwin.
- It asks `dev-ios-session is-owner` whether the current process already belongs
to an owned session. Ownership (not the mere presence of `DEV_IOS_SESSION_PID`,
`IOS_SIMULATOR_ID`, or `SIMULATOR_UDID`) decides nesting.
- A non-owner re-enters through `dev-ios-session run -- bash
scripts/ci/ios-local.sh <action>`, which selects the `DEV_IOS_PROFILE` device and
serializes the heavy build/test behind one lock. `DEV_IOS_REASON` is forwarded
for audit.
- Other hosts, missing helpers, and `CI=true` run the action directly with no
external dependency. The wrapper never boots a Simulator itself; `build-ios`
never touches `simctl`.

The helper is host tooling and is not implemented in this repository. `PROJECT`,
`SCHEME`, `DERIVED_DATA`, `PYTHON`, and the other gate inputs stay overridable
from the `make` command line or environment; the Makefile exports them through
the process environment, so spaces and shell metacharacters in values such as
`DEV_IOS_REASON` are data and are never re-interpolated into a recipe shell.

```sh
# Force an iPad session locally (helper) or an explicit iPad id (selector).
DEV_IOS_PROFILE=ipad DEV_IOS_REASON="ipad layout check" make check-ios
DEV_IOS_PROFILE=ipad IOS_SIMULATOR_ID=<udid> make check-ios

# Validate a requested device without running a build.
xcrun simctl list devices available --json \
  | python3 scripts/ci/select_simulator.py --format destination --udid <udid>
```

## Evidence rules

- Capture the exact command, working directory, environment identity, result, and
  non-sensitive artifact paths.
- Do not claim a skipped or blocked command passed.
- iOS UI changes require the app running in Simulator; SwiftUI preview is insufficient.
- Web interaction changes require an affected browser flow at relevant viewport sizes.
- Storage changes require an isolated vault and inspection of actual YAML/Markdown.
- Verification that mutates a fixture, Simulator, or local database must prove restoration.
- Screenshots/logs must not expose vault content, credentials, tokens, or personal paths.

Use `.agents/schemas/evidence.schema.json` for portable evidence records.
