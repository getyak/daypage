"""Tests for issue_pulse.cli — `tracker.scan` is mocked.

Run with:  python -m unittest issue_pulse.tests.test_cli
"""
from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

from issue_pulse import cli, config, tracker


def _make_change(kind: str = "opened", number: int = 1) -> tracker.StateChange:
    return tracker.StateChange(
        number=number, title="hello", kind=kind, detail="", timestamp="2026-05-04T00:00:00Z",
    )


class CliScanTests(unittest.TestCase):
    def test_scan_success_prints_summary_and_writes_dashboard(self) -> None:
        result = ([], [], [_make_change("opened", 1), _make_change("closed", 2)])
        with mock.patch("issue_pulse.cli.scan", return_value=result), \
             mock.patch("issue_pulse.cli.write_dashboard", return_value=Path("/tmp/x.md")) as wrote:
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--repo", "x/y", "scan"])
        self.assertEqual(rc, 0)
        wrote.assert_called_once_with(repo="x/y")
        out = buf.getvalue()
        self.assertIn("opened", out)
        self.assertIn("closed", out)
        self.assertIn("repo=x/y", out)

    def test_scan_failure_returns_exit_code_2(self) -> None:
        with mock.patch("issue_pulse.cli.scan", side_effect=RuntimeError("auth fail")):
            err = io.StringIO()
            with redirect_stderr(err):
                rc = cli.main(["--repo", "x/y", "scan"])
        self.assertEqual(rc, 2)
        self.assertIn("auth fail", err.getvalue())

    def test_scan_full_flag_passed_through(self) -> None:
        with mock.patch("issue_pulse.cli.scan", return_value=([], [], [])) as scanned, \
             mock.patch("issue_pulse.cli.write_dashboard", return_value=Path("/tmp/x.md")):
            with redirect_stdout(io.StringIO()):
                cli.main(["--repo", "x/y", "scan", "--full"])
        self.assertTrue(scanned.call_args.kwargs.get("force_full"))


class CliStatusTests(unittest.TestCase):
    def test_status_missing_dashboard_returns_1(self) -> None:
        with TemporaryDirectory() as tmp:
            with mock.patch.object(config, "OUTPUT_PATH", Path(tmp) / "missing.md"):
                err = io.StringIO()
                with redirect_stderr(err):
                    rc = cli.main(["status"])
        self.assertEqual(rc, 1)
        self.assertIn("no dashboard yet", err.getvalue())

    def test_status_prints_dashboard(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "dash.md"
            path.write_text("# Hello\n", encoding="utf-8")
            with mock.patch.object(config, "OUTPUT_PATH", path):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = cli.main(["status"])
        self.assertEqual(rc, 0)
        self.assertIn("# Hello", buf.getvalue())


class CliDiffTests(unittest.TestCase):
    def test_diff_no_changelog(self) -> None:
        with TemporaryDirectory() as tmp:
            with mock.patch.object(config, "CHANGELOG_PATH", Path(tmp) / "no.log"):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = cli.main(["diff"])
        self.assertEqual(rc, 0)
        self.assertIn("no changelog yet", buf.getvalue())

    def test_diff_prints_recent(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "log.jsonl"
            entries = [
                {"timestamp": "t1", "kind": "opened", "number": 1, "title": "a", "detail": ""},
                {"timestamp": "t2", "kind": "closed", "number": 2, "title": "b", "detail": "by=x"},
            ]
            path.write_text("\n".join(json.dumps(e) for e in entries) + "\n", encoding="utf-8")
            with mock.patch.object(config, "CHANGELOG_PATH", path):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = cli.main(["diff", "--limit", "1"])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        # --limit 1 → only the last entry (closed #2)
        self.assertIn("#2", out)
        self.assertIn("closed", out)
        self.assertNotIn("#1", out)


class CliMarkerMapTests(unittest.TestCase):
    def test_marker_map_uses_opened_not_new(self) -> None:
        self.assertIn("opened", cli._KIND_MARKERS)
        self.assertNotIn("new", cli._KIND_MARKERS)
        self.assertIn("unknown_dropped", cli._KIND_MARKERS)


if __name__ == "__main__":
    unittest.main()
