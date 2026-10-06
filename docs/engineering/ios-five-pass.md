# iOS five-pass verification runner

`scripts/ci/run_ios_five_pass.py` is a bounded, deterministic local runner that
repeats the **existing** iOS and DayPageKit test suites five (or more) times in
strict serial order to surface flakiness and regressions for the current iOS
deep product audit. It is repetition of the registered regression suite —
**not** feature coverage, **not** a UI audit, **not** a release gate.

## Serialized Swift Testing fixture root

All Swift Testing suites in `DayPageTests` are nested under one explicit root in
`DayPageTests/SmokeTest.swift`:

```swift
@Suite("DayPageSerialSwiftTests", .serialized)
struct DayPageSerialSwiftTests {}
```

Every suite type (including implicit suites without `@Suite`) is declared in
`extension DayPageSerialSwiftTests` across files, with top-level
`typealias X = DayPageSerialSwiftTests.X` aliases preserving global names for
helpers, extensions (`extension SearchServiceTests`), and qualified references.
This exists because suites that can overlap share
`VaultInitializer.testOverrideURL`: per-suite `.serialized` only serializes
within one suite, and `@MainActor` can re-enter at `await`, while xcodebuild
`-parallel-testing-enabled NO` does not prove in-process task-group
serialization. The parent verified the shared-root design across five real-host
rounds (three peer suites, nine async parameterized cases,
`maximumConcurrent=1` every round; removing the root's `.serialized` yielded
nine concurrent cases), plus alias-plus-extension trait inheritance
(`evidence/serial-probe` in the parent's report tree). The parent also completed
an actual Debug Simulator `build-for-testing` with this arrangement. Execution
and user-feature acceptance remain separate gates.

Note: test identifiers are now nested (e.g.
`DayPageTests/DayPageSerialSwiftTests/MemoSyncE2EIntegrationTests`), so
`-only-testing:` selectors must use the nested path.

## What one run does

1. Validates the caller artifact directory against the real dev-storage-guard
   registry (`~/.local/state/dev-storage-guard/artifacts.list`) with an
   independent own-ROOT validation: the resolved root must be **exactly** a
   registered entry (all comparisons on physical/symlink-resolved paths),
   symlink traversal into the repository work tree is refused, output
   boundaries must be outside the work tree and not nested with any other
   registered artifact root, and the root must contain no foreign Git marker
   (`.git` outside the official guard's SPM
   `SourcePackages/(checkouts|repositories)` exception). A fresh uniquely-owned
   run child (`five-pass-run-<utc>-<token>/`) is created inside the registered
   artifact directory; logs, bundles, receipts and reports are exclusively
   created and existing runs are never overwritten.
2. Freezes an exact source receipt: HEAD SHA, dirty paths, SHA-256 of the
   tracked diff content, SHA-256 of every untracked file's content, and SHA-256
   of ignored/config build inputs (`GeneratedSecrets.swift` when present,
   `project.pbxproj`, `Package.swift`, `Package.resolved` pins,
   `.swiftlint.yml`). Hashes only are recorded — never file contents or
   secrets. The receipt is verified after the build and after **each** round;
   any source change (including an already-dirty file edited to different
   content) stops the run immediately so a stale build is never re-used.
3. Runs `dev-storage-guard audit` before the heavyweight native session and
   classifies its output **fail-closed** against the known guard schema. Hard
   blockers (free space below 30 GiB, rogue simulator devices or Compose
   projects outside allowlist, missing/mismatched target allowlist entry,
   unknown/partial/duplicate/inconsistent output, unexpected exit codes or
   tool errors) stop the session with the concrete blocker lines. Known
   global housekeeping — foreign tasks' aged/unregistered/unsafe-Git
   artifacts and the Codex session-log budget — is retained as visible
   warnings and tolerated only after the own-root validation in step 1 proved
   the warnings attributable to foreign tasks. The raw exit code and full
   output are always preserved in the `guard_audit` log; a raw exit 2 is
   labelled **audit warning**, never a pass. Nothing is ever cleaned and the
   runner has no force/ignore flags. A missing non-target allowlist profile is
   informational when the official tool returns 0; it remains a visible warning.
4. Resolves the one primary simulator from the real
   `~/.config/dev-storage-guard/simulator-allowlist.tsv` (default profile
   `primary` = **Primary iPhone**) and pins the same UDID to both
   `dev-ios-session` and xcodebuild. Caller-supplied arbitrary devices are
   refused. Devices are never booted, created, erased, cloned or deleted here —
   lifecycle belongs to `dev-ios-session`.
5. Runs **one** `xcodebuild build-for-testing`, then **N ≥ 5 serial**
   `xcodebuild test-without-building` rounds (unique `.xcresult` per round,
   `-parallel-testing-enabled NO`, `-maximum-concurrent-test-simulator-destinations 1`),
   then **N ≥ 5 serial** `swift test --no-parallel --jobs 2` DayPageKit rounds
   reusing one scratch path (`<run>/SourcePackages`, so its SPM
   checkouts/repositories stay inside the official guard's SPM exception).
   Native and Kit rounds never overlap.

Every native command is routed through:

```sh
"$HOME/.local/bin/dev-ios-session" run --profile primary --udid <UDID> \
    --reason "..." -- <xcodebuild|swift test ...>
```

Only read-only `git` (receipt), `xcrun xcresulttool` (result parsing) and
`dev-storage-guard audit` run outside the helper.

Native commands select the Debug isolated unit host with
`DAYPAGE_QA_BUNDLE_SUFFIX=.qa-unit`,
`DAYPAGE_UNIT_TEST_CONDITIONS=DAYPAGE_ISOLATED_TEST_HOST`, empty
`CODE_SIGN_ENTITLEMENTS`, and `CODE_SIGNING_ALLOWED=NO`. They preserve package
compilation conditions. See [unit-host isolation](ios-unit-host-isolation.md)
for the required processed-product inspection and dummy-account Keychain probe.
The runner does not provision signing or prove that probe. Unsigned Keychain
skips retain incomplete coverage; resolve signing and independently pass the
probe before running credential-name tests in an acceptance session.

## Invocation

```sh
python3 scripts/ci/run_ios_five_pass.py \
  --repo-root . \
  --artifacts /registered/artifact/dir \
  --profile primary \
  --rounds 5 \
  --kit-rounds 5
```

| Flag | Meaning |
|---|---|
| `--artifacts` | Caller-registered absolute artifact directory (must be listed in `artifacts.list`). A fresh uniquely-owned run child is created inside. |
| `--profile` | `primary` (default, Primary iPhone), `compact`, or `ipad` — resolved against the real simulator allowlist. |
| `--udid` | Optional pin; must equal the allowlist entry for the profile. |
| `--rounds` / `--kit-rounds` | Minimum **5** each; lower values are rejected before any command runs. |
| `--scheme`, `--configuration`, `--only-testing`, `--session-helper` | As named; only Debug is accepted because the isolated host and test seams are DEBUG-only. |

Exit codes: `0` pass, `1` run failed (including audit blockers, source drift,
KeyboardInterrupt/OSError/missing tool — all preserve a failure report), `2`
usage/precondition error.

## Evidence layout

```
<artifacts>/five-pass-run-<utc>-<token>/
  run-owner.json          # exclusive-created ownership marker
  source-receipt.json     # frozen at start; written once, never overwritten
  checkpoints.log         # after_build + after_each_round identity verification
  five-pass-report.json   # verdict, per-round results, commands, checkpoints
  five-pass-report.md     # human summary incl. disclaimers
  logs/NNN-<role>.log     # exact argv/cwd/exit/stdout/stderr per command
  native/build.xcresult
  native/round-01.xcresult ...
  DerivedData/
  SourcePackages/        # reused swift test scratch (inside the guard's SPM exception)
```

## Verdict semantics (fail closed)

A run passes **only** when the guard audit is executed with no hard blockers
(raw exit 0, or raw exit 2 attributed entirely to known global housekeeping
and labelled **audit warning**), `build-for-testing` passes, every native
round and Kit round passes, and the source identity is byte-stable at every
checkpoint.

- **Native counts** must be explicit and complete from `xcresulttool`
  (`totalTests`/`passedTests`/`failedTests`/`skippedTests` present and
  internally consistent). Missing, malformed, incomplete, inconsistent, zero
  or **all-skipped** counts all fail the round; reported failures fail the
  round even when the exit code is 0. Skips are retained distinctly and always
  mark coverage as incomplete — a run with skips is never presented as complete
  acceptance.
- **Kit counts**: the **last** aggregate XCTest `Executed …` line is used
  (repeated per-suite/overall lines are never summed), combined with the final
  Swift Testing `Test run with …` summary from both stdout and stderr, including
  its suite count. Swift Testing's `passed` summary includes disabled tests;
  explicit test-level skips are deducted, without double-counting suite skips.
  Swift Testing skip accounting is scoped to the real Swift Testing section
  starting at `◇ Test run started.` (synthetic logs without the marker fall
  back to the output after the last aggregate XCTest line), so XCTest
  `Test Case '…' skipped (…)` and `… : Test skipped - Set …` lines can never
  contaminate it — real mixed XCTest+Swift Testing logs parse to their true
  combined counts instead of failing closed.
  A failed run or unknown format fails closed without inventing an exact number
  of failed tests. Missing,
  zero or all-skipped counts fail; a non-zero exit always fails; exit 0 alone
  never proves tests ran.
- **Guard audit classification** is strict to the known `dev-storage-guard
  audit` output schema; unknown, partial, duplicate or internally
  inconsistent output blocks. Foreign artifact warnings are tolerated only
  behind the independent own-root validation (exact registry membership,
  physical path/symlink handling, non-workspace/non-other-artifact output
  boundaries, no foreign Git marker beyond the official SPM
  `SourcePackages/(checkouts|repositories)` exception); reports always record
  the raw audit exit code, retain every warning verbatim, label a raw exit 2
  as `audit warning`, and never call it a pass.
- Test-ID inventory (from `xcresulttool get test-results tests`) is compared
  across rounds where feasible; a differing inventory fails the run, and when
  IDs are unavailable the report states that verification limit explicitly.
- A failed round is recorded `fail` — never skipped or downgraded — and the
  remaining rounds still run to preserve evidence. Source drift is the
  exception: it **stops** the run (later rounds `not_run`) so an old build is
  never re-used.
- Keyboard interrupts, OS errors and missing tools end the run with a
  preserved failure report. Only test results decide the verdict; UI
  navigation success alone is never a pass.

## Coverage and limitations — what this gate is and is not

| Gate | Status |
|---|---|
| Regression-suite repetition (this runner) | Implemented; dry-tested with mocks; native repetition runs belong to the parent's session |
| DayPageTests membership + serialized-root namespace | Deterministic hard gates over all 66 registered test files and the serialized root; missing registration or namespace fails, including complete removal |
| Tiny serial probe (root architecture) | Parent-run, five real-host rounds (`evidence/serial-probe`) |
| UIKit/real compilation of the moved suites | Parent's Debug Simulator build passed; runtime acceptance remains separate |
| Dry tests (this runner's own behavior) | Mocked subprocess + temp fixtures only; no Simulator |
| Complete user-function acceptance | **Not claimed** — see disclaimers |

Every report disclaims, and this document reiterates:

- regression-suite repetition only; it does **not** cover every product
  feature;
- no real authentication, real AI/LLM, real sync/backends or hardware
  (camera, microphone, photos, location, Watch, widgets) verification;
- a PASS is not complete user-function acceptance and not a release gate.

Native runtime, disk, signing and service requirements are checked against the
actual execution environment. Missing isolated sync configuration remains a
real skip; no historical environment report substitutes for current checks.

## Test registration scope

`DayPage.xcodeproj` registers all 66 Swift files under `DayPageTests/` in the
`DayPageTests` target (issue #830 scope), so repetition exercises the full
registered suite. Orphan-test fixes already accepted: DST noon `11/23`
(`DayProgressTests`), POSIX long-form date (`MarkdownExportServiceTests`),
`@MainActor` for `EntityPageService` access (`EntitySlugDedupTests`), and
`@testable import DayPageServices` for the internal `WeatherService.init(testing:)`
seam (`WeatherServiceCacheTests`).

The membership and serialized-root namespace contract tests are mandatory.
They fail when registration or the serialized root is missing, including total
feature removal; they never skip to accommodate a partial checkout.

## Dry tests

```sh
python3 -m unittest discover -s scripts/ci/tests -p test_ios_five_pass.py
```

Covered contracts (all with mocked subprocesses and temp fixtures): minimum
rounds enforced before any command; build failure prevents all testing; no
skip-on-failure misreporting; native fail-closed counting (incomplete,
inconsistent, zero, all-skipped, malformed, unavailable); Kit last-aggregate
and combined-summary counting with real failure scenarios; mixed
XCTest+Swift Testing logs (sanitized fixture plus inline real-log shapes) with
Swift Testing skip scoping and preserved unknown/suite-skip rejection; audit
exit-2 fail-closed classification (true unsafe blocks vs. tolerated foreign
housekeeping warnings, raw exit preserved, `audit warning` labelling, strict
schema rejection of unknown/partial/duplicate/inconsistent output); own-root
validation (exact registry membership, nested-root refusal, foreign Git
markers with the official SPM exception); serial execution
with unique result bundles, one reused Kit scratch path and `--no-parallel
--jobs 2`; content-bound source receipt with adversarial mid-run change
detection (untracked content and tracked diff); guard registry/allowlist
validation, symlink refusal, audit blocker gating and Primary iPhone default;
never-overwrite evidence; Keyboard interrupt / missing tool failure
preservation; session-helper routing with no device lifecycle commands;
disclaimers; test-ID inventory stability; and the DayPageTests membership plus
serialized-root namespace contracts (missing or partially removed production
state is a failure, with no skip-on-absence exception).
