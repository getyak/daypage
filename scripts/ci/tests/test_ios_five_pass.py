#!/usr/bin/env python3
"""Deterministic dry tests for scripts/ci/run_ios_five_pass.py.

No Simulator, no xcodebuild, no network: subprocess execution and filesystem
side effects are faked with temp fixtures. Contracts under test:

  * insufficient rounds are rejected before any command runs (min rounds = 5);
  * build-for-testing failure prevents all testing;
  * a failed round is reported as failed — never skipped or misreported;
  * native fail-closed counting: incomplete/missing/malformed/zero/all-skipped
    xcresult counts fail; skips are retained distinctly;
  * Kit counting: LAST aggregate XCTest line (never summed), combined with the
    final Swift Testing summary including its failures; missing/all-skipped/
    zero counts fail; non-zero exit always fails; exit 0 alone never proves
    tests ran;
  * source identity binds content (diff + untracked + build-input SHA256),
    is frozen at start, verified after build and each round, and adversarial
    mid-run changes stop the run so a stale build is never re-used;
  * dev-storage-guard artifacts registry + simulator allowlist are the real
    authority (exact own-ROOT registry membership, symlink refusal, non-other-
    artifact output boundaries, foreign Git-marker refusal with the official
    SPM SourcePackages/(checkouts|repositories) exception, audit
    classification, Primary iPhone default); evidence lives in a fresh
    uniquely-owned run child and existing runs are never overwritten;
  * audit exit 2 fail-closed classification: true unsafe blockers (free
    space < 30 GiB, rogue simulator/Compose, missing target allowlist entry,
    unknown/partial/duplicate/inconsistent output, unexpected exit/tool
    errors) block the native session; known global housekeeping (foreign
    aged/unregistered/unsafe-Git artifacts, Codex session-log budget) is
    tolerated as visible labelled warnings after own-root validation, is
    never called a pass on raw exit 2, and nothing is ever cleaned;
  * mixed XCTest+Swift Testing logs parse real counts: Swift Testing skip
    accounting is scoped to the `◇ Test run started.` section so XCTest
    `Test Case ... skipped` / `: Test skipped - Set ...` lines cannot
    contaminate it (sanitized fixture, no personal paths);
  * the DayPageTests membership + serialized-root namespace repo-state
    contracts (parent-owned production Swift/Xcode, issue #830) enforce fully
    wherever that state is present and report explicit skips — never a false
    pass or a weakened assertion — when it is wholly absent from a checkout;
  * Keyboard interrupt / missing tool failures preserve a failure report;
  * serial reuse/unique result bundles, session-helper routing, no device
    lifecycle commands;
  * DayPageTests membership contract and the DayPageSerialSwiftTests
    serialized-root namespace contract (all Swift Testing suites nested).

Run from the repository root:

    python3 -m unittest discover -s scripts/ci/tests -p test_ios_five_pass.py
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import re
import stat
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_CI_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS_CI_DIR.parents[1]
sys.path.insert(0, str(SCRIPTS_CI_DIR))

import run_ios_five_pass as rfp  # noqa: E402

PRIMARY_UDID = "02B4F0C1-A92F-469D-9DCC-5ED13F119507"
COMPACT_UDID = "526F80F9-01D6-4F46-8969-FC89EE198C89"
IPAD_UDID = "EED7D68D-35F3-4A97-93D8-9DE6FF11A343"
ALLOWLIST_TSV = (
    f"{PRIMARY_UDID}\tPrimary iPhone\n"
    f"{COMPACT_UDID}\tCompact iPhone\n"
    f"{IPAD_UDID}\tiPad\n"
)
# Complete, internally consistent counts (12 = 11 + 0 + 1).
PASSING_PAYLOAD = {"totalTests": 12, "passedTests": 11, "failedTests": 0, "skippedTests": 1}
CLEAN_PAYLOAD = {"totalTests": 12, "passedTests": 12, "failedTests": 0, "skippedTests": 0}
ALL_SKIPPED_PAYLOAD = {"totalTests": 7, "passedTests": 0, "failedTests": 0, "skippedTests": 7}
INCOMPLETE_PAYLOAD = {"totalTests": 7}
INCONSISTENT_PAYLOAD = {"totalTests": 7, "passedTests": 5, "failedTests": 0, "skippedTests": 1}
ZERO_PAYLOAD = {"totalTests": 0, "passedTests": 0, "failedTests": 0, "skippedTests": 0}
FAILED_PAYLOAD = {"totalTests": 12, "passedTests": 10, "failedTests": 2, "skippedTests": 0}

DEFAULT_KIT_OUTPUT = "Executed 20 tests, with 0 failures\nTest run with 20 tests passed after 0.5s"

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"

GUARD_SIM_ROWS = (
    f"  OK\tPrimary iPhone\tiPhone 17 Pro\tShutdown\t{PRIMARY_UDID}\n"
    f"  OK\tCompact iPhone\tiPhone SE (3rd generation)\tShutdown\t{COMPACT_UDID}\n"
    f"  OK\tiPad\tiPad Pro 11-inch (M5)\tShutdown\t{IPAD_UDID}\n"
)


def guard_output(*, free: str = "200", sim_total: str = "3", sim_outside: str = "0",
                 compose_active: str = "7", compose_outside: str = "0",
                 paths: str = "14", size: str = "0.7", aged: str = "0",
                 unregistered: str = "0", unsafe: str = "0",
                 session: str = "1.0", rows: str = GUARD_SIM_ROWS,
                 extra: str = "") -> str:
    """Schema-shaped `dev-storage-guard audit` output with controllable knobs."""
    return (
        f"Free space: {free} GiB (minimum 30 GiB)\n"
        f"Simulator devices: {sim_total} total, {sim_outside} outside allowlist\n"
        f"Docker Compose projects: {compose_active} active, {compose_outside} outside allowlist\n"
        f"Registered test artifacts: {paths} paths, {size} GiB ({aged} older than 24h, "
        f"{unregistered} unregistered, {unsafe} unsafe Git roots)\n"
        f"Codex session logs: {session} GiB (5.0 GiB warning threshold)\n"
        "\nAllowed simulators:\n" + rows + extra
    )


CLEAN_AUDIT_OUTPUT = guard_output()
# Real observed housekeeping shape (sanitized): foreign tasks' aged,
# unregistered and unsafe-Git artifacts plus the Codex session-log budget.
HOUSEKEEPING_AUDIT_OUTPUT = guard_output(free="87", aged="8", unregistered="4",
                                         unsafe="1", session="6.0")


class FakeSession:
    """Fake subprocess backend: records argv and simulates command results."""

    def __init__(
        self,
        *,
        helper: str = "/fake/bin/dev-ios-session",
        guard_tool: str = "/fake/bin/dev-storage-guard",
        sha: str = "a" * 40,
        diff_text: str = "fake tracked diff\n",
        status_output: str = "",
        untracked_output: str = "",
        audit_exit: int = 0,
        audit_output: str = CLEAN_AUDIT_OUTPUT,
        build_exit: int = 0,
        native_exits: list[int] | None = None,
        kit_exits: list[int] | None = None,
        native_payloads: dict[int, dict] | None = None,
        default_payload: dict | None = None,
        kit_outputs: dict[int, str] | None = None,
        default_kit_output: str = DEFAULT_KIT_OUTPUT,
        bundle_missing_rounds: set[int] | None = None,
        summary_broken: bool = False,
        summary_garbage: bool = False,
        tests_broken: bool = False,
        id_payloads: dict[int, list[str]] | None = None,
        diff_after: tuple[int, str] | None = None,
        hook=None,
    ) -> None:
        self.helper = helper
        self.guard_tool = guard_tool
        self.commands: list[tuple[str, ...]] = []
        self.sha = sha
        self.diff_text = diff_text
        self.status_output = status_output
        self.untracked_output = untracked_output
        self.audit_exit = audit_exit
        self.audit_output = audit_output
        self.build_exit = build_exit
        self.native_exits = list(native_exits or [])
        self.kit_exits = list(kit_exits or [])
        self.native_payloads = dict(native_payloads or {})
        self.default_payload = dict(default_payload if default_payload is not None
                                    else CLEAN_PAYLOAD)
        self.kit_outputs = dict(kit_outputs or {})
        self.default_kit_output = default_kit_output
        self.bundle_missing_rounds = set(bundle_missing_rounds or set())
        self.summary_broken = summary_broken
        self.summary_garbage = summary_garbage
        self.tests_broken = tests_broken
        self.id_payloads = dict(id_payloads or {})
        self.diff_after = diff_after  # (command_index, new_diff_text)
        self.hook = hook
        self._native_calls = 0
        self._kit_calls = 0

    def __call__(self, argv: tuple[str, ...], cwd: Path) -> rfp.CommandResult:
        if self.hook is not None:
            self.hook(argv, len(self.commands))
        index = len(self.commands)
        self.commands.append(tuple(argv))
        if self.diff_after is not None and index >= self.diff_after[0]:
            self.diff_text = self.diff_after[1]
        if argv[:2] == ("git", "rev-parse"):
            return rfp.CommandResult(argv, 0, self.sha + "\n", "")
        if argv[:2] == ("git", "status"):
            return rfp.CommandResult(argv, 0, self.status_output, "")
        if argv[:2] == ("git", "diff"):
            return rfp.CommandResult(argv, 0, self.diff_text, "")
        if argv[:3] == ("git", "ls-files", "--others"):
            return rfp.CommandResult(argv, 0, self.untracked_output, "")
        if argv[0] == self.guard_tool and argv[1:2] == ("audit",):
            return rfp.CommandResult(argv, self.audit_exit, self.audit_output, "")
        if argv[0] == "xcrun":
            bundle = argv[argv.index("--path") + 1] if "--path" in argv else ""
            index_m = re.search(r"round-(\d+)", Path(bundle).name)
            rnd = int(index_m.group(1)) if index_m else 1
            if "summary" in argv:
                if self.summary_broken:
                    return rfp.CommandResult(argv, 1, "", "xcresulttool: failed")
                if self.summary_garbage:
                    return rfp.CommandResult(argv, 0, "not json", "")
                payload = self.native_payloads.get(rnd, self.default_payload)
                return rfp.CommandResult(argv, 0, json.dumps(payload), "")
            if "tests" in argv:
                if self.tests_broken:
                    return rfp.CommandResult(argv, 1, "", "xcresulttool: failed")
                ids = self.id_payloads.get(rnd, ["DayPageTests.A.testOne",
                                                 "DayPageTests.A.testTwo"])
                return rfp.CommandResult(
                    argv, 0, json.dumps({"testNodes": [{"identifier": i} for i in ids]}), "")
            raise AssertionError(f"unexpected xcrun command: {argv}")
        if argv[:2] == (self.helper, "run") and "--" in argv:
            body = argv[argv.index("--") + 1:]
            if "build-for-testing" in body:
                self._maybe_make_bundle(body)
                return rfp.CommandResult(argv, self.build_exit, "build output", "")
            if "test-without-building" in body:
                self._native_calls += 1
                rnd = self._native_calls
                if rnd not in self.bundle_missing_rounds:
                    self._maybe_make_bundle(body)
                code = self.native_exits[rnd - 1] if rnd - 1 < len(self.native_exits) else 0
                return rfp.CommandResult(argv, code, "test output", "")
            if "swift" in body:
                self._kit_calls += 1
                rnd = self._kit_calls
                code = self.kit_exits[rnd - 1] if rnd - 1 < len(self.kit_exits) else 0
                out = self.kit_outputs.get(rnd, self.default_kit_output)
                return rfp.CommandResult(argv, code, out, "")
        raise AssertionError(f"unexpected command: {argv}")

    @staticmethod
    def _maybe_make_bundle(body: tuple[str, ...]) -> None:
        if "-resultBundlePath" in body:
            bundle = Path(body[body.index("-resultBundlePath") + 1])
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_text("stub", encoding="utf-8")

    def helper_commands(self) -> list[tuple[str, ...]]:
        return [c for c in self.commands if c[0] == self.helper]

    def action_commands(self, action: str) -> list[tuple[str, ...]]:
        return [c for c in self.helper_commands() if action in c]


class DryRunFixture(unittest.TestCase):
    """Temp workspace: fake repo, guard registry/allowlist, helper stubs."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.repo = self.root / "repo"
        (self.repo / "DayPage.xcodeproj").mkdir(parents=True)
        (self.repo / "DayPage.xcodeproj" / "project.pbxproj").write_text("// pbx", encoding="utf-8")
        (self.repo / "DayPageKit").mkdir(parents=True)
        (self.repo / "DayPageKit" / "Package.swift").write_text("// pkg", encoding="utf-8")
        (self.repo / "untracked-notes.txt").write_text("notes v1", encoding="utf-8")
        self.helper_path = self.root / "dev-ios-session"
        self.guard_tool_path = self.root / "dev-storage-guard"
        for tool in (self.helper_path, self.guard_tool_path):
            tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            tool.chmod(tool.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.registry = self.root / "artifacts.list"
        self.registry.write_text(str(self.artifacts.resolve()) + "\n", encoding="utf-8")
        self.allowlist = self.root / "simulator-allowlist.tsv"
        self.allowlist.write_text(ALLOWLIST_TSV, encoding="utf-8")

    def guard(self) -> rfp.GuardPaths:
        return rfp.GuardPaths(
            guard_tool=str(self.guard_tool_path),
            artifacts_registry=str(self.registry),
            simulator_allowlist=str(self.allowlist),
        )

    def run_main(self, fake: FakeSession, **overrides) -> tuple[int, list[str]]:
        fake.helper = str(self.helper_path)
        fake.guard_tool = str(self.guard_tool_path)
        argv = [
            "--repo-root", str(self.repo),
            "--artifacts", str(self.artifacts),
            "--session-helper", str(self.helper_path),
        ]
        for key, value in overrides.items():
            flag = "--" + key.replace("_", "-")
            if isinstance(value, list):
                for item in value:
                    argv.extend([flag, str(item)])
            else:
                argv.extend([flag, str(value)])
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = rfp.main(argv, run_cmd=fake, guard=self.guard())
        return code, argv

    def run_dir(self) -> Path:
        dirs = sorted(d for d in self.artifacts.glob("five-pass-run-*")
                      if (d / "run-owner.json").is_file())
        self.assertEqual(len(dirs), 1, f"expected exactly one owned run dir, found {dirs}")
        return dirs[0]

    def read_report(self) -> dict:
        return json.loads((self.run_dir() / "five-pass-report.json").read_text(encoding="utf-8"))

    def read_receipt(self) -> dict:
        return json.loads((self.run_dir() / "source-receipt.json").read_text(encoding="utf-8"))

    @staticmethod
    def default_fake(**kwargs) -> FakeSession:
        kwargs.setdefault("untracked_output", "untracked-notes.txt\n")
        kwargs.setdefault("status_output", "?? untracked-notes.txt\n")
        return FakeSession(**kwargs)


# ---------------------------------------------------------------------------
# Validation and guard integration
# ---------------------------------------------------------------------------

class TestValidation(DryRunFixture):
    def test_non_debug_configuration_rejected_before_any_command(self) -> None:
        for configuration in ("Release", "Custom", "debug"):
            with self.subTest(configuration=configuration):
                fake = self.default_fake()
                code, _ = self.run_main(fake, configuration=configuration)
                self.assertEqual(code, 2)
                self.assertEqual(fake.commands, [])

    def test_min_rounds_contract_is_five(self) -> None:
        self.assertEqual(rfp.MIN_ROUNDS, 5)

    def test_insufficient_native_rounds_rejected_before_any_command(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake, rounds=4)
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [], "no command may run after validation failure")

    def test_insufficient_kit_rounds_rejected_before_any_command(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake, kit_rounds=2)
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [])

    def test_unregistered_artifact_dir_rejected(self) -> None:
        self.registry.write_text(str((self.root / "somewhere-else").resolve()) + "\n",
                                 encoding="utf-8")
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [], "unregistered artifact directories are refused")

    def test_symlink_traversal_into_repo_refused(self) -> None:
        evil = self.root / "evil-link"
        evil.symlink_to(self.repo / "build-out")
        fake = self.default_fake()
        argv = [
            "--repo-root", str(self.repo),
            "--artifacts", str(evil),
            "--session-helper", str(self.helper_path),
        ]
        with contextlib.redirect_stderr(io.StringIO()):
            code = rfp.main(argv, run_cmd=fake, guard=self.guard())
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [])

    def test_missing_artifacts_flag_is_usage_error(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            with contextlib.redirect_stderr(io.StringIO()):
                rfp.main(["--session-helper", str(self.helper_path)],
                         run_cmd=FakeSession(), guard=self.guard())
        self.assertEqual(ctx.exception.code, 2)

    def test_unknown_profile_rejected(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake, profile="watch")
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [])

    def test_udid_not_matching_allowlist_entry_rejected(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake, udid="00000000-0000-0000-0000-000000000000")
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [])

    def test_missing_allowlist_file_rejected(self) -> None:
        self.allowlist.unlink()
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 2)


class TestGuardIntegration(DryRunFixture):
    def test_guard_audit_blocks_native_session_with_concrete_blockers(self) -> None:
        fake = self.default_fake(
            audit_exit=2,
            audit_output="Free space: 26 GiB (minimum 30 GiB)\n"
                         "Registered test artifacts: 2 paths (1 unsafe Git roots)\n")
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertEqual(fake.action_commands("build-for-testing"), [],
                         "audit blockers must stop the heavyweight native session")
        self.assertEqual(fake.action_commands("test-without-building"), [])
        report = self.read_report()
        self.assertEqual(report["verdict"], "fail")
        self.assertTrue(any("dev-storage-guard audit failed" in f for f in report["failures"]))
        for key in ["native_rounds", "kit_rounds"]:
            self.assertEqual(len(report[key]), 5)
            self.assertTrue(all(r["status"] == "not_run" and r["exit_code"] is None
                                for r in report[key]))
        self.assertTrue(any("minimum 30 GiB" in f for f in report["failures"]))
        self.assertTrue(any("unsafe Git" in f for f in report["failures"]))
        # Evidence preserved without touching other tasks.
        self.assertTrue((self.run_dir() / "logs").is_dir())

    def test_guard_audit_runs_before_build(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        roles = [tuple(c) for c in fake.commands]
        audit_idx = next(i for i, c in enumerate(roles)
                         if c[0] == self.guard_tool_path.as_posix() and c[1:2] == ("audit",))
        build_idx = next(i for i, c in enumerate(roles) if "build-for-testing" in c)
        self.assertLess(audit_idx, build_idx,
                        "dev-storage-guard audit must precede the native session")

    def test_device_resolved_from_real_allowlist_with_primary_default(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        build = fake.action_commands("build-for-testing")[0]
        self.assertIn(f"platform=iOS Simulator,id={PRIMARY_UDID}", build)
        for c in fake.helper_commands():
            self.assertIn("--profile", c)
            self.assertEqual(c[c.index("--profile") + 1], "primary")
            self.assertEqual(c[c.index("--udid") + 1], PRIMARY_UDID)
            self.assertTrue(c[c.index("--reason") + 1])
        report = self.read_report()
        self.assertEqual(report["config"]["device_label"], "Primary iPhone")
        self.assertEqual(report["config"]["device_udid"], PRIMARY_UDID)

    def test_secondary_profile_uses_its_allowlist_entry(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake, profile="compact")
        self.assertEqual(code, 0)
        build = fake.action_commands("build-for-testing")[0]
        self.assertIn(f"platform=iOS Simulator,id={COMPACT_UDID}", " ".join(build))


# ---------------------------------------------------------------------------
# Guard audit classification (P1: exit-2 false blockers vs true blockers)
# ---------------------------------------------------------------------------

class TestGuardAuditClassification(unittest.TestCase):
    """Exact fail-closed classification of dev-storage-guard audit output."""

    TARGET = {"target_label": "Primary iPhone", "target_udid": PRIMARY_UDID}

    def classify(self, output: str, exit_code: int = 0, stderr: str = "",
                 **target) -> rfp.GuardAuditReport:
        kwargs = dict(self.TARGET)
        kwargs.update(target)
        return rfp.classify_guard_audit(output, stderr, exit_code, **kwargs)

    def test_clean_schema_exit_zero_is_pass(self) -> None:
        r = self.classify(CLEAN_AUDIT_OUTPUT, 0)
        self.assertEqual(r.status, "pass")
        self.assertEqual((r.blockers, r.warnings), ([], []))
        self.assertEqual(r.raw_exit_code, 0)

    def test_foreign_housekeeping_exit_two_is_warning_never_pass(self) -> None:
        r = self.classify(HOUSEKEEPING_AUDIT_OUTPUT, 2)
        self.assertEqual(r.raw_exit_code, 2)
        self.assertEqual(r.status, "warning")
        self.assertNotEqual(r.status, "pass")
        self.assertEqual(r.blockers, [])
        self.assertTrue(any("older than 24h" in w for w in r.warnings))
        self.assertTrue(any("unregistered" in w for w in r.warnings))
        self.assertTrue(any("unsafe Git" in w for w in r.warnings))
        self.assertTrue(any("session-log budget" in w for w in r.warnings))
        self.assertTrue(all("nothing cleaned" in w for w in r.warnings
                            if "session-log" in w or "artifacts" in w))

    def test_free_space_below_minimum_blocks(self) -> None:
        r = self.classify(guard_output(free="29"), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("minimum 30 GiB" in b for b in r.blockers))

    def test_free_space_at_minimum_and_between_old_threshold_passes(self) -> None:
        for free in ("30", "64"):
            with self.subTest(free=free):
                r = self.classify(guard_output(free=free), 0)
                self.assertEqual(r.status, "pass")
                self.assertEqual(r.blockers, [])

    def test_unexpected_guard_minimum_still_blocks(self) -> None:
        output = guard_output().replace("minimum 30 GiB", "minimum 80 GiB")
        r = self.classify(output, 0)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("unexpected free-space minimum" in b for b in r.blockers))

    def test_rogue_simulator_blocks(self) -> None:
        r = self.classify(guard_output(sim_total="4", sim_outside="1"), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("rogue simulator" in b for b in r.blockers))

    def test_rogue_compose_blocks(self) -> None:
        r = self.classify(guard_output(compose_outside="2"), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("Compose" in b for b in r.blockers))

    def test_missing_target_allowlist_entry_blocks(self) -> None:
        rows = "".join(l + "\n" for l in GUARD_SIM_ROWS.splitlines()
                       if "Primary iPhone" not in l)
        r = self.classify(guard_output(rows=rows), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("target allowlist entry missing" in b for b in r.blockers))

    def test_missing_marker_row_for_target_blocks(self) -> None:
        rows = ("".join(l + "\n" for l in GUARD_SIM_ROWS.splitlines()
                        if "Primary iPhone" not in l)
                + f"  MISSING\tPrimary iPhone\t{PRIMARY_UDID}\n")
        r = self.classify(guard_output(rows=rows), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("MISSING row" in b for b in r.blockers))

    def test_target_udid_mismatch_blocks(self) -> None:
        rows = GUARD_SIM_ROWS.replace(PRIMARY_UDID, "00000000-0000-0000-0000-000000000000")
        r = self.classify(guard_output(rows=rows), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("UDID mismatch" in b for b in r.blockers))

    def test_unknown_output_line_blocks(self) -> None:
        r = self.classify(guard_output(extra="Storage pressure: 3 GiB\n"), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("unknown audit output line" in b for b in r.blockers))

    def test_duplicate_summary_line_blocks(self) -> None:
        r = self.classify(
            guard_output(extra="Free space: 200 GiB (minimum 30 GiB)\n"), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("duplicate audit output line" in b for b in r.blockers))

    def test_partial_output_blocks(self) -> None:
        partial = "\n".join(CLEAN_AUDIT_OUTPUT.splitlines()[:4]) + "\n"
        r = self.classify(partial, 0)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("partial audit output" in b for b in r.blockers))

    def test_unexpected_exit_code_blocks(self) -> None:
        r = self.classify(CLEAN_AUDIT_OUTPUT, 1)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("unexpected dev-storage-guard exit code 1" in b
                            for b in r.blockers))

    def test_exit_two_without_findings_blocks(self) -> None:
        r = self.classify(CLEAN_AUDIT_OUTPUT, 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("exit 2 without recognizable findings" in b
                            for b in r.blockers))

    def test_exit_zero_with_findings_blocks(self) -> None:
        r = self.classify(HOUSEKEEPING_AUDIT_OUTPUT, 0)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("contradicts parsed findings" in b for b in r.blockers))

    def test_stderr_output_blocks(self) -> None:
        r = self.classify(CLEAN_AUDIT_OUTPUT, 0, stderr="tool panic")
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("stderr" in b for b in r.blockers))

    def test_non_target_missing_simulator_is_retained_warning(self) -> None:
        rows = ("".join(l + "\n" for l in GUARD_SIM_ROWS.splitlines()
                        if "iPad" not in l)
                + f"  MISSING\tiPad\t{IPAD_UDID}\n")
        r = self.classify(guard_output(rows=rows), 0)
        self.assertEqual(r.status, "warning")
        self.assertEqual(r.raw_exit_code, 0)
        self.assertTrue(any("non-target allowlist simulator missing" in w
                            for w in r.warnings))

    def test_duplicate_missing_simulator_rows_block(self) -> None:
        rows = ("".join(l + "\n" for l in GUARD_SIM_ROWS.splitlines() if "iPad" not in l)
                + f"  MISSING\tiPad\t{IPAD_UDID}\n" * 2)
        r = self.classify(guard_output(rows=rows), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("duplicate simulator" in b for b in r.blockers))

    def test_ok_and_missing_same_simulator_block_in_either_order(self) -> None:
        row = f"  MISSING\tiPad\t{IPAD_UDID}\n"
        for rows in [GUARD_SIM_ROWS + row, row + GUARD_SIM_ROWS]:
            with self.subTest(rows=rows):
                r = self.classify(guard_output(rows=rows), 2)
                self.assertEqual(r.status, "blocked")
                self.assertTrue(any("duplicate simulator" in b for b in r.blockers))

    def test_non_target_missing_alone_cannot_explain_exit_two(self) -> None:
        rows = ("".join(l + "\n" for l in GUARD_SIM_ROWS.splitlines() if "iPad" not in l)
                + f"  MISSING\tiPad\t{IPAD_UDID}\n")
        r = self.classify(guard_output(rows=rows), 2)
        self.assertEqual(r.status, "blocked")
        self.assertTrue(any("exit 2 without recognizable findings" in b for b in r.blockers))

    def test_foreign_git_markers_match_official_guard_exception(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            foreign = root / "clone" / ".git"
            foreign.mkdir(parents=True)
            spm_checkout = root / "run" / "SourcePackages" / "checkouts" / "pkg" / ".git"
            spm_checkout.mkdir(parents=True)
            spm_repo = root / "run" / "SourcePackages" / "repositories" / "mirror" / ".git"
            spm_repo.mkdir(parents=True)
            bare_scratch = root / "run" / "kit-scratch" / "checkouts" / "pkg" / ".git"
            bare_scratch.mkdir(parents=True)
            markers = rfp.find_foreign_git_markers(root)
            self.assertIn(str(foreign), markers)
            # Only the official SPM SourcePackages/(checkouts|repositories)
            # paths are package metadata; anything else is foreign.
            self.assertIn(str(bare_scratch), markers)
            self.assertNotIn(str(spm_checkout), markers)
            self.assertNotIn(str(spm_repo), markers)


class TestGuardAuditTolerance(DryRunFixture):
    """Integration: foreign housekeeping warns; true unsafe state still blocks."""

    def test_foreign_housekeeping_warnings_do_not_block_but_are_labelled(self) -> None:
        fake = self.default_fake(audit_exit=2, audit_output=HOUSEKEEPING_AUDIT_OUTPUT)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        ga = report["guard_audit"]
        self.assertEqual(ga["status"], "warning")
        self.assertEqual(ga["raw_exit_code"], 2)  # raw exit preserved
        self.assertNotEqual(ga["status"], "pass")
        self.assertEqual(ga["blockers"], [])
        self.assertTrue(any("unsafe Git" in w for w in ga["warnings"]))
        self.assertTrue(any("older than 24h" in w for w in ga["warnings"]))
        self.assertTrue(any("session-log budget" in w for w in ga["warnings"]))
        # Original exit code and full output preserved in the guard_audit log.
        log_text = (self.run_dir() / ga["log"]).read_text(encoding="utf-8")
        self.assertIn("# exit_code: 2", log_text)
        self.assertIn("Registered test artifacts: 14 paths", log_text)
        # Report labels the audit warning and never calls raw exit 2 a pass.
        md = (self.run_dir() / "five-pass-report.md").read_text(encoding="utf-8")
        self.assertIn("audit warning", md)
        self.assertNotIn("Status: pass", md)
        self.assertIn("nothing was cleaned", md)
        for w in ga["warnings"]:
            self.assertIn(w, md, "warnings must be retained in the report")
        # Real command sequence: audit first, then everything via the helper.
        roles = [tuple(c) for c in fake.commands]
        audit_idx = next(i for i, c in enumerate(roles)
                         if c[0] == str(self.guard_tool_path) and c[1:2] == ("audit",))
        build_idx = next(i for i, c in enumerate(roles) if "build-for-testing" in c)
        self.assertLess(audit_idx, build_idx)
        self.assertEqual(len(fake.action_commands("build-for-testing")), 1)
        self.assertEqual(len(fake.action_commands("test-without-building")), 5)
        self.assertEqual(len([c for c in fake.helper_commands() if "swift" in c]), 5)
        for c in fake.helper_commands():
            self.assertEqual(c[:2], (str(self.helper_path), "run"))

    def test_true_unsafe_free_space_still_blocks_native_session(self) -> None:
        fake = self.default_fake(audit_exit=2, audit_output=guard_output(free="29"))
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["guard_audit"]["status"], "blocked")
        self.assertEqual(report["guard_audit"]["raw_exit_code"], 2)
        self.assertEqual(fake.action_commands("build-for-testing"), [])
        self.assertTrue(all(r["status"] == "not_run" for r in report["native_rounds"]))
        self.assertTrue(all(r["status"] == "not_run" for r in report["kit_rounds"]))
        self.assertTrue(any("minimum 30 GiB" in f for f in report["failures"]))
        md = (self.run_dir() / "five-pass-report.md").read_text(encoding="utf-8")
        self.assertIn("audit blocked", md)

    def test_rogue_simulator_and_missing_target_still_block(self) -> None:
        rows = "".join(l + "\n" for l in GUARD_SIM_ROWS.splitlines()
                       if "Primary iPhone" not in l)
        fake = self.default_fake(
            audit_exit=2,
            audit_output=guard_output(sim_total="4", sim_outside="1", rows=rows))
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        failures = self.read_report()["failures"]
        self.assertTrue(any("rogue simulator" in f for f in failures))
        self.assertTrue(any("target allowlist entry missing" in f for f in failures))

    def test_foreign_git_marker_in_own_root_refused_before_any_command(self) -> None:
        (self.artifacts / "foreign-clone" / ".git").mkdir(parents=True)
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 2)
        self.assertEqual(fake.commands, [], "foreign Git markers refuse before any command")

    def test_spm_sourcepackages_git_markers_are_not_foreign(self) -> None:
        for rel in ("prev-run/SourcePackages/checkouts/pkg/.git",
                    "prev-run/SourcePackages/repositories/mirror/.git"):
            (self.artifacts / rel).mkdir(parents=True)
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0, "official SPM exception must not flag package metadata")

    def test_exact_registry_membership_and_no_nested_roots(self) -> None:
        child = self.artifacts / "child"
        child.mkdir()
        fake = self.default_fake()
        argv = ["--repo-root", str(self.repo), "--artifacts", str(child),
                "--session-helper", str(self.helper_path)]
        with contextlib.redirect_stderr(io.StringIO()):
            code = rfp.main(argv, run_cmd=fake, guard=self.guard())
        self.assertEqual(code, 2, "subdirectories of registered roots are not exact members")
        self.assertEqual(fake.commands, [])

        inner = self.artifacts / "inner"
        inner.mkdir()
        self.registry.write_text(str(self.artifacts.resolve()) + "\n"
                                 + str(inner.resolve()) + "\n")
        fake2 = self.default_fake()
        code, _ = self.run_main(fake2)
        self.assertEqual(code, 2, "a root containing another registered root is refused")
        self.assertEqual(fake2.commands, [])

        self.registry.write_text(str(self.artifacts.parent.resolve()) + "\n"
                                 + str(self.artifacts.resolve()) + "\n")
        fake3 = self.default_fake()
        code, _ = self.run_main(fake3)
        self.assertEqual(code, 2, "a root nested inside another registered root is refused")
        self.assertEqual(fake3.commands, [])


# ---------------------------------------------------------------------------
# Failure semantics (native)
# ---------------------------------------------------------------------------

class TestNativeFailureSemantics(DryRunFixture):
    def test_build_failure_prevents_all_testing(self) -> None:
        fake = self.default_fake(build_exit=65)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        self.assertEqual(fake.action_commands("test-without-building"), [])
        self.assertEqual([c for c in fake.helper_commands() if "swift" in c], [])
        report = self.read_report()
        self.assertEqual(report["verdict"], "fail")
        self.assertEqual(report["build"]["status"], "fail")
        self.assertTrue(all(r["status"] == "not_run" for r in report["native_rounds"]))
        self.assertTrue(all(r["status"] == "not_run" for r in report["kit_rounds"]))

    def test_no_skip_on_failure_misreport(self) -> None:
        fake = self.default_fake(native_exits=[0, 65, 0, 0, 0])
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        statuses = [r["status"] for r in report["native_rounds"]]
        self.assertEqual(statuses, ["pass", "fail", "pass", "pass", "pass"])
        self.assertNotIn("skip", statuses)
        self.assertEqual(len(fake.action_commands("test-without-building")), 5,
                         "remaining rounds must still run to preserve evidence")

    def test_all_skipped_native_round_fails(self) -> None:
        fake = self.default_fake(default_payload=ALL_SKIPPED_PAYLOAD)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(all(r["status"] == "fail" for r in report["native_rounds"]))
        self.assertTrue(any("all native tests skipped" in f
                            for r in report["native_rounds"] for f in r["failures"]))

    def test_incomplete_counts_fail_closed(self) -> None:
        fake = self.default_fake(default_payload=INCOMPLETE_PAYLOAD)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("counts missing/incomplete" in f
                            for r in report["native_rounds"] for f in r["failures"]))

    def test_inconsistent_totals_fail_closed(self) -> None:
        fake = self.default_fake(default_payload=INCONSISTENT_PAYLOAD)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)

    def test_zero_native_tests_fail_closed(self) -> None:
        fake = self.default_fake(default_payload=ZERO_PAYLOAD)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("zero native tests" in f
                            for r in report["native_rounds"] for f in r["failures"]))

    def test_malformed_summary_fail_closed(self) -> None:
        fake = self.default_fake(summary_garbage=True)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(all(r["tests"] is None for r in report["native_rounds"]))

    def test_unavailable_xcresulttool_fail_closed(self) -> None:
        fake = self.default_fake(summary_broken=True)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)

    def test_missing_result_bundle_fail_closed(self) -> None:
        fake = self.default_fake(bundle_missing_rounds={3})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("no test result" in f
                            for f in report["native_rounds"][2]["failures"]))

    def test_reported_test_failures_fail_round_even_on_zero_exit(self) -> None:
        fake = self.default_fake(native_payloads={2: FAILED_PAYLOAD})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["native_rounds"][1]["status"], "fail")
        self.assertTrue(any("2 test(s) failed" in f
                            for f in report["native_rounds"][1]["failures"]))

    def test_partial_skips_pass_repetition_but_never_claim_full_acceptance(self) -> None:
        fake = self.default_fake(default_payload=PASSING_PAYLOAD)  # 1 skipped
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        self.assertTrue(report["skips_present"])
        self.assertEqual(report["native_rounds"][0]["tests"]["skipped"], 1)
        self.assertEqual(report["native_rounds"][0]["tests"]["total"], 12)
        md = (self.run_dir() / "five-pass-report.md").read_text(encoding="utf-8")
        self.assertIn("Skips present: True", md)
        self.assertIn("coverage is incomplete", md)
        for d in report["disclaimers"]:
            self.assertIn(d, md)


# ---------------------------------------------------------------------------
# Kit counting (actual failure scenarios)
# ---------------------------------------------------------------------------

class TestKitCounting(DryRunFixture):
    def test_mixed_zero_xctest_nonzero_swift_testing_passes(self) -> None:
        out = "Test run with 6 tests passed after 0.2s"
        fake = self.default_fake(kit_outputs={i: out for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        self.assertEqual(report["kit_rounds"][0]["tests"],
                         {"total": 6, "passed": 6, "failed": 0, "skipped": 0})

    def test_explicit_swift_testing_failure_fails_on_zero_exit(self) -> None:
        out = "Test run with 3 tests failed after 1.0s"
        fake = self.default_fake(kit_outputs={i: out for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("Swift Testing run failed" in f
                            for f in report["kit_rounds"][0]["failures"]))

    def test_missing_kit_counts_fail_on_zero_exit(self) -> None:
        fake = self.default_fake(kit_outputs={i: "compiling..." for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("exit 0 alone never proves tests ran" in f
                            for f in report["kit_rounds"][0]["failures"]))

    def test_all_skipped_kit_round_fails(self) -> None:
        out = "Test run with 5 tests skipped after 0.1s"
        fake = self.default_fake(kit_outputs={i: out for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("no executed/passed Kit tests" in f
                            for f in report["kit_rounds"][0]["failures"]))

    def test_nonzero_exit_always_fails(self) -> None:
        fake = self.default_fake(kit_exits=[0, 0, 0, 0, 130])
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["kit_rounds"][4]["status"], "fail")

    def test_last_aggregate_xctest_line_used_not_summed(self) -> None:
        out = ("Suite A: Executed 3 tests, with 1 failure\n"
               "Suite B: Executed 7 tests, with 0 failures\n"
               "Executed 10 tests, with 0 failures\n")
        fake = self.default_fake(kit_outputs={i: out for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        self.assertEqual(report["kit_rounds"][0]["tests"],
                         {"total": 10, "passed": 10, "failed": 0, "skipped": 0})

    def test_last_aggregate_line_failures_are_not_hidden(self) -> None:
        out = ("Executed 3 tests, with 0 failures\n"
               "Executed 9 tests, with 2 failures\n")
        fake = self.default_fake(kit_outputs={i: out for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["kit_rounds"][0]["tests"]["failed"], 2)

    def test_swift_testing_failures_combine_with_xctest(self) -> None:
        out = ("Executed 8 tests, with 0 failures\n"
               "Test run with 2 tests failed after 0.4s\n")
        fake = self.default_fake(kit_outputs={i: out for i in range(1, 6)})
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertIsNone(report["kit_rounds"][0]["tests"])
        self.assertTrue(any("Swift Testing run failed" in f
                            for f in report["kit_rounds"][0]["failures"]))

    def test_real_stderr_all_disabled_is_not_a_pass(self) -> None:
        stderr = ("➜ Test first() skipped: disabled\n➜ Test second() skipped: disabled\n"
                  "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n")
        fake = self.default_fake()
        original = fake.__call__
        def with_stderr(argv, cwd):
            fake.helper = str(self.helper_path)
            fake.guard_tool = str(self.guard_tool_path)
            result = original(argv, cwd)
            if "swift" in argv and "test" in argv:
                result.stdout = ""
                result.stderr = stderr
            return result
        code, _ = self.run_main(with_stderr)
        self.assertEqual(code, 1)
        self.assertEqual(self.read_report()["kit_rounds"][0]["tests"],
                         {"total": 2, "passed": 0, "failed": 0, "skipped": 2})

    def test_real_stderr_failed_run_cannot_hide_behind_xctest(self) -> None:
        fake = self.default_fake()
        original = fake.__call__
        def with_stderr(argv, cwd):
            fake.helper = str(self.helper_path)
            fake.guard_tool = str(self.guard_tool_path)
            result = original(argv, cwd)
            if "swift" in argv and "test" in argv:
                result.stdout = "Executed 20 tests, with 0 failures\n"
                result.stderr = "✘ Test run with 4 tests in 4 suites failed after 0.2 seconds with 1 issue.\n"
            return result
        code, _ = self.run_main(with_stderr)
        self.assertEqual(code, 1)
        self.assertIsNone(self.read_report()["kit_rounds"][0]["tests"])


# ---------------------------------------------------------------------------
# Mixed XCTest + Swift Testing logs (P1: ST skip scoping)
# ---------------------------------------------------------------------------

class TestMixedFrameworkLogs(unittest.TestCase):
    """Real mixed `swift test` logs must parse without false blockers.

    Real logs interleave XCTest (whose skip lines look like
    `Test Case '...' skipped (0.1 seconds).` and `... : Test skipped - Set ...`)
    with the Swift Testing section starting at `◇ Test run started.`. Swift
    Testing skip accounting is scoped to that section so XCTest skip lines can
    never contaminate it.
    """

    def test_xctest_skip_lines_do_not_contaminate_swift_testing(self) -> None:
        out = (
            "/path/to/DayPageKit/Tests/DayPageStorageTests/SupabaseLiveTestConfiguration.swift:24:"
            " -[DayPageStorageTests.SupabaseSyncLiveTests testLocalVault] : Test skipped - "
            "Set DAYPAGE_SYNC_E2E_URL and DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY\n"
            "Test Case '-[DayPageStorageTests.SupabaseSyncLiveTests testLocalVault]' "
            "skipped (0.003 seconds).\n"
            "\t Executed 5 tests, with 2 tests skipped and 0 failures (0 unexpected) "
            "in 0.100 (0.101) seconds\n"
            "\t Executed 5 tests, with 2 tests skipped and 0 failures (0 unexpected) "
            "in 0.100 (0.102) seconds\n"
            "◇ Test run started.\n"
            "◇ Test unknownEventTypesAreSkipped() started.\n"
            "✔ Test unknownEventTypesAreSkipped() passed after 0.005 seconds.\n"
            "✔ Test run with 3 tests in 1 suite passed after 0.01 seconds.\n"
        )
        self.assertEqual(rfp.parse_swift_test_counts(out),
                         {"total": 8, "passed": 6, "failed": 0, "skipped": 2})

    def test_real_aggregate_shapes_parse_262_259_0_3(self) -> None:
        out = (
            "/path/to/DayPageKit/Tests/DayPageStorageTests/SupabaseLiveTestConfiguration.swift:24:"
            " -[DayPageStorageTests.SupabaseSyncLiveTests testOne] : Test skipped - "
            "Set DAYPAGE_SYNC_E2E_URL and DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY\n"
            "Test Case '-[DayPageStorageTests.SupabaseSyncLiveTests testOne]' "
            "skipped (0.003 seconds).\n"
            "\t Executed 195 tests, with 3 tests skipped and 0 failures (0 unexpected) "
            "in 3.856 (3.891) seconds\n"
            "\t Executed 195 tests, with 3 tests skipped and 0 failures (0 unexpected) "
            "in 3.856 (3.901) seconds\n"
            "◇ Test run started.\n"
            "◇ Test \"Platform callbacks are distinct and stable\" started.\n"
            "✔ Test \"Platform callbacks are distinct and stable\" passed after 0.001 seconds.\n"
            "✔ Test run with 67 tests in 10 suites passed after 0.535 seconds.\n"
        )
        self.assertEqual(rfp.parse_swift_test_counts(out),
                         {"total": 262, "passed": 259, "failed": 0, "skipped": 3})

    def test_st_disabled_skips_inside_section_still_counted(self) -> None:
        out = (
            "Test Case '-[Kit.A testX]' skipped (0.01 seconds).\n"
            "\t Executed 5 tests, with 1 test skipped and 0 failures (0 unexpected) "
            "in 0.1 seconds\n"
            "◇ Test run started.\n"
            "➜ Test first() skipped: disabled\n"
            "➜ Test second() skipped: disabled\n"
            "✔ Test run with 3 tests in 1 suite passed after 0.01 seconds.\n"
        )
        self.assertEqual(rfp.parse_swift_test_counts(out),
                         {"total": 8, "passed": 5, "failed": 0, "skipped": 3})

    def test_suite_level_skip_inside_section_still_rejected(self) -> None:
        out = (
            "◇ Test run started.\n"
            "➜ Suite Disabled skipped: disabled\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.01 seconds.\n"
        )
        self.assertIsNone(rfp.parse_swift_test_counts(out))

    def test_unknown_st_summary_inside_section_still_rejected(self) -> None:
        out = (
            "Executed 4 tests, with 0 failures\n"
            "◇ Test run started.\n"
            "Test run with unknown results\n"
        )
        self.assertIsNone(rfp.parse_swift_test_counts(out))

    def test_sanitized_mixed_fixture_parses_expected_counts(self) -> None:
        text = (FIXTURES_DIR / "mixed-xctest-swift-testing.log").read_text(encoding="utf-8")
        self.assertNotIn("/Users/", text, "fixture must not carry personal absolute paths")
        self.assertIn("◇ Test run started.", text)
        self.assertEqual(rfp.parse_swift_test_counts(text),
                         {"total": 20, "passed": 17, "failed": 0, "skipped": 3})


# ---------------------------------------------------------------------------
# Source identity (adversarial)
# ---------------------------------------------------------------------------

class TestSourceIdentity(DryRunFixture):
    def test_exact_current_source_receipt(self) -> None:
        sha = "f" * 40
        untracked = self.root / "repo" / "untracked-notes.txt"
        expected_untracked = hashlib.sha256(untracked.read_bytes()).hexdigest()
        expected_pbx = hashlib.sha256(
            (self.repo / "DayPage.xcodeproj" / "project.pbxproj").read_bytes()).hexdigest()
        fake = self.default_fake(
            sha=sha, diff_text="dirty diff body\n",
            status_output=" M DayPage/DayPageApp.swift\n?? untracked-notes.txt\n")
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)

        receipt = self.read_receipt()
        src = receipt["source"]
        self.assertEqual(src["sha"], sha)
        self.assertEqual(src["dirty_paths"], ["DayPage/DayPageApp.swift", "untracked-notes.txt"])
        self.assertEqual(src["tracked_diff_sha256"],
                         hashlib.sha256(b"dirty diff body\n").hexdigest())
        self.assertEqual(src["untracked_hashes"]["untracked-notes.txt"], expected_untracked)
        self.assertEqual(src["build_input_hashes"]["DayPage.xcodeproj/project.pbxproj"],
                         expected_pbx)
        report = self.read_report()
        for r in report["native_rounds"] + report["kit_rounds"]:
            self.assertEqual(r["source_sha"], sha)
        self.assertEqual(report["checkpoints"][0]["stage"], "frozen")
        logs = "\n".join(path.read_text() for path in (self.run_dir() / "logs").glob("*.log"))
        self.assertNotIn("dirty diff body", logs)
        self.assertNotIn("untracked file contents", logs)
        self.assertIn("source diff omitted; sha256=", logs)

    def test_adversarial_untracked_change_stops_run_and_skips_stale_build(self) -> None:
        notes = self.repo / "untracked-notes.txt"

        def hook(argv, count):
            # During native round 2, mutate an already-present untracked file.
            if "test-without-building" in argv and count > 0:
                if len([c for c in fake.action_commands("test-without-building")]) == 1:
                    notes.write_text("notes v2 — adversarial change", encoding="utf-8")

        fake = self.default_fake(hook=hook)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["verdict"], "fail")
        statuses = [r["status"] for r in report["native_rounds"]]
        self.assertEqual(statuses[:2], ["pass", "pass"])
        self.assertTrue(all(s == "not_run" for s in statuses[2:]),
                        f"rounds after drift must stop, got {statuses}")
        self.assertTrue(all(r["status"] == "not_run" for r in report["kit_rounds"]))
        self.assertTrue(any("source changed during run" in f for f in report["failures"]))
        self.assertTrue(any("untracked file changed" in d
                            for c in report["checkpoints"] for d in c["drift"]))
        # Stale build never re-used: no test command ran after the drift checkpoint.
        n_cmds = fake.action_commands("test-without-building")
        self.assertEqual(len(n_cmds), 2)

    def test_adversarial_tracked_diff_change_invalidates(self) -> None:
        # The tracked diff is different after the first native round: an
        # already-dirty file modified to different content must invalidate.
        fake = self.default_fake(
            diff_text="original dirty diff\n",
            status_output=" M DayPage/Dirty.swift\n",
            diff_after=(4, "modified dirty diff\n"))
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertTrue(any("tracked diff content changed" in d
                            for c in report["checkpoints"] for d in c["drift"]))
        self.assertEqual(report["verdict"], "fail")

    def test_existing_run_evidence_never_overwritten(self) -> None:
        existing = self.artifacts / "five-pass-run-19990101T000000Z-deadbeef"
        existing.mkdir()
        sentinel = existing / "five-pass-report.json"
        sentinel.write_text('{"verdict": "other run"}', encoding="utf-8")
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), '{"verdict": "other run"}')
        self.assertNotEqual(self.run_dir(), existing)
        # Our own reports are exclusive-created inside our own run child.
        self.assertTrue((self.run_dir() / "five-pass-report.json").is_file())


# ---------------------------------------------------------------------------
# Robustness: interrupts, missing tools, receipts
# ---------------------------------------------------------------------------

class TestRobustness(DryRunFixture):
    def test_keyboard_interrupt_preserves_failure_report(self) -> None:
        def hook(argv, count):
            if "build-for-testing" in argv:
                raise KeyboardInterrupt

        fake = self.default_fake(hook=hook)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 130)
        report = self.read_report()
        self.assertEqual(report["verdict"], "fail")
        self.assertTrue(any("keyboard interrupt" in f for f in report["failures"]))

    def test_missing_tool_preserves_failure_report(self) -> None:
        def hook(argv, count):
            if argv[0] == str(self.helper_path):
                raise FileNotFoundError(2, "No such file or directory", argv[0])

        fake = self.default_fake(hook=hook)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["verdict"], "fail")
        self.assertTrue(any("missing tool" in f for f in report["failures"]))

    def test_receipt_written_once_and_never_rewritten(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        receipt_path = self.run_dir() / "source-receipt.json"
        first = receipt_path.read_text(encoding="utf-8")
        self.assertIn('"frozen_at"', first)
        checkpoints = (self.run_dir() / "checkpoints.log").read_text(encoding="utf-8")
        self.assertIn('"frozen"', checkpoints)
        self.assertIn("after_build", checkpoints)
        self.assertIn("after_native_round_5", checkpoints)
        self.assertIn("after_kit_round_5", checkpoints)
        self.assertEqual(first, receipt_path.read_text(encoding="utf-8"))

    def test_exclusive_writes_refuse_overwrite(self) -> None:
        target = self.root / "evidence.txt"
        rfp.FivePassRunner._write_exclusive(target, "first\n")
        with self.assertRaises(FileExistsError):
            rfp.FivePassRunner._write_exclusive(target, "second\n")
        self.assertEqual(target.read_text(encoding="utf-8"), "first\n")


# ---------------------------------------------------------------------------
# Serial reuse, routing, disclaimers
# ---------------------------------------------------------------------------

class TestSerialReuseAndRouting(DryRunFixture):
    def test_one_build_unique_bundles_serial_reuse(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)

        builds = fake.action_commands("build-for-testing")
        self.assertEqual(len(builds), 1)
        rounds = fake.action_commands("test-without-building")
        self.assertEqual(len(rounds), 5)
        bundles = [c[c.index("-resultBundlePath") + 1] for c in rounds]
        self.assertEqual(len(set(bundles)), 5)

        kit = [c for c in fake.helper_commands() if "swift" in c]
        self.assertEqual(len(kit), 5)
        scratches = {c[c.index("--scratch-path") + 1] for c in kit}
        self.assertEqual(len(scratches), 1, "kit rounds must reuse one scratch path")
        for c in kit:
            self.assertIn("--no-parallel", c)
            self.assertEqual(c[c.index("--jobs") + 1], "2")

        order = [c for c in fake.helper_commands()
                 if "build-for-testing" in c or "test-without-building" in c or "swift" in c]
        self.assertEqual(order, [builds[0], *rounds, *kit], "native and kit must be serial")

        for c in rounds:
            self.assertEqual(c[c.index("-parallel-testing-enabled") + 1], "NO")
            self.assertEqual(
                c[c.index("-maximum-concurrent-test-simulator-destinations") + 1], "1")

    def test_native_build_and_rounds_select_isolated_unit_host(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        commands = fake.action_commands("build-for-testing") + fake.action_commands("test-without-building")
        self.assertEqual(len(commands), 6)
        for command in commands:
            for setting in rfp.UNIT_HOST_BUILD_FLAGS:
                self.assertIn(setting, command)
            self.assertFalse(any(x.startswith("SWIFT_ACTIVE_COMPILATION_CONDITIONS=") for x in command))

    def test_all_native_commands_route_through_session_helper(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        for c in fake.commands:
            if c[0] == "git" or c[0] == "xcrun" or c[0] == str(self.guard_tool_path):
                continue  # read-only receipt, result parsing, guard audit
            self.assertEqual(c[:2], (str(self.helper_path), "run"))
            self.assertIn("--", c, f"command not routed through session helper: {c}")
        for c in fake.commands:
            for banned in ("simctl", "boot", "erase", "clone", "delete", "shutdown"):
                self.assertNotIn(banned, c, f"device lifecycle command leaked: {c}")
        native = fake.helper_commands()
        self.assertTrue(
            all(c[c.index("--") + 1] in ("xcodebuild", "swift") for c in native))

    def test_report_carries_disclaimers_and_registration(self) -> None:
        fake = self.default_fake()
        code, argv = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        self.assertEqual(report["verdict"], "pass")
        for disclaimer in rfp.DISCLAIMERS:
            self.assertIn(disclaimer, report["disclaimers"])
        md = (self.run_dir() / "five-pass-report.md").read_text(encoding="utf-8")
        for disclaimer in rfp.DISCLAIMERS:
            self.assertIn(disclaimer, md)
        self.assertIn("does NOT cover every product feature", md)
        self.assertIn("UI navigation success alone is never a pass", md)
        owner = json.loads((self.run_dir() / "run-owner.json").read_text(encoding="utf-8"))
        self.assertEqual(owner["registered_by"], "caller")
        self.assertEqual(owner["registry"], str(self.registry))
        self.assertEqual(owner["argv"], [sys.argv[0], *argv])


# ---------------------------------------------------------------------------
# Test-ID inventory
# ---------------------------------------------------------------------------

class TestIDInventory(DryRunFixture):
    def test_stable_inventory_reported(self) -> None:
        fake = self.default_fake()
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        self.assertEqual(report["id_inventory"]["status"], "stable")
        self.assertEqual(report["id_inventory"]["test_count"], 2)

    def test_unavailable_inventory_states_verification_limit(self) -> None:
        fake = self.default_fake(tests_broken=True)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 0)
        report = self.read_report()
        self.assertEqual(report["id_inventory"]["status"], "unavailable")
        self.assertIn("verification limit", report["id_inventory"]["note"])

    def test_unstable_inventory_fails_the_run(self) -> None:
        payloads = {i: ["DayPageTests.A.testOne"] for i in range(1, 6)}
        payloads[3] = ["DayPageTests.A.testDifferent"]
        fake = self.default_fake(id_payloads=payloads)
        code, _ = self.run_main(fake)
        self.assertEqual(code, 1)
        report = self.read_report()
        self.assertEqual(report["id_inventory"]["status"], "unstable")
        self.assertTrue(any("test ID inventory unstable" in f for f in report["failures"]))


# ---------------------------------------------------------------------------
# Count parsing units
# ---------------------------------------------------------------------------

class TestCountParsing(unittest.TestCase):
    def test_extract_xcresult_counts_requires_complete_consistent(self) -> None:
        self.assertEqual(rfp.extract_xcresult_counts(CLEAN_PAYLOAD),
                         {"total": 12, "passed": 12, "failed": 0, "skipped": 0,
                          "expected_failures": 0})
        self.assertEqual(rfp.extract_xcresult_counts(ALL_SKIPPED_PAYLOAD)["skipped"], 7)
        self.assertIsNone(rfp.extract_xcresult_counts(INCOMPLETE_PAYLOAD))
        self.assertIsNone(rfp.extract_xcresult_counts(INCONSISTENT_PAYLOAD))
        self.assertIsNone(rfp.extract_xcresult_counts({"title": "no counts"}))
        self.assertIsNone(rfp.extract_xcresult_counts(None))
        self.assertIsNone(rfp.extract_xcresult_counts([1, 2]))
        self.assertIsNone(rfp.extract_xcresult_counts(
            {"totalTests": 2, "passedTests": True, "failedTests": 0, "skippedTests": 0}))

    def test_parse_swift_test_counts_last_line_semantics(self) -> None:
        out = ("Executed 3 tests, with 1 failure\n"
               "Executed 10 tests, with 0 failures\n")
        self.assertEqual(rfp.parse_swift_test_counts(out),
                         {"total": 10, "passed": 10, "failed": 0, "skipped": 0})
        self.assertEqual(rfp.parse_swift_test_counts("Test run with 5 tests passed after 0.1s"),
                         {"total": 5, "passed": 5, "failed": 0, "skipped": 0})
        self.assertIsNone(rfp.parse_swift_test_counts("Test run with 2 tests failed after 0.1s"))
        self.assertEqual(rfp.parse_swift_test_counts("Test run with 4 tests skipped after 0.1s"),
                         {"total": 4, "passed": 0, "failed": 0, "skipped": 4})
        self.assertIsNone(rfp.parse_swift_test_counts("compiling..."))
        self.assertEqual(
            rfp.parse_swift_test_counts("Executed 4 tests, with 0 failures\n"
                                        "Test run with 2 tests passed after 0.1s"),
            {"total": 6, "passed": 6, "failed": 0, "skipped": 0})

    def test_real_framework_summaries_and_skips(self) -> None:
        self.assertEqual(rfp.parse_swift_test_counts(
            "Executed 195 tests, with 3 tests skipped and 0 failures (0 unexpected) in 1.016 seconds\n"
            "✔ Test run with 54 tests in 8 suites passed after 0.045 seconds.\n"),
            {"total": 249, "passed": 246, "failed": 0, "skipped": 3})
        self.assertEqual(rfp.parse_swift_test_counts(
            "➜ Test disabled() skipped: disabled\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.01 seconds.\n"),
            {"total": 2, "passed": 1, "failed": 0, "skipped": 1})
        self.assertIsNone(rfp.parse_swift_test_counts(
            "Executed 20 tests, with 0 failures\n"
            "✘ Test run with 4 tests in 4 suites failed after 0.2 seconds with 1 issue.\n"))
        self.assertIsNone(rfp.parse_swift_test_counts(
            "Executed 20 tests, with 0 failures\nTest run with unknown results\n"))
        self.assertEqual(rfp.parse_swift_test_counts(
            "➜ Suite Disabled skipped: disabled\n➜ Test first() skipped: disabled\n"
            "➜ Test second() skipped: disabled\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.01 seconds.\n"),
            {"total": 2, "passed": 0, "failed": 0, "skipped": 2})
        self.assertEqual(rfp.parse_swift_test_counts(
            "➜ Test param(_:) skipped: disabled\n"
            "✔ Test run with 1 test in 1 suite passed after 0.01 seconds.\n"),
            {"total": 1, "passed": 0, "failed": 0, "skipped": 1})
        self.assertIsNone(rfp.parse_swift_test_counts(
            "➜ Suite Disabled skipped: disabled\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.01 seconds.\n"))

    def test_negative_or_malformed_native_counts_are_rejected(self) -> None:
        for payload in [dict(CLEAN_PAYLOAD, passedTests=-1, totalTests=-1),
                        dict(CLEAN_PAYLOAD, expectedFailures=-1, totalTests=11),
                        dict(CLEAN_PAYLOAD, expectedFailures="unknown")]:
            self.assertIsNone(rfp.extract_xcresult_counts(payload))


# ---------------------------------------------------------------------------
# DayPageTests membership + serialized-root namespace contract
# ---------------------------------------------------------------------------

def _swift_lexer(src: str):
    """Minimal Swift-aware scanner: masks strings/comments, returns braces/tests."""
    n = len(src)
    masked = list(src)
    braces, tests = [], []
    i = 0
    mode = ["code"]
    hashcount = 0
    paren = []
    block_depth = 0

    def blank(a, b):
        for k in range(a, b):
            if masked[k] != "\n":
                masked[k] = " "

    while i < n:
        c = src[i]
        m = mode[-1]
        if m == "line":
            j = src.find("\n", i)
            if j == -1:
                j = n
            blank(i, j)
            i = j
            mode.pop()
            continue
        if m == "block":
            if src.startswith("/*", i):
                blank(i, i + 2)
                block_depth += 1
                i += 2
                continue
            if src.startswith("*/", i):
                blank(i, i + 2)
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    mode.pop()
                continue
            blank(i, i + 1)
            i += 1
            continue
        if m in ("string", "mstring", "regex"):
            if m == "regex":
                if src.startswith("\\", i):
                    blank(i, i + 2)
                    i += 2
                    continue
                if src.startswith("/#", i):
                    blank(i, i + 2)
                    i += 2
                    mode.pop()
                    continue
                blank(i, i + 1)
                i += 1
                continue
            interp_open = "\\" + "#" * hashcount + "("
            if src.startswith(interp_open, i):
                blank(i, i + len(interp_open))
                i += len(interp_open)
                mode.append("code")
                paren.append(0)
                continue
            if c == "\\" and hashcount == 0 and m == "string" and i + 1 < n:
                blank(i, i + 2)
                i += 2
                continue
            if m == "string" and hashcount == 0 and c == '"':
                blank(i, i + 1)
                mode.pop()
                i += 1
                continue
            if m == "mstring" and hashcount == 0 and src.startswith('"""', i):
                blank(i, i + 3)
                mode.pop()
                i += 3
                continue
            term = '"' + "#" * hashcount
            if hashcount > 0 and src.startswith(term, i):
                blank(i, i + len(term))
                mode.pop()
                i += len(term)
                continue
            if hashcount > 0 and m == "mstring" and src.startswith('"""' + "#" * hashcount, i):
                blank(i, i + 3 + hashcount)
                mode.pop()
                i += 3 + hashcount
                continue
            blank(i, i + 1)
            i += 1
            continue
        if src.startswith("//", i):
            mode.append("line")
            blank(i, i + 2)
            i += 2
            continue
        if src.startswith("/*", i):
            mode.append("block")
            block_depth = 1
            blank(i, i + 2)
            i += 2
            continue
        hm = re.match(r'#+(?="""|")', src[i:])
        if hm and (src[i + len(hm.group()):].startswith('"""')
                   or src[i + len(hm.group()):].startswith('"')):
            hashcount = len(hm.group())
            j = i + hashcount
            if src.startswith('"""', j):
                mode.append("mstring")
                blank(i, j + 3)
                i = j + 3
            else:
                mode.append("string")
                blank(i, j + 1)
                i = j + 1
            continue
        if src.startswith('"""', i):
            mode.append("mstring")
            hashcount = 0
            blank(i, i + 3)
            i += 3
            continue
        if c == '"':
            mode.append("string")
            hashcount = 0
            blank(i, i + 1)
            i += 1
            continue
        if src.startswith("#/", i):
            mode.append("regex")
            blank(i, i + 2)
            i += 2
            continue
        if c == "(":
            if paren:
                paren[-1] += 1
            i += 1
            continue
        if c == ")":
            if paren:
                paren[-1] -= 1
                if paren[-1] < 0:
                    mode.pop()
                    paren.pop()
            i += 1
            continue
        if c in "{}":
            braces.append((i, c))
            i += 1
            continue
        if src.startswith("@Test", i):
            tests.append(i)
            i += 1
            continue
        i += 1
    return "".join(masked), braces, tests


# Repository contracts remain hard gates even when the entire feature is absent.
# A missing test registration or serialized root must fail, never skip.


class TestDayPageTestsMembership(unittest.TestCase):
    """Hard contract for complete production test-target registration."""

    def _pbxproj(self) -> str:
        return (REPO_ROOT / "DayPage.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

    def test_all_test_files_registered_exactly_once_in_target_sources(self) -> None:
        pbx = self._pbxproj()
        files = sorted(p.name for p in (REPO_ROOT / "DayPageTests").glob("*.swift"))
        self.assertEqual(len(files), 66, "DayPageTests is expected to hold 66 Swift files")
        m = re.search(r"T90000001 /\* Sources \*/ = \{.*?files = \((.*?)\);", pbx, re.S)
        self.assertIsNotNone(m, "DayPageTests sources phase T90000001 not found")
        entries = re.findall(r"/\* (.+?) in Sources \*/,", m.group(1))
        self.assertEqual(sorted(entries), files)
        self.assertEqual(len(entries), len(set(entries)), "duplicate sources entries")

    def test_group_membership_complete_and_refs_consistent(self) -> None:
        pbx = self._pbxproj()
        files = sorted(p.name for p in (REPO_ROOT / "DayPageTests").glob("*.swift"))
        m = re.search(r"T50000001 /\* DayPageTests \*/ = \{.*?children = \((.*?)\);", pbx, re.S)
        self.assertIsNotNone(m)
        entries = re.findall(r"/\* (.+?) \*/,", m.group(1))
        self.assertEqual(sorted(entries), files)
        build = re.findall(
            r"^\t\t([A-Za-z0-9]+) /\* (.+?) in Sources \*/ = "
            r"\{isa = PBXBuildFile; fileRef = ([A-Za-z0-9]+) /\* (.+?) \*/;",
            pbx, re.M)
        refs = dict(re.findall(r"^\t\t([A-Za-z0-9]+) /\* (.+?) \*/ = \{isa = PBXFileReference;",
                               pbx, re.M))
        for _bid, name, fref, ref_name in build:
            self.assertEqual(name, ref_name)
            self.assertIn(fref, refs)
            self.assertEqual(refs[fref], name)


class TestSerializedNamespace(unittest.TestCase):
    """All Swift Testing suites must nest under the .serialized root."""

    def test_serial_root_exists_with_serialized_trait(self) -> None:
        smoke = (REPO_ROOT / "DayPageTests" / "SmokeTest.swift").read_text(encoding="utf-8")
        self.assertIn('@Suite("DayPageSerialSwiftTests", .serialized)', smoke)
        self.assertIn("struct DayPageSerialSwiftTests", smoke)

    def test_every_test_lives_under_serial_root(self) -> None:
        problems = []
        alias_map: dict[str, str] = {}
        for path in sorted((REPO_ROOT / "DayPageTests").glob("*.swift")):
            src = path.read_text(encoding="utf-8")
            masked, braces, tests = _swift_lexer(src)
            self.assertEqual(masked.count("{"), masked.count("}"),
                             f"{path.name}: unbalanced braces")
            for m in re.finditer(
                    r"^typealias\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
                    r"DayPageSerialSwiftTests\.([A-Za-z0-9_]+)", masked, re.M):
                alias_map[m.group(1)] = m.group(2)
            stack: list[str] = []
            for pos, tok in sorted(braces + [(p, "@") for p in tests]):
                if tok == "{":
                    pre = masked[max(0, pos - 220):pos]
                    hm = re.search(
                        r"((?:class|struct|enum|actor|extension)\s+[A-Za-z_][A-Za-z0-9_.]*)\s*$",
                        pre)
                    stack.append(hm.group(1) if hm else "?")
                elif tok == "}":
                    if stack:
                        stack.pop()
                else:
                    ok = any(
                        s == "extension DayPageSerialSwiftTests"
                        or (s.startswith("extension ")
                            and s.split(" ", 1)[1] in alias_map)
                        for s in stack)
                    if not ok:
                        problems.append(f"{path.name}: @Test outside root namespace: {stack}")
        self.assertEqual(problems, [])

    def test_all_moved_suites_have_namespace_aliases(self) -> None:
        expected = {
            "AccessibilityTests", "AppIntentsTests", "ArchiveViewModelGroupTests",
            "CaptureReminderServiceTests", "DailyPageParserEvidenceTests", "DayProgressTests",
            "DoubaoASRResolutionTests", "DoubaoASRTests", "DoubaoConnectivityTesterTests",
            "EntitySlugDedupTests", "EntityTypeSingularTests", "GraphViewModelFilterCacheTests",
            "GraphFocusAndWeightTests", "HapticFeedbackTests", "KeychainHelperTests",
            "LocationServiceLRUTests", "MarkdownExportServiceTests", "MemoExifShutterTests",
            "AttachmentImagePipelineTests", "MemoDetailRefTests", "MemoMarkdownTests",
            "MemoSerializationTests", "MemoSyncE2EIntegrationTests", "MemoSyncMapperTests",
            "MemoSyncResponseTests", "SyncSettingsTests", "MemoYAMLTests",
            "LLMClientParseTests", "GraphRetrieverParseTests", "RetrievedContextTests",
            "MemoryChatServiceTests", "LLMClientSSETests", "MemoAnchoredChatTests",
            "NetworkMonitorTests", "OnThisDayHeaderTests", "OnThisDayIntegrationTests",
            "ParserTests", "PhotoServiceBackgroundTests", "RawStorageWriteFailedTests",
            "ReminderIntentParserTests", "SearchHighlightTests", "SearchServiceTests",
            "SmokeTest", "SwipePolishContractTests", "SyncQueueServiceTests",
            "SystemActionAppleAdapterTests", "SystemActionUIModelTests",
            "TimeOfDayBucketTests", "ContinuousTintTests", "DayProgressFractionTests",
            "TimeZoneBadgeTests", "TimeOfDayTests", "TodayViewModelTests", "TrashTTLTests",
            "VaultExportServiceTests", "WeatherServiceCacheTests",
            "WeeklyCompilationServiceTests", "WeeklyRecapAutoTriggerTests",
            "WeeklyRecapRangeTests", "WriteSheetCountTests",
        }
        found: set[str] = set()
        for path in (REPO_ROOT / "DayPageTests").glob("*.swift"):
            src = path.read_text(encoding="utf-8")
            for m in re.finditer(
                    r"^typealias\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
                    r"DayPageSerialSwiftTests\.([A-Za-z0-9_]+)", src, re.M):
                self.assertEqual(m.group(1), m.group(2), f"{path.name}: alias mismatch")
                found.add(m.group(1))
        self.assertEqual(found, expected)

    def test_search_service_extension_resolves_via_alias(self) -> None:
        src = (REPO_ROOT / "DayPageTests" / "SearchServiceTests.swift").read_text(encoding="utf-8")
        self.assertIn("typealias SearchServiceTests = DayPageSerialSwiftTests.SearchServiceTests",
                      src)
        self.assertIn("extension SearchServiceTests {", src)
        masked, _braces, tests = _swift_lexer(src)
        self.assertTrue(tests, "SearchIndexParity suite keeps its @Test members")


if __name__ == "__main__":
    unittest.main()
