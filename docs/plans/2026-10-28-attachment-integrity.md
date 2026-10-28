# Attachment integrity follow-up (#884)

Status: implementation and isolated verification complete; review, hosted checks,
real-account round-trip and release verification remain open.

The 2026-10-28 audit identifies the remaining gap as current live acceptance, not
an absent attachment protocol. ADR-0016 and ADR-0025 remain authoritative.

## Accepted scope

- Preserve memo IDs, original text, creation time, attachment order, metadata and
  every attachment byte across an isolated source and second empty Vault.
- Reject missing, truncated, corrupt, duplicate or foreign attachment data without
  overwriting a valid file or claiming complete synchronization.
- Preserve pending obligations across interrupted transfers and reject effects
  after a session lease is invalidated.
- Keep downloads and staging inside the selected Vault, including when a local
  directory is replaced by a symlink.

Owned paths: attachment transfer/downloader services, focused attachment and live
acceptance tests, and this verification document. No UI, personal Vault, unrelated
performance work, dependencies, schema migrations or persistent-format changes.

## Risk and verification

Downloaded bytes are verified, but the current write destination uses a lexical
prefix check. A symlink in a destination or staging ancestor may bypass the Vault
boundary. Reproduce in temporary Vaults first; preserve foreign sentinel bytes.

The regression run reproduced writes outside the Vault through `raw` and
`raw/assets/sync`, installation of a symlinked partial as transferred, and
rewriting a foreign transfer sidecar through `_agent/sync`. The shared attachment
path guard now refuses those entries and rechecks after network waits. Existing
safe local media reading remains compatible. Malformed manifest sizes are also
bounded before summing, preventing an integer-overflow process crash.

Use focused Swift tests before broader gates. Coordinate the Swift suite and iOS
build with the lead. Real HTTP round-trip evidence must be recorded separately
from injected transport tests and Simulator/physical-device acceptance. Existing
user data is never a fixture, and live acceptance may address only controlled
memo IDs and objects owned by the default test account.

Rollback: revert the client fix while preserving raw files, sidecars, remote
objects and manifests. No data cleanup or format migration is part of rollback.

## Recorded local gates

- Red: three download containment tests failed with eight assertions; the
  sidecar containment test failed with three assertions; two `Int64.max`
  descriptor sizes terminated the test process with signal 5.
- Green: 89 focused attachment/session/pull/completion tests passed.
- Final package suite: 505 XCTest cases (three environment-gated live cases
  skipped), plus 84 Swift Testing cases; zero failures.
- Agent repository contract check and `git diff --check` passed.

The live JPEG/M4A test uses real v2 RPC/Storage uploads and a test-only REST
projection filtered by the task's exact memo UUID and owner. This includes the
actual committed v2 manifest and drives the native pull decoder/downloader.
It compares memo ID, original creation time and text, attachment order/metadata,
size and SHA-256, and decodes the received image/audio. A query-boundary test
ensures the adapter never requests the account feed. A high-water mark alone
would still read concurrent notes; `sync_change_sequence` has no unique
constraint, so a single-row cursor probe is not used as a privacy guarantee.
This scoped acceptance does not prove the deployed account-wide pull RPC or
physical/version compatibility. Existing isolated RPC regressions are retained.
Running the live command remains a separate, explicitly targeted gate; skipped
cases above do not prove it.

DP-02 and DP-03 already have later fixes on main. Existing local-reset and
diagnostics-consent tests passed in the package suite; no duplicate architecture
change was made for those historical audit items. Actual App Store review and
physical-device acceptance are separate outcomes.
