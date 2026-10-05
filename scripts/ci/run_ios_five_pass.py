#!/usr/bin/env python3
"""Bounded five-pass iOS + DayPageKit regression-suite repetition runner.

This runner is intentionally narrow. It re-runs the *existing* registered test
suites five (or more) times in a fixed, serial order to surface flakiness and
regressions for the iOS deep product audit. It is repetition of the registered
regression suite — NOT feature coverage, NOT a UI audit, NOT a release gate.

What one run does:

  1. Validates the caller artifact directory against the real dev-storage-guard
     registry (`artifacts.list`), resolves the real repo/artifact paths, refuses
     symlink traversal into the repository and unregistered directories, and
     creates a fresh uniquely-owned run child (evidence is never overwritten).
  2. Freezes an exact source receipt: HEAD SHA, dirty paths, SHA-256 of the
     tracked diff content, SHA-256 of every untracked file (hashes only, no
     content/secrets recorded), and SHA-256 of relevant ignored build inputs
     (GeneratedSecrets.swift when present, project file, package pins/config).
     The receipt is verified after the build and after EACH round; any source
     change stops the run immediately so an old build is never re-used.
  3. Runs `dev-storage-guard audit` before the heavyweight native session and
     classifies its output fail-closed (see verdict semantics below): real
     blockers stop the session, known global housekeeping stays as visible
     warnings, and nothing is ever cleaned.
  4. Resolves the one primary simulator from the real
     `simulator-allowlist.tsv` (default: Primary iPhone) and cross-checks the
     dev-ios-session selection — caller-supplied arbitrary devices are refused.
  5. Runs ONE `xcodebuild build-for-testing`, then N >= 5 serial
     `xcodebuild test-without-building` rounds (unique `.xcresult` per round,
     simulator parallelization and clones disabled), then N >= 5 serial
     `swift test --no-parallel --jobs 2` DayPageKit rounds reusing one scratch
     path. Native and Kit rounds never overlap.

Every native command is routed through the session helper:

    "$HOME/.local/bin/dev-ios-session" run --profile ... --udid ... \
        --reason ... -- <command ...>

The session helper owns simulator/device lifecycle. This runner never boots,
creates, erases, clones or deletes devices and never calls `simctl`. Only
read-only `git` (receipt), `xcrun xcresulttool` (result parsing) and
`dev-storage-guard audit` run outside the helper.

Verdict semantics (fail closed):

  * Native rounds require explicit COMPLETE xcresult counts
    (totalTests/passedTests/failedTests/skippedTests all present and
    internally consistent): zero tests, all-skipped, incomplete, malformed or
    missing counts all fail the round. Skips are retained distinctly and are
    never reported as complete acceptance.
  * Kit rounds take the LAST aggregate XCTest summary (never summed across
    repeated lines), combine the final Swift Testing summary including its
    failures, and require executed/passed > 0 with zero failures. A non-zero
    exit always fails; exit 0 alone never proves tests ran. Swift Testing skip
    accounting is scoped to the real Swift Testing section (starting at
    "◇ Test run started.") so XCTest `Test Case ... skipped (...)` and
    `... : Test skipped - Set ...` lines can never contaminate it.
  * The dev-storage-guard audit is always executed with its real command; the
    raw exit code and full output are preserved. Non-zero audit exits are
    classified fail-closed against the known guard output schema: free space
    below the 30 GiB minimum, rogue simulator devices or Compose projects
    outside allowlist, a missing target allowlist entry, unknown/partial/
    duplicate/inconsistent output, and unexpected exit codes or tool errors
    all block the native session. Known global housekeeping (foreign tasks'
    aged/unregistered/unsafe-Git artifacts and the Codex session-log budget) is
    retained as visible warnings and tolerated ONLY after the runner's own
    registered artifact ROOT passes independent validation (exact registry
    membership, physical path/symlink handling, non-workspace/non-other-
    artifact output boundaries, no foreign Git marker beyond the official
    guard's SPM SourcePackages/(checkouts|repositories) exception). Nothing is
    ever cleaned and no force/ignore flags exist. A raw audit exit 2 is always
    labelled "audit warning" — never a pass.
  * Execution failures, interrupted runs, missing result bundles and source
    drift all fail the run. A failed round is recorded as failed — never
    skipped — and remaining rounds still run to preserve evidence, except
    source drift which STOPS the run so a stale build is never re-used.
  * Keyboard interrupts, OS errors and missing tools are preserved as failure
    reports; receipts and logs are exclusively created and never overwritten.
  * Test-ID inventory is compared across rounds where feasible; when the
    xcresult tool cannot provide IDs the report states that verification
    limit. Only test results decide the verdict — UI navigation success alone
    is never a pass.

Coverage disclaimer (emitted into every report):

  * regression-suite repetition only; it does NOT cover every product feature;
  * no real authentication, AI/LLM, sync/backend or hardware verification;
  * a PASS means the same registered tests passed in every round — it is not
    complete user-function acceptance and not a release gate.

Run the deterministic dry tests with:

    python3 -m unittest discover -s scripts/ci/tests -p test_ios_five_pass.py
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Callable, Sequence

TOOL_NAME = "run_ios_five_pass.py"
DEFAULT_SESSION_HELPER = str(Path.home() / ".local/bin/dev-ios-session")
DEFAULT_GUARD_TOOL = str(Path.home() / ".local/bin/dev-storage-guard")
DEFAULT_ARTIFACT_REGISTRY = str(Path.home() / ".local/state/dev-storage-guard/artifacts.list")
DEFAULT_SIMULATOR_ALLOWLIST = str(Path.home() / ".config/dev-storage-guard/simulator-allowlist.tsv")
MIN_ROUNDS = 5
DEFAULT_ROUNDS = 5
BUILD_ACTION = "build-for-testing"
TEST_ACTION = "test-without-building"
XCRESULT_TOOL = ("xcrun", "xcresulttool")

# dev-storage-guard audit schema (strict; known output only — anything
# unknown/partial/duplicate/inconsistent blocks). Mirrors the real
# `dev-storage-guard audit` output lines exactly.
GUARD_MIN_FREE_GIB = 30
GUARD_SESSION_BUDGET_GIB = 5.0
GUARD_FREE_RE = re.compile(r"^Free space: (\d+) GiB \(minimum (\d+) GiB\)$")
GUARD_SIM_RE = re.compile(r"^Simulator devices: (\d+) total, (\d+) outside allowlist$")
GUARD_COMPOSE_RE = re.compile(
    r"^Docker Compose projects: (\d+) active, (\d+) outside allowlist$")
GUARD_ARTIFACTS_RE = re.compile(
    r"^Registered test artifacts: (\d+) paths, (\d+\.\d) GiB "
    r"\((\d+) older than 24h, (\d+) unregistered, (\d+) unsafe Git roots\)$")
GUARD_SESSION_RE = re.compile(
    r"^Codex session logs: (\d+\.\d) GiB \(5\.0 GiB warning threshold\)$")
GUARD_ALLOWED_HEADER = "Allowed simulators:"
GUARD_ROW_OK_RE = re.compile(r"^  OK\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
GUARD_ROW_MISSING_RE = re.compile(r"^  MISSING\t([^\t]+)\t([^\t]+)$")
GUARD_SUMMARY_RES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("free_space", GUARD_FREE_RE),
    ("simulators", GUARD_SIM_RE),
    ("compose", GUARD_COMPOSE_RE),
    ("artifacts", GUARD_ARTIFACTS_RE),
    ("session_logs", GUARD_SESSION_RE),
)

# Swift Testing section start in real mixed `swift test` logs.
ST_SECTION_START_RE = re.compile(r"◇ Test run started\.")

# The official dev-storage-guard `unsafe_git_markers` exception: SPM package
# metadata under SourcePackages/(checkouts|repositories) is not a foreign Git
# marker. Foreign Git markers elsewhere in an artifact root mean the audit's
# unsafe-Git count cannot be attributed to foreign tasks.
GUARD_SPM_GIT_EXCEPTION_RE = re.compile(r"/SourcePackages/(checkouts|repositories)/")

# dev-ios-session profiles mapped to dev-storage-guard allowlist labels.
PROFILE_LABELS = {
    "primary": "Primary iPhone",
    "compact": "Compact iPhone",
    "ipad": "iPad",
}
DEFAULT_PROFILE = "primary"
DEFAULT_SESSION_REASON = "daypage ios five-pass regression-suite repetition"

# Simulator test parallelization and destination clones stay off; every
# test-without-building round runs serially on the one allowlisted device.
DISABLE_PARALLEL_FLAGS: tuple[str, ...] = (
    "-parallel-testing-enabled", "NO",
    "-maximum-concurrent-test-simulator-destinations", "1",
)

# Select an empty host before production App initialization or fixture setup.
# Conditions are added only by the App/test targets, never globally to SwiftPM.
UNIT_HOST_BUILD_FLAGS: tuple[str, ...] = (
    "DAYPAGE_QA_BUNDLE_SUFFIX=.qa-unit",
    "DAYPAGE_UNIT_TEST_CONDITIONS=DAYPAGE_ISOLATED_TEST_HOST",
    "CODE_SIGN_ENTITLEMENTS=",
    "CODE_SIGNING_ALLOWED=NO",
)

# Kit rounds: serial execution, bounded build parallelism, one reused scratch.
KIT_SERIAL_FLAGS: tuple[str, ...] = ("--no-parallel", "--jobs", "2")

# Tracked source identity is HEAD + diff content; these ignored/config inputs
# additionally gate builds and are hashed (never printed) when present.
BUILD_INPUT_PATHS: tuple[str, ...] = (
    "Config/GeneratedSecrets.swift",
    "DayPage/Config/GeneratedSecrets.swift",
    "DayPage.xcodeproj/project.pbxproj",
    "DayPageKit/Package.swift",
    "DayPageKit/Package.resolved",
    "DayPage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ".swiftlint.yml",
)

DISCLAIMERS: tuple[str, ...] = (
    "This runner is regression-suite repetition only: it re-runs the already "
    "registered DayPageTests/DayPageKit suites N times to surface flakiness and "
    "regressions. It does NOT cover every product feature.",
    "It does not verify real authentication, real AI/LLM calls, real sync or "
    "backends, or hardware (camera, microphone, photos, location, Watch, "
    "widgets). Those still require dedicated verification.",
    "A PASS means the same registered tests passed in every round. It is not "
    "complete user-function acceptance, not a UI audit, and not a release gate. "
    "Skipped tests (if any) are reported distinctly and mean coverage is "
    "incomplete wherever they occur.",
    "UI navigation success alone is never a pass: only test results (more than "
    "zero executed and passed tests, zero failures, every round) determine the "
    "verdict.",
    "Simulator/device lifecycle is owned by the session helper "
    "(dev-ios-session). This runner never boots, creates, erases, clones or "
    "deletes devices.",
)


class RunnerError(Exception):
    """Raised for usage/precondition problems (exit code 2)."""


@dataclasses.dataclass
class CommandResult:
    argv: tuple[str, ...]
    exit_code: int
    stdout: str
    stderr: str


@dataclasses.dataclass
class GuardPaths:
    """Guard inputs; production uses the real paths, tests inject fixtures."""

    guard_tool: str = DEFAULT_GUARD_TOOL
    artifacts_registry: str = DEFAULT_ARTIFACT_REGISTRY
    simulator_allowlist: str = DEFAULT_SIMULATOR_ALLOWLIST


@dataclasses.dataclass
class SourceIdentity:
    """Content-bound source identity; hashes only, never file contents."""

    sha: str
    dirty_paths: list[str]
    tracked_diff_sha256: str
    untracked_hashes: dict[str, str]
    build_input_hashes: dict[str, str]

    def to_json(self) -> dict[str, Any]:
        return {
            "sha": self.sha,
            "dirty": bool(self.dirty_paths),
            "dirty_paths": list(self.dirty_paths),
            "tracked_diff_sha256": self.tracked_diff_sha256,
            "untracked_hashes": dict(self.untracked_hashes),
            "build_input_hashes": dict(self.build_input_hashes),
        }

    def difference(self, other: "SourceIdentity") -> list[str]:
        """Concrete drift reasons between frozen and re-captured identity."""
        diffs: list[str] = []
        if self.sha != other.sha:
            diffs.append(f"HEAD moved: {self.sha} -> {other.sha}")
        if self.tracked_diff_sha256 != other.tracked_diff_sha256:
            diffs.append("tracked diff content changed (SHA256 mismatch)")
        for key in sorted(set(self.untracked_hashes) | set(other.untracked_hashes)):
            if self.untracked_hashes.get(key) != other.untracked_hashes.get(key):
                diffs.append(f"untracked file changed: {key}")
        for key in sorted(set(self.build_input_hashes) | set(other.build_input_hashes)):
            if self.build_input_hashes.get(key) != other.build_input_hashes.get(key):
                diffs.append(f"build input changed: {key}")
        if sorted(self.dirty_paths) != sorted(other.dirty_paths):
            diffs.append("dirty path set changed")
        return diffs


@dataclasses.dataclass
class RoundResult:
    kind: str  # "native" | "kit"
    index: int
    status: str  # "pass" | "fail" | "not_run"
    command: list[str] | None
    exit_code: int | None
    result_bundle: str | None
    tests: dict[str, Any] | None
    failures: list[str]
    log: str | None
    source_sha: str | None

    def to_json(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "round": self.index,
            "status": self.status,
            "command": list(self.command) if self.command else None,
            "exit_code": self.exit_code,
            "result_bundle": self.result_bundle,
            "tests": self.tests,
            "failures": list(self.failures),
            "log": self.log,
            "source_sha": self.source_sha,
        }


# ---------------------------------------------------------------------------
# Count parsing (strict; fail closed on anything incomplete)
# ---------------------------------------------------------------------------

def extract_xcresult_counts(payload: Any) -> dict[str, int] | None:
    """Complete test counts from `xcresulttool get test-results summary`.

    Returns counts ONLY when totalTests/passedTests/failedTests/skippedTests
    are all explicitly present as integers and the totals are internally
    consistent (total == passed + failed + skipped [+ expectedFailures]).
    Anything missing, malformed, zero or inconsistent returns None and must be
    treated as missing tests (fail closed) — never as a pass. Skips are
    retained distinctly; callers must require passed > 0 so all-skipped runs
    fail.
    """
    if not isinstance(payload, dict):
        return None

    def _int(key: str) -> int | None:
        value = payload.get(key)
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None

    total = _int("totalTests")
    passed = _int("passedTests")
    failed = _int("failedTests")
    skipped = _int("skippedTests")
    if None in (total, passed, failed, skipped):
        return None
    expected = _int("expectedFailures") if "expectedFailures" in payload else 0
    if expected is None:
        return None
    if total != passed + failed + skipped + expected:
        return None
    return {
        "total": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "expected_failures": expected,
    }


def _swift_testing_section(text: str) -> str:
    """Swift Testing section of (mixed) `swift test` output.

    Real XCTest+Swift Testing logs run XCTest first and start Swift Testing at
    the `◇ Test run started.` marker. Swift Testing skip detection is scoped to
    that section so XCTest `Test Case ... skipped (...)` and
    `... : Test skipped - Set ...` lines can never contaminate Swift Testing
    skip accounting. Minimal/synthetic logs without the marker fall back to the
    output after the last aggregate XCTest line (or the whole text when XCTest
    produced no aggregate), preserving their historical semantics.
    """
    marker = ST_SECTION_START_RE.search(text)
    if marker is not None:
        return text[marker.start():]
    xctest_lines = list(re.finditer(r"Executed [^\n]*", text))
    return text[xctest_lines[-1].end():] if xctest_lines else text


def parse_swift_test_counts(text: str) -> dict[str, int] | None:
    """Combined Kit counts from `swift test` output.

    XCTest: take the LAST aggregate `Executed N tests, with M failures` line —
    repeated per-suite/overall lines are never summed. Swift Testing: combine
    the FINAL `Test run with ...` summary (its failures are never hidden).
    Swift Testing skip accounting is scoped to the real Swift Testing section
    (see _swift_testing_section) so XCTest skip lines cannot contaminate it.
    Missing/all-skipped/zero counts return None or zero passed, which callers
    must fail on; exit 0 alone never proves tests ran.
    """
    total = passed = failed = skipped = 0
    seen = False

    xctest_lines = list(re.finditer(r"Executed [^\n]*", text))
    if xctest_lines:
        seen = True
        line = xctest_lines[-1].group(0)  # LAST aggregate summary only
        m = re.match(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", line)
        if m is None:
            return None
        x_total, x_skipped, x_failed = int(m.group(1)), int(m.group(2) or 0), int(m.group(3))
        if x_skipped > x_total:
            return None
        total += x_total
        failed += x_failed
        skipped += x_skipped
        passed += max(0, x_total - x_failed - x_skipped)

    swift_runs = list(re.finditer(r"Test run with [^\n]*", text))
    if swift_runs:
        seen = True
        # A failed run reports total tests and issues, not an exact failed-test
        # count. Refuse to fabricate counts or hide it behind green XCTest.
        for run in swift_runs:
            m = re.match(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed|skipped)\b", run.group(0))
            if m is None or m.group(2) == "failed":
                return None
        m = re.match(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|skipped)\b", swift_runs[-1].group(0))
        assert m is not None
        s_total = int(m.group(1))
        # Real Swift Testing includes disabled tests in a "passed" summary.
        # Count explicit test-level skips, rather than marking them executed.
        # Scoped to the Swift Testing section: XCTest skip lines must not leak.
        st_section = _swift_testing_section(text)
        s_skipped = len(re.findall(r"^.*?Test [^\n]*\bskipped(?:[.:]|$)", st_section, re.MULTILINE))
        if re.search(r"^.*?Suite [^\n]*\bskipped(?:[.:]|$)", st_section, re.MULTILINE) and not s_skipped:
            return None
        if re.search(r"^.*?Test [^\n]*\bskipped\b", st_section, re.MULTILINE) and not s_skipped and m.group(2) != "skipped":
            return None
        if m.group(2) == "skipped":
            s_skipped = s_total
        if s_skipped > s_total:
            return None
        total += s_total
        passed += s_total - s_skipped
        skipped += s_skipped

    if not seen:
        return None
    return {"total": total, "passed": passed, "failed": failed, "skipped": skipped}


def extract_test_ids(payload: Any) -> set[str]:
    """Best-effort stable test identifiers from `xcresulttool get test-results tests`."""
    ids: set[str] = set()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            ident = node.get("identifier")
            if isinstance(ident, str) and ident:
                ids.add(ident)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(payload)
    return ids


@dataclasses.dataclass
class GuardAuditReport:
    """Fail-closed classification of one `dev-storage-guard audit` invocation.

    status "pass"     -> raw exit 0 and a completely clean, schema-valid output;
    status "warning"  -> known global housekeeping or non-target simulator
                         information (raw exit 0 or 2; the caller's own
                         registered artifact ROOT passed the independent
                         own-root validation must pass; nothing is ever cleaned);
    status "blocked"  -> any hard blocker, schema problem, inconsistency or
                         unexpected exit/tool error.
    A raw exit 2 is never labelled "pass".
    """

    raw_exit_code: int
    status: str  # "pass" | "warning" | "blocked"
    blockers: list[str]
    warnings: list[str]
    parsed: dict[str, Any]

    def to_json(self) -> dict[str, Any]:
        return {
            "raw_exit_code": self.raw_exit_code,
            "status": self.status,
            "blockers": list(self.blockers),
            "warnings": list(self.warnings),
            "parsed": dict(self.parsed),
        }


def find_foreign_git_markers(root: Path) -> list[str]:
    """Non-package `.git` markers under an artifact root.

    Consistent with the official dev-storage-guard `unsafe_git_markers`
    predicate: `.git` under `SourcePackages/(checkouts|repositories)` is SPM
    package metadata and excluded; every other `.git` is a foreign Git marker
    that makes the audit's unsafe-Git count un-attributable to foreign tasks.
    Symlinked directories are not followed (matching `find` without `-L`).
    """
    markers: list[str] = []
    if not root.exists():
        return markers
    for dirpath, dirnames, filenames in os.walk(root):
        for name in [*dirnames, *filenames]:
            if name != ".git":
                continue
            path = str(Path(dirpath) / name)
            if not GUARD_SPM_GIT_EXCEPTION_RE.search(path):
                markers.append(path)
    return sorted(markers)


def classify_guard_audit(stdout: str, stderr: str, exit_code: int, *,
                         target_label: str, target_udid: str) -> GuardAuditReport:
    """Exact fail-closed classification of `dev-storage-guard audit` output.

    Only the known guard output schema is accepted; unknown, partial,
    duplicate or internally inconsistent output blocks. Hard blockers are:
    free space below the 30 GiB minimum, rogue simulator devices or Compose
    projects outside allowlist, a missing/mismatched target allowlist entry,
    schema problems, and unexpected exit codes or tool errors. Known global
    housekeeping (foreign tasks' aged/unregistered/unsafe-Git artifacts, the
    Codex session-log budget, and missing NON-target shared simulators) is
    retained as visible warnings and tolerated only after the caller's own
    registered artifact ROOT passed the independent own-root validation (exact
    registry membership, physical path/symlink handling, non-workspace/non-
    other-artifact output boundaries, no foreign Git marker beyond the
    official SPM exception) — see FivePassRunner._validate_registration.
    Nothing is ever cleaned and no force/ignore flags exist.
    """
    blockers: list[str] = []
    warnings: list[str] = []
    parsed: dict[str, Any] = {}
    raw_lines: dict[str, str] = {}
    ok_rows: dict[str, str] = {}
    missing_rows: list[tuple[str, str]] = []
    seen: set[str] = set()
    header_count = 0

    for line in stdout.splitlines():
        if not line.strip():
            continue
        matched = False
        for kind, pattern in GUARD_SUMMARY_RES:
            m = pattern.match(line)
            if m is None:
                continue
            matched = True
            if kind in seen:
                blockers.append(f"duplicate audit output line ({kind}): {line!r}")
            else:
                seen.add(kind)
                parsed[kind] = m.groups()
                raw_lines[kind] = line
            break
        if matched:
            continue
        if line == GUARD_ALLOWED_HEADER:
            header_count += 1
            if header_count > 1:
                blockers.append(f"duplicate audit output section: {line!r}")
            continue
        m = GUARD_ROW_OK_RE.match(line)
        if header_count == 1 and m is not None:
            label, _name, _state, udid = m.groups()
            if label in ok_rows or any(l == label for l, _ in missing_rows):
                blockers.append(f"duplicate simulator allowlist row: {line!r}")
            ok_rows[label] = udid
            continue
        m = GUARD_ROW_MISSING_RE.match(line)
        if header_count == 1 and m is not None:
            label, udid = m.groups()
            if label in ok_rows or any(l == label for l, _ in missing_rows):
                blockers.append(f"duplicate simulator allowlist row: {line!r}")
            missing_rows.append((label, udid))
            continue
        blockers.append(f"unknown audit output line: {line!r}")

    for kind, _pattern in GUARD_SUMMARY_RES:
        if kind not in seen:
            blockers.append(f"partial audit output: missing {kind} summary line")
    if header_count == 0:
        blockers.append("partial audit output: missing 'Allowed simulators:' section")

    if "free_space" in parsed:
        free = int(parsed["free_space"][0])
        minimum = int(parsed["free_space"][1])
        if minimum != GUARD_MIN_FREE_GIB:
            blockers.append(
                f"unexpected free-space minimum in audit output: {raw_lines['free_space']!r}")
        elif free < GUARD_MIN_FREE_GIB:
            blockers.append(
                f"free space below the required minimum: {raw_lines['free_space']!r}")
    if "simulators" in parsed:
        total = int(parsed["simulators"][0])
        outside = int(parsed["simulators"][1])
        if outside > total:
            blockers.append(
                f"inconsistent audit output (rogue devices exceed total): {raw_lines['simulators']!r}")
        if outside > 0:
            blockers.append(
                f"rogue simulator device(s) outside allowlist: {raw_lines['simulators']!r}")
    if "compose" in parsed:
        active = int(parsed["compose"][0])
        outside = int(parsed["compose"][1])
        if outside > active:
            blockers.append(
                f"inconsistent audit output (rogue Compose projects exceed active): {raw_lines['compose']!r}")
        if outside > 0:
            blockers.append(
                f"rogue Docker Compose project(s) outside allowlist: {raw_lines['compose']!r}")
    if "artifacts" in parsed:
        paths = int(parsed["artifacts"][0])
        aged = int(parsed["artifacts"][2])
        unregistered = int(parsed["artifacts"][3])
        unsafe = int(parsed["artifacts"][4])
        if aged > paths or unsafe > paths:
            blockers.append(
                f"inconsistent audit output (artifact counts exceed paths): {raw_lines['artifacts']!r}")
        if aged > 0:
            warnings.append(
                f"aged registered artifacts ({aged} older than 24h) — foreign/global "
                f"housekeeping, nothing cleaned: {raw_lines['artifacts']!r}")
        if unregistered > 0:
            warnings.append(
                f"unregistered artifact directories ({unregistered}) — foreign/global "
                f"housekeeping, nothing cleaned: {raw_lines['artifacts']!r}")
        if unsafe > 0:
            warnings.append(
                f"unsafe Git roots in registered artifacts ({unsafe}) — attributed to "
                f"foreign housekeeping after own-root validation, nothing cleaned: "
                f"{raw_lines['artifacts']!r}")
    if "session_logs" in parsed:
        session_gib = float(parsed["session_logs"][0])
        if session_gib > GUARD_SESSION_BUDGET_GIB:
            warnings.append(
                f"Codex session-log budget exceeded ({session_gib} GiB > "
                f"{GUARD_SESSION_BUDGET_GIB} GiB) — global housekeeping, nothing "
                f"cleaned: {raw_lines['session_logs']!r}")

    missing_labels = {label for label, _udid in missing_rows}
    if target_label in missing_labels:
        blockers.append(f"target allowlist entry missing (MISSING row for {target_label!r})")
    elif header_count == 1 and target_label not in ok_rows:
        blockers.append(f"target allowlist entry missing (no row for {target_label!r})")
    elif header_count == 1 and ok_rows.get(target_label) not in (None, target_udid):
        blockers.append(
            f"target allowlist UDID mismatch for {target_label!r}: audit row "
            f"{ok_rows[target_label]} != runner {target_udid}")
    # Only the guard's actual exit-triggering findings participate in exit
    # consistency. A missing non-target device is informational even at exit 0.
    exit_findings = bool(blockers) or bool(warnings)
    for label, udid in missing_rows:
        if label != target_label:
            warnings.append(
                f"non-target allowlist simulator missing ({label!r}, {udid}) — shared "
                f"machine housekeeping, nothing created or deleted")

    if stderr.strip():
        blockers.append(f"unexpected dev-storage-guard stderr output: {stderr.strip()[:200]!r}")
    if exit_code not in (0, 2):
        blockers.append(f"unexpected dev-storage-guard exit code {exit_code} (tool error)")
    elif exit_code == 0 and exit_findings:
        blockers.append("audit exit 0 contradicts parsed findings (inconsistent output)")
    elif exit_code == 2 and not exit_findings:
        blockers.append("audit exit 2 without recognizable findings (unknown output)")

    status = "blocked" if blockers else ("warning" if warnings else "pass")
    return GuardAuditReport(raw_exit_code=exit_code, status=status,
                            blockers=blockers, warnings=warnings, parsed=parsed)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_simulator_allowlist(text: str) -> dict[str, str]:
    """Parse dev-storage-guard simulator-allowlist.tsv -> {label: udid}."""
    labels: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0].strip() or not fields[1].strip():
            raise RunnerError(f"malformed simulator allowlist line {number}")
        udid, label = fields[0].strip(), fields[1].strip()
        if label in labels:
            raise RunnerError(f"duplicate simulator allowlist label {label!r}")
        labels[label] = udid
    if not labels:
        raise RunnerError("simulator allowlist is empty")
    return labels


class FivePassRunner:
    """Runs the bounded five-pass session and preserves all evidence."""

    def __init__(
        self,
        *,
        repo_root: Path,
        artifact_dir: Path,
        profile: str = DEFAULT_PROFILE,
        udid: str | None = None,
        rounds: int = DEFAULT_ROUNDS,
        kit_rounds: int = DEFAULT_ROUNDS,
        scheme: str = "DayPage",
        configuration: str = "Debug",
        session_helper: str = DEFAULT_SESSION_HELPER,
        only_testing: Sequence[str] = (),
        guard: GuardPaths | None = None,
        invocation_argv: Sequence[str] | None = None,
        run_cmd: Callable[[tuple[str, ...], Path], CommandResult] | None = None,
    ) -> None:
        self.repo_root = Path(repo_root).resolve()
        self.artifact_dir = Path(artifact_dir)
        self.profile = profile
        self.udid = udid
        self.rounds = rounds
        self.kit_rounds = kit_rounds
        self.scheme = scheme
        self.configuration = configuration
        self.session_helper = session_helper
        self.only_testing = tuple(only_testing)
        self.guard = guard or GuardPaths()
        self.invocation_argv = [sys.argv[0], *(
            list(invocation_argv) if invocation_argv is not None else sys.argv[1:]
        )]
        self._run_cmd = run_cmd or self._default_run_cmd
        self.commands: list[dict[str, Any]] = []
        self.round_results: list[RoundResult] = []
        self.checkpoints: list[dict[str, Any]] = []
        self._round_ids: dict[int, set[str]] = {}
        self._log_seq = 0
        self.run_dir: Path | None = None
        self.device_label: str | None = None
        self.device_udid: str | None = None
        self.guard_audit: GuardAuditReport | None = None

    # ------------------------------------------------------------------ I/O

    @staticmethod
    def _default_run_cmd(argv: tuple[str, ...], cwd: Path) -> CommandResult:
        proc = subprocess.run(
            list(argv), cwd=str(cwd), capture_output=True, text=True, check=False
        )
        return CommandResult(argv=argv, exit_code=proc.returncode,
                             stdout=proc.stdout, stderr=proc.stderr)

    def _invoke(self, role: str, argv: Sequence[str]) -> CommandResult:
        argv_t = tuple(argv)
        result = self._run_cmd(argv_t, self.repo_root)
        log_rel = self._write_log(role, result)
        self.commands.append({
            "role": role,
            "argv": list(argv_t),
            "exit_code": result.exit_code,
            "log": log_rel,
        })
        return result

    def _write_log(self, role: str, result: CommandResult) -> str:
        assert self.run_dir is not None
        logs_dir = self.run_dir / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        self._log_seq += 1
        name = f"{self._log_seq:03d}-{role}.log"
        source_diff = result.argv[:2] == ("git", "diff")
        stdout = ("<source diff omitted; sha256=" + hashlib.sha256(result.stdout.encode("utf-8")).hexdigest() + ">") if source_diff else result.stdout
        stderr = "<source diff diagnostics omitted>" if source_diff else result.stderr
        body = (
            f"# role: {role}\n"
            f"# argv: {shlex.join(result.argv)}\n"
            f"# cwd: {self.repo_root}\n"
            f"# exit_code: {result.exit_code}\n"
            f"# recorded_at: {_utc_now()}\n\n"
            f"--- stdout ---\n{stdout}\n"
            f"--- stderr ---\n{stderr}\n"
        )
        self._write_exclusive(logs_dir / name, body)
        return f"logs/{name}"

    @staticmethod
    def _write_exclusive(path: Path, text: str) -> None:
        """Create exclusively; never overwrite another run's evidence."""
        with path.open("x", encoding="utf-8") as fh:
            fh.write(text)

    # ------------------------------------------------------------- validate

    def validate(self) -> None:
        if self.configuration != "Debug":
            raise RunnerError("--configuration must be Debug for the isolated unit host")
        if self.rounds < MIN_ROUNDS:
            raise RunnerError(
                f"--rounds {self.rounds} is below the required minimum of {MIN_ROUNDS}"
            )
        if self.kit_rounds < MIN_ROUNDS:
            raise RunnerError(
                f"--kit-rounds {self.kit_rounds} is below the required minimum of {MIN_ROUNDS}"
            )
        if self.profile not in PROFILE_LABELS:
            raise RunnerError(
                f"unknown profile {self.profile!r}; expected one of {sorted(PROFILE_LABELS)}"
            )
        if not self.artifact_dir.is_absolute():
            raise RunnerError("--artifacts must be an absolute path (caller-registered)")
        self._validate_registration()
        self._resolve_device()

    def _validate_registration(self) -> None:
        """Independent own-ROOT validation against the real dev-storage-guard registry.

        Runs before any command and gates whether the audit's foreign artifact
        warnings can later be tolerated as global housekeeping:
          * exact registry membership — the resolved root is itself registered;
          * physical path/symlink handling — all comparisons on resolved paths;
          * output boundaries — outside the repository work tree and not
            nested with any other registered artifact root;
          * no foreign Git marker — the official guard's SPM
            SourcePackages/(checkouts|repositories) exception applies.
        """
        registry = Path(self.guard.artifacts_registry)
        if not registry.is_file():
            raise RunnerError(f"artifact registry not found: {registry}")
        entries: list[Path] = []
        for line in registry.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                entries.append(Path(line).resolve())
        resolved = self.artifact_dir.resolve()
        if self.repo_root == resolved or self.repo_root in resolved.parents:
            raise RunnerError(
                "--artifacts resolves inside the repository work tree "
                "(symlink traversal refused)"
            )
        if not any(resolved == entry for entry in entries):
            raise RunnerError(
                f"--artifacts {self.artifact_dir} does not resolve to an artifact "
                f"root registered exactly in {registry}"
            )
        for entry in entries:
            if entry == resolved:
                continue
            if entry in resolved.parents or resolved in entry.parents:
                raise RunnerError(
                    f"--artifacts {self.artifact_dir} is nested with another "
                    f"registered artifact root {entry} (output boundary refused)"
                )
        markers = find_foreign_git_markers(resolved)
        if markers:
            raise RunnerError(
                "registered artifact root contains foreign Git marker(s) "
                "(official SPM SourcePackages/(checkouts|repositories) exception "
                "applied): " + "; ".join(markers[:5])
            )

    def _resolve_device(self) -> None:
        """Resolve the primary device from the real dev-storage-guard allowlist."""
        allowlist = Path(self.guard.simulator_allowlist)
        if not allowlist.is_file():
            raise RunnerError(f"simulator allowlist not found: {allowlist}")
        labels = parse_simulator_allowlist(allowlist.read_text(encoding="utf-8"))
        label = PROFILE_LABELS[self.profile]
        if label not in labels:
            raise RunnerError(
                f"simulator allowlist has no entry labelled {label!r} for "
                f"profile {self.profile!r}"
            )
        udid = labels[label]
        if self.udid and self.udid != udid:
            raise RunnerError(
                f"requested --udid {self.udid} does not match allowlisted "
                f"{label} ({udid})"
            )
        self.device_label = label
        self.device_udid = udid

    def _open_run_dir(self) -> None:
        """Fresh uniquely-owned child inside the registered artifact directory."""
        root = self.artifact_dir.resolve()
        root.mkdir(parents=True, exist_ok=True)
        for _ in range(4):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            candidate = root / f"five-pass-run-{stamp}-{uuid.uuid4().hex[:8]}"
            try:
                candidate.mkdir()
            except FileExistsError:
                continue
            self.run_dir = candidate
            registration = {
                "registered_by": "caller",
                "registry": self.guard.artifacts_registry,
                "artifact_root": str(self.artifact_dir),
                "run_dir": str(candidate),
                "argv": list(self.invocation_argv),
                "cwd": os.getcwd(),
                "pid": os.getpid(),
                "registered_at": _utc_now(),
            }
            self._write_exclusive(candidate / "run-owner.json",
                                  json.dumps(registration, indent=2, sort_keys=True) + "\n")
            return
        raise RunnerError("could not create a fresh unique run directory")

    # ------------------------------------------------------- source identity

    def _capture_identity(self) -> SourceIdentity:
        head = self._invoke("receipt", ["git", "rev-parse", "HEAD"])
        if head.exit_code != 0:
            raise RunnerError(f"git rev-parse HEAD failed: {head.stderr.strip()}")
        status = self._invoke("receipt", ["git", "status", "--porcelain"])
        if status.exit_code != 0:
            raise RunnerError(f"git status failed: {status.stderr.strip()}")
        diff = self._invoke("receipt", ["git", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--"])
        if diff.exit_code != 0:
            raise RunnerError(f"git diff failed: {diff.stderr.strip()}")
        untracked = self._invoke("receipt", ["git", "ls-files", "--others", "--exclude-standard"])
        if untracked.exit_code != 0:
            raise RunnerError(f"git ls-files failed: {untracked.stderr.strip()}")

        dirty_paths = sorted(line[3:] for line in status.stdout.splitlines() if len(line) >= 4)
        untracked_hashes: dict[str, str] = {}
        for rel in sorted(untracked.stdout.splitlines()):
            rel = rel.strip()
            if not rel:
                continue
            path = self.repo_root / rel
            untracked_hashes[rel] = _sha256_file(path) if path.is_file() else "<not-a-file>"
        build_input_hashes: dict[str, str] = {}
        for rel in BUILD_INPUT_PATHS:
            path = self.repo_root / rel
            if path.is_file():
                build_input_hashes[rel] = _sha256_file(path)
        return SourceIdentity(
            sha=head.stdout.strip(),
            dirty_paths=dirty_paths,
            tracked_diff_sha256=hashlib.sha256(diff.stdout.encode("utf-8")).hexdigest(),
            untracked_hashes=untracked_hashes,
            build_input_hashes=build_input_hashes,
        )

    def _verify_identity(self, frozen: SourceIdentity, stage: str) -> list[str]:
        current = self._capture_identity()
        drift = frozen.difference(current)
        self._record_checkpoint(stage, not drift, drift)
        return drift

    def _record_checkpoint(self, stage: str, stable: bool, drift: Sequence[str]) -> None:
        self.checkpoints.append({
            "stage": stage,
            "at": _utc_now(),
            "stable": stable,
            "drift": list(drift),
        })
        assert self.run_dir is not None
        with (self.run_dir / "checkpoints.log").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(self.checkpoints[-1], sort_keys=True) + "\n")

    # ------------------------------------------------------------- commands

    def _helper_argv(self, body: Sequence[str]) -> list[str]:
        return [
            self.session_helper, "run",
            "--profile", self.profile,
            "--udid", str(self.device_udid),
            "--reason", DEFAULT_SESSION_REASON,
            "--", *body,
        ]

    def _build_argv(self, result_bundle: Path) -> list[str]:
        return self._helper_argv([
            "xcodebuild", BUILD_ACTION,
            "-project", "DayPage.xcodeproj",
            "-scheme", self.scheme,
            "-configuration", self.configuration,
            "-destination", f"platform=iOS Simulator,id={self.device_udid}",
            "-derivedDataPath", str(self.run_dir / "DerivedData"),
            "-resultBundlePath", str(result_bundle),
            *UNIT_HOST_BUILD_FLAGS,
        ])

    def _native_argv(self, result_bundle: Path) -> list[str]:
        body = [
            "xcodebuild", TEST_ACTION,
            "-project", "DayPage.xcodeproj",
            "-scheme", self.scheme,
            "-configuration", self.configuration,
            "-destination", f"platform=iOS Simulator,id={self.device_udid}",
            "-derivedDataPath", str(self.run_dir / "DerivedData"),
            "-resultBundlePath", str(result_bundle),
            *DISABLE_PARALLEL_FLAGS,
            *UNIT_HOST_BUILD_FLAGS,
        ]
        for target in self.only_testing:
            body.append(f"-only-testing:{target}")
        return self._helper_argv(body)

    def _kit_argv(self) -> list[str]:
        # The kit scratch is placed under a `SourcePackages` container so its
        # SPM checkouts/repositories `.git` markers fall inside the official
        # dev-storage-guard SPM exception — keeping the artifact root free of
        # foreign Git markers for audit-warning attribution on later runs.
        return self._helper_argv([
            "swift", "test",
            "--package-path", "DayPageKit",
            "--scratch-path", str(self.run_dir / "SourcePackages"),
            *KIT_SERIAL_FLAGS,
        ])

    def _xcresult_counts(self, bundle: Path) -> dict[str, int] | None:
        result = self._invoke(
            "xcresult_summary",
            [*XCRESULT_TOOL, "get", "test-results", "summary",
             "--path", str(bundle), "--format", "json"],
        )
        if result.exit_code != 0:
            return None
        try:
            payload = json.loads(result.stdout)
        except ValueError:
            return None
        return extract_xcresult_counts(payload)

    def _xcresult_test_ids(self, bundle: Path) -> set[str]:
        result = self._invoke(
            "xcresult_tests",
            [*XCRESULT_TOOL, "get", "test-results", "tests",
             "--path", str(bundle), "--format", "json"],
        )
        if result.exit_code != 0:
            return set()
        try:
            payload = json.loads(result.stdout)
        except ValueError:
            return set()
        return extract_test_ids(payload)

    # ----------------------------------------------------------------- run

    def run(self) -> int:
        self.validate()
        self._open_run_dir()
        try:
            return self._run_guarded()
        except KeyboardInterrupt:
            self._finish(["keyboard interrupt during native session"],
                         build_record=None, exit_hint=130)
            return 130
        except OSError as exc:
            self._finish([f"os error / missing tool: {exc}"],
                         build_record=None, exit_hint=1)
            return 1
        except RunnerError as exc:
            self._finish([f"precondition failed mid-run: {exc}"],
                         build_record=None, exit_hint=1)
            return 1

    def _run_guarded(self) -> int:
        frozen = self._capture_identity()
        self._write_receipt(frozen)
        self._record_checkpoint("frozen", True, [])

        # Storage/session guard audit BEFORE the heavyweight native session.
        # The real audit always runs; its raw exit code and full output are
        # preserved. Classification is fail-closed: hard blockers stop the
        # native session, known global housekeeping (foreign aged/unregistered/
        # unsafe-Git artifacts, Codex session-log budget) stays as visible
        # warnings — tolerated only because _validate_registration proved our
        # own ROOT clean above. Nothing is ever cleaned.
        audit = self._invoke("guard_audit", [self.guard.guard_tool, "audit"])
        classification = classify_guard_audit(
            audit.stdout, audit.stderr, audit.exit_code,
            target_label=str(self.device_label), target_udid=str(self.device_udid),
        )
        self.guard_audit = classification
        if classification.status == "blocked":
            reasons = [
                f"dev-storage-guard audit failed (exit {audit.exit_code}); "
                f"native session blocked; blockers: "
                f"{classification.blockers or 'see guard_audit log'}"
            ]
            self._not_run_rest("native", 0, frozen.sha, "storage/session audit blocked execution")
            self._not_run_rest("kit", 0, frozen.sha, "storage/session audit blocked execution")
            self._finish(reasons, build_record=None, exit_hint=1)
            return 1

        build_bundle = self.run_dir / "native" / "build.xcresult"
        build_bundle.parent.mkdir(parents=True, exist_ok=True)
        build_result = self._invoke("build", self._build_argv(build_bundle))
        build_ok = build_result.exit_code == 0 and build_bundle.exists()
        build_record = {
            "status": "pass" if build_ok else "fail",
            "command": self._find_command("build"),
            "exit_code": build_result.exit_code,
            "result_bundle": str(build_bundle),
            "log": self._find_log("build"),
        }

        drift = self._verify_identity(frozen, "after_build")
        if drift:
            self._not_run_rest("native", 0, frozen.sha,
                               "source changed during/after build; stale build must not be used")
            self._not_run_rest("kit", 0, frozen.sha,
                               "source changed during/after build; stale build must not be used")
            self._finish(self._collect_failures(build_record,
                                                [f"source changed during run: {d}" for d in drift]),
                         build_record, exit_hint=1)
            return 1

        if not build_ok:
            self._not_run_rest("native", 0, frozen.sha,
                               "build-for-testing failed; testing is prevented")
            self._not_run_rest("kit", 0, frozen.sha,
                               "build-for-testing failed; testing is prevented")
            self._finish(self._collect_failures(build_record,
                                                ["build-for-testing failed"]),
                         build_record, exit_hint=1)
            return 1

        for i in range(1, self.rounds + 1):
            result = self._run_native_round(i, frozen.sha)
            self.round_results.append(result)
            drift = self._verify_identity(frozen, f"after_native_round_{i}")
            if drift:
                self._not_run_rest("native", i, frozen.sha,
                                   "source changed during run; stale build must not be used")
                self._not_run_rest("kit", 0, frozen.sha,
                                   "source changed during run; stale build must not be used")
                self._finish(self._collect_failures(build_record,
                                                    [f"source changed during run: {d}" for d in drift]),
                             build_record, exit_hint=1)
                return 1

        for i in range(1, self.kit_rounds + 1):
            result = self._run_kit_round(i, frozen.sha)
            self.round_results.append(result)
            drift = self._verify_identity(frozen, f"after_kit_round_{i}")
            if drift:
                self._not_run_rest("kit", i, frozen.sha,
                                   "source changed during run; stale results must not be claimed")
                self._finish(self._collect_failures(build_record,
                                                    [f"source changed during run: {d}" for d in drift]),
                             build_record, exit_hint=1)
                return 1

        failures = self._collect_failures(build_record, [])
        self._finish(failures, build_record, exit_hint=0)
        return 0 if not failures else 1

    def _not_run_rest(self, kind: str, after: int, sha: str, reason: str) -> None:
        total = self.rounds if kind == "native" else self.kit_rounds
        for i in range(after + 1, total + 1):
            self.round_results.append(RoundResult(
                kind=kind, index=i, status="not_run", command=None, exit_code=None,
                result_bundle=None, tests=None, failures=[reason], log=None,
                source_sha=sha))

    def _run_native_round(self, index: int, sha: str) -> RoundResult:
        bundle = self.run_dir / "native" / f"round-{index:02d}.xcresult"
        argv = self._native_argv(bundle)
        result = self._invoke(f"native_round_{index:02d}", argv)
        log = self._find_log(f"native_round_{index:02d}")

        failures: list[str] = []
        counts: dict[str, Any] | None = None
        if result.exit_code != 0:
            failures.append(f"execution failure or interrupted run (exit {result.exit_code})")
        if not bundle.exists():
            failures.append("no test result (result bundle missing)")
        else:
            ids = self._xcresult_test_ids(bundle)
            if ids:
                self._round_ids[index] = ids
            counts = self._xcresult_counts(bundle)
            if counts is None:
                failures.append(
                    "test counts missing/incomplete/inconsistent in xcresult (fail closed)")
            elif counts["failed"] > 0:
                failures.append(f"{counts['failed']} test(s) failed")
            elif counts["total"] == 0:
                failures.append("zero native tests executed")
            elif counts["passed"] == 0:
                failures.append(
                    f"all native tests skipped (0 passed, {counts['skipped']} skipped)")

        status = "pass" if not failures else "fail"
        return RoundResult(kind="native", index=index, status=status,
                           command=list(argv), exit_code=result.exit_code,
                           result_bundle=str(bundle), tests=counts,
                           failures=failures, log=log, source_sha=sha)

    def _run_kit_round(self, index: int, sha: str) -> RoundResult:
        argv = self._kit_argv()
        result = self._invoke(f"kit_round_{index:02d}", argv)
        log = self._find_log(f"kit_round_{index:02d}")
        output = result.stdout + "\n" + result.stderr
        counts = parse_swift_test_counts(output)

        failures: list[str] = []
        if result.exit_code != 0:
            failures.append(f"execution failure or interrupted run (exit {result.exit_code})")
        if counts is None:
            if re.search(r"Test run with [^\n]*\bfailed\b", output):
                failures.append("Swift Testing run failed; exact failed-test count unavailable")
            else:
                failures.append("no complete test counts parsed from swift test output "
                                "(exit 0 alone never proves tests ran)")
        elif counts["failed"] > 0:
            failures.append(f"{counts['failed']} Kit test(s) failed")
        elif counts["total"] == 0 or counts["passed"] == 0:
            failures.append(
                f"no executed/passed Kit tests (passed={counts['passed']}, "
                f"skipped={counts['skipped']})")

        status = "pass" if not failures else "fail"
        return RoundResult(kind="kit", index=index, status=status,
                           command=list(argv), exit_code=result.exit_code,
                           result_bundle=None, tests=counts,
                           failures=failures, log=log, source_sha=sha)

    # -------------------------------------------------------------- verdict

    def _skips_present(self) -> bool:
        return any((r.tests or {}).get("skipped", 0) > 0 for r in self.round_results)

    def _id_inventory(self) -> dict[str, Any]:
        per_round = [r for r in self.round_results
                     if r.kind == "native" and r.status != "not_run"]
        inventories = self._round_ids
        sets = [inventories.get(r.index) for r in per_round]
        if not sets or any(not s for s in sets):
            return {
                "status": "unavailable",
                "note": "xcresulttool did not provide stable test IDs for every round; "
                        "cross-round test-identity stability could not be verified "
                        "(verification limit)",
            }
        first = sorted(sets[0])
        stable = all(sorted(s) == first for s in sets)
        return {
            "status": "stable" if stable else "unstable",
            "test_count": len(first),
            "note": None if stable else "test ID inventory differs across rounds",
        }

    def _collect_failures(self, build_record: dict[str, Any] | None,
                          extra: Sequence[str]) -> list[str]:
        """All fail-closed conditions for the run (strict, exhaustive)."""
        failures = list(extra)
        if build_record is None or build_record.get("status") != "pass":
            failures.append("build-for-testing did not pass")
        for rnd in self.round_results:
            if rnd.status != "pass":
                failures.append(
                    f"{rnd.kind} round {rnd.index}: {rnd.status} "
                    f"({'; '.join(rnd.failures) or 'no reasons recorded'})")
        if not self.checkpoints or not all(c.get("stable") for c in self.checkpoints):
            failures.append("source identity was not stable across all checkpoints")
        if not self.checkpoints or self.checkpoints[0].get("stage") != "frozen":
            failures.append("source receipt was not frozen at start")
        inv = self._id_inventory()
        if inv.get("status") == "unstable":
            failures.append("test ID inventory unstable across rounds")
        native = [r for r in self.round_results if r.kind == "native"]
        kit = [r for r in self.round_results if r.kind == "kit"]
        if len(native) != self.rounds or len(kit) != self.kit_rounds:
            failures.append("round count mismatch")
        return failures

    def _find_command(self, role: str) -> list[str] | None:
        for entry in self.commands:
            if entry["role"] == role:
                return list(entry["argv"])
        return None

    def _find_log(self, role: str) -> str | None:
        for entry in self.commands:
            if entry["role"] == role:
                return entry["log"]
        return None

    # -------------------------------------------------------------- reports

    def _write_receipt(self, frozen: SourceIdentity) -> None:
        assert self.run_dir is not None
        receipt = {
            "tool": TOOL_NAME,
            "frozen_at": _utc_now(),
            "source": frozen.to_json(),
            "config": self._config_json(),
        }
        self._write_exclusive(self.run_dir / "source-receipt.json",
                              json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    def _config_json(self) -> dict[str, Any]:
        return {
            "repo_root": str(self.repo_root),
            "artifact_dir": str(self.artifact_dir),
            "run_dir": str(self.run_dir),
            "scheme": self.scheme,
            "configuration": self.configuration,
            "profile": self.profile,
            "device_label": self.device_label,
            "device_udid": self.device_udid,
            "rounds": self.rounds,
            "kit_rounds": self.kit_rounds,
            "session_helper": self.session_helper,
            "guard_tool": self.guard.guard_tool,
            "only_testing": list(self.only_testing),
            "parallel_testing": False,
            "clones_disabled": True,
            "kit_flags": list(KIT_SERIAL_FLAGS),
        }

    def _finish(self, failures: list[str], build_record: dict[str, Any] | None,
                exit_hint: int) -> None:
        assert self.run_dir is not None
        verdict = "pass" if not failures and exit_hint == 0 else "fail"
        inv = self._id_inventory()
        guard_json = self.guard_audit.to_json() if self.guard_audit is not None else None
        if guard_json is not None:
            guard_json["log"] = self._find_log("guard_audit")
        report = {
            "tool": TOOL_NAME,
            "generated_at": _utc_now(),
            "verdict": verdict,
            "exit_hint": exit_hint,
            "failures": failures,
            "disclaimers": list(DISCLAIMERS),
            "skips_present": self._skips_present(),
            "id_inventory": inv,
            "guard_audit": guard_json,
            "config": self._config_json(),
            "checkpoints": self.checkpoints,
            "build": build_record,
            "native_rounds": [r.to_json() for r in self.round_results if r.kind == "native"],
            "kit_rounds": [r.to_json() for r in self.round_results if r.kind == "kit"],
            "commands": self.commands,
        }
        self._write_exclusive(self.run_dir / "five-pass-report.json",
                              json.dumps(report, indent=2, sort_keys=True) + "\n")
        self._write_exclusive(self.run_dir / "five-pass-report.md",
                              self._render_markdown(report))

    @staticmethod
    def _render_markdown(report: dict[str, Any]) -> str:
        lines = ["# iOS five-pass report", ""]
        lines.append(f"- Verdict: **{report['verdict'].upper()}**")
        lines.append(f"- Generated: {report['generated_at']}")
        cfg = report["config"]
        src = report["checkpoints"][0] if report["checkpoints"] else {}
        lines.append(f"- Source frozen: {src.get('stage')} at {src.get('at')}")
        lines.append(f"- Config: scheme={cfg['scheme']} configuration={cfg['configuration']} "
                     f"profile={cfg['profile']} device={cfg.get('device_label')} "
                     f"rounds={cfg['rounds']} kit_rounds={cfg['kit_rounds']}")
        lines.append(f"- Skips present: {report['skips_present']} "
                     f"(skipped tests always mean coverage is incomplete)")
        inv = report["id_inventory"]
        lines.append(f"- Test ID inventory: {inv.get('status')}"
                     + (f" — {inv.get('note')}" if inv.get("note") else ""))
        if report["failures"]:
            lines.append("- Failures:")
            for f in report["failures"]:
                lines.append(f"  - {f}")
        lines.append("")
        lines.append("## dev-storage-guard audit")
        lines.append("")
        ga = report.get("guard_audit")
        if ga is None:
            lines.append("- Status: not run")
        else:
            labels = {"pass": "pass", "warning": "**audit warning**",
                      "blocked": "**audit blocked**"}
            lines.append(f"- Status: {labels[ga['status']]} (raw exit code {ga['raw_exit_code']})")
            if ga["status"] == "warning":
                lines.append("- Known global housekeeping tolerated after independent "
                             "own-root validation; nothing was cleaned (cross-task "
                             "artifact cleanup is forbidden).")
            if ga["status"] == "blocked":
                lines.append("- The heavyweight native session was blocked; the audit "
                             "was executed and its raw exit code and full output are "
                             "preserved in the guard_audit log.")
            if ga["warnings"]:
                lines.append("- Warnings:")
                for w in ga["warnings"]:
                    lines.append(f"  - {w}")
            if ga["blockers"]:
                lines.append("- Blockers:")
                for b in ga["blockers"]:
                    lines.append(f"  - {b}")
        lines.append("")
        lines.append("## Build")
        build = report["build"]
        if build:
            lines.append(f"- build-for-testing: {build['status']} (exit {build['exit_code']})")
        else:
            lines.append("- build-for-testing: not run")
        lines.append("")
        lines.append("## Native rounds (serial test-without-building)")
        lines.append("")
        lines.append("| Round | Status | Exit | Tests (total/passed/failed/skipped) | Failures |")
        lines.append("|---|---|---|---|---|")
        for r in report["native_rounds"]:
            t = r["tests"] or {}
            counts = "/".join(str(t.get(k, "-")) for k in ("total", "passed", "failed", "skipped"))
            lines.append(f"| {r['round']} | {r['status']} | {r['exit_code']} | {counts} | "
                         f"{'; '.join(r['failures']) or '-'} |")
        lines.append("")
        lines.append("## DayPageKit rounds (serial swift test)")
        lines.append("")
        lines.append("| Round | Status | Exit | Tests (total/passed/failed/skipped) | Failures |")
        lines.append("|---|---|---|---|---|")
        for r in report["kit_rounds"]:
            t = r["tests"] or {}
            counts = "/".join(str(t.get(k, "-")) for k in ("total", "passed", "failed", "skipped"))
            lines.append(f"| {r['round']} | {r['status']} | {r['exit_code']} | {counts} | "
                         f"{'; '.join(r['failures']) or '-'} |")
        lines.append("")
        lines.append("## Source identity checkpoints")
        lines.append("")
        for c in report["checkpoints"]:
            drift = "; ".join(c.get("drift") or []) or "-"
            lines.append(f"- {c['stage']} @ {c['at']}: stable={c['stable']} ({drift})")
        lines.append("")
        lines.append("## Coverage and limitations")
        lines.append("")
        for d in report["disclaimers"]:
            lines.append(f"- {d}")
        lines.append("")
        return "\n".join(lines)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=TOOL_NAME,
        description="Bounded five-pass iOS + DayPageKit regression-suite repetition runner.",
    )
    parser.add_argument("--repo-root", default=".",
                        help="repository root containing DayPage.xcodeproj (default: cwd)")
    parser.add_argument("--artifacts", required=True,
                        help="caller artifact directory, registered in dev-storage-guard's "
                             "artifacts.list; a fresh uniquely-owned run child is created inside")
    parser.add_argument("--profile", default=DEFAULT_PROFILE,
                        help="dev-ios-session profile (default: primary = Primary iPhone)")
    parser.add_argument("--udid", default=None,
                        help="optional UDID pin; must equal the allowlist entry for --profile")
    parser.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS,
                        help=f"native test rounds (minimum {MIN_ROUNDS}, default {DEFAULT_ROUNDS})")
    parser.add_argument("--kit-rounds", type=int, default=DEFAULT_ROUNDS,
                        help=f"DayPageKit swift test rounds (minimum {MIN_ROUNDS}, default {DEFAULT_ROUNDS})")
    parser.add_argument("--scheme", default="DayPage")
    parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--session-helper", default=DEFAULT_SESSION_HELPER)
    parser.add_argument("--only-testing", action="append", default=[],
                        help="optional -only-testing: target (repeatable)")
    return parser


def main(argv: Sequence[str] | None = None, *,
         run_cmd: Callable[[tuple[str, ...], Path], CommandResult] | None = None,
         guard: GuardPaths | None = None) -> int:
    args = build_arg_parser().parse_args(list(argv) if argv is not None else None)
    runner = FivePassRunner(
        repo_root=Path(args.repo_root),
        artifact_dir=Path(args.artifacts),
        profile=args.profile,
        udid=args.udid,
        rounds=args.rounds,
        kit_rounds=args.kit_rounds,
        scheme=args.scheme,
        configuration=args.configuration,
        session_helper=args.session_helper,
        only_testing=args.only_testing,
        guard=guard,
        invocation_argv=(list(argv) if argv is not None else None),
        run_cmd=run_cmd,
    )
    try:
        return runner.run()
    except RunnerError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
