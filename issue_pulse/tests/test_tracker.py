"""Tests for issue_pulse.tracker and issue_pulse.display.

Run with:  python -m unittest issue_pulse.tests.test_tracker
"""
from __future__ import annotations

import json
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

from issue_pulse import display, tracker


def _issue(
    number: int,
    state: str = "OPEN",
    title: str = "Sample issue",
    labels: list[str] | None = None,
    created_days_ago: int = 1,
    updated_days_ago: int | None = None,
    closed_days_ago: int | None = None,
    closed_by: str | None = None,
    assignees: list[str] | None = None,
    milestone: str | None = None,
    comments: int = 0,
) -> tracker.Issue:
    now = datetime.now(timezone.utc)
    created = (now - timedelta(days=created_days_ago)).isoformat(timespec="seconds")
    updated_ago = updated_days_ago if updated_days_ago is not None else created_days_ago
    updated = (now - timedelta(days=updated_ago)).isoformat(timespec="seconds")
    closed = (
        (now - timedelta(days=closed_days_ago)).isoformat(timespec="seconds")
        if closed_days_ago is not None
        else None
    )
    return tracker.Issue(
        number=number,
        title=title,
        state=state,
        labels=labels or [],
        created_at=created,
        updated_at=updated,
        closed_at=closed,
        closed_by=closed_by,
        url=f"https://github.com/example/repo/issues/{number}",
        assignees=assignees or [],
        milestone=milestone,
        comments=comments,
    )


class CacheRoundTripTests(unittest.TestCase):
    def test_save_and_load(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "cache.json"
            payload = {
                "repo": "example/repo",
                "fetched_at": "2026-05-04T00:00:00+00:00",
                "issues": {"1": _issue(1).to_dict()},
            }
            tracker.save_cache(payload, path)
            self.assertTrue(path.exists())
            loaded = tracker.load_cache(path)
            self.assertEqual(loaded["repo"], "example/repo")
            self.assertIn("1", loaded["issues"])
            # New skeleton keys should be present after load.
            self.assertIn("last_synced_at", loaded)
            self.assertIn("close_time_total_seconds", loaded)
            self.assertIn("close_time_count", loaded)
            self.assertIn("counted_closed_numbers", loaded)

    def test_load_missing_returns_skeleton(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "missing.json"
            data = tracker.load_cache(path)
            self.assertIsNone(data["repo"])
            self.assertIsNone(data["fetched_at"])
            self.assertEqual(data["issues"], {})
            self.assertEqual(data["close_time_count"], 0)

    def test_load_corrupt_returns_skeleton(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "corrupt.json"
            path.write_text("{not json", encoding="utf-8")
            data = tracker.load_cache(path)
            self.assertEqual(data["issues"], {})

    def test_save_is_atomic(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "cache.json"
            tracker.save_cache({"issues": {"1": _issue(1).to_dict()}}, path)
            tracker.save_cache({"issues": {"2": _issue(2).to_dict()}}, path)
            data = json.loads(path.read_text(encoding="utf-8"))
            leftover = list(Path(tmp).glob(".issue_cache.*"))
            self.assertEqual(leftover, [])
            self.assertIn("2", data["issues"])


class DiffDetectionTests(unittest.TestCase):
    def test_new_open_issue(self) -> None:
        prev: dict[int, tracker.Issue] = {}
        curr = {1: _issue(1)}
        changes = tracker.diff_issues(prev, curr)
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0].kind, "opened")

    def test_open_to_closed(self) -> None:
        prev = {1: _issue(1, state="OPEN")}
        curr = {1: _issue(1, state="CLOSED", closed_days_ago=0, closed_by="alice")}
        changes = tracker.diff_issues(prev, curr, confirmed_closed={1})
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0].kind, "closed")
        self.assertIn("alice", changes[0].detail)

    def test_reopened(self) -> None:
        prev = {1: _issue(1, state="CLOSED", closed_days_ago=2)}
        curr = {1: _issue(1, state="OPEN")}
        changes = tracker.diff_issues(prev, curr)
        self.assertEqual(changes[0].kind, "reopened")

    def test_label_change(self) -> None:
        prev = {1: _issue(1, labels=["bug"])}
        curr = {1: _issue(1, labels=["bug", "p1"])}
        changes = tracker.diff_issues(prev, curr)
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0].kind, "labels_changed")
        self.assertIn("+p1", changes[0].detail)

    def test_no_change(self) -> None:
        prev = {1: _issue(1, labels=["bug"])}
        curr = {1: _issue(1, labels=["bug"])}
        curr[1].created_at = prev[1].created_at
        curr[1].updated_at = prev[1].updated_at
        changes = tracker.diff_issues(prev, curr)
        self.assertEqual(changes, [])

    def test_dropped_open_issue_is_unknown_not_closed(self) -> None:
        prev = {1: _issue(1, state="OPEN")}
        curr: dict[int, tracker.Issue] = {}
        changes = tracker.diff_issues(prev, curr, confirmed_closed=set())
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0].kind, "unknown_dropped")

    def test_dropped_open_issue_confirmed_closed(self) -> None:
        prev = {1: _issue(1, state="OPEN")}
        curr: dict[int, tracker.Issue] = {}
        changes = tracker.diff_issues(prev, curr, confirmed_closed={1})
        self.assertEqual(changes[0].kind, "closed")


class DisplayFormattingTests(unittest.TestCase):
    def test_render_open_table_includes_urgency_markers(self) -> None:
        # Stale by `updated_at` triggers markers.
        old = _issue(1, title="Old issue", created_days_ago=40, updated_days_ago=40)
        warn = _issue(2, title="Warn issue", created_days_ago=10, updated_days_ago=10)
        fresh = _issue(3, title="Fresh issue", created_days_ago=1, updated_days_ago=1)
        now = datetime.now(timezone.utc)
        out = display.render_open_table([old, warn, fresh], now)
        self.assertIn("🚨", out)
        self.assertIn("⚠️", out)
        self.assertIn("Fresh issue", out)

    def test_recent_activity_resets_staleness(self) -> None:
        # Created long ago but updated recently — should NOT be flagged stale.
        active = _issue(1, created_days_ago=100, updated_days_ago=1)
        stats = display.compute_stats([active], [])
        self.assertEqual(stats["stale_count"], 0)
        # But oldest_open_age_days reflects creation.
        self.assertGreaterEqual(stats["oldest_open_age_days"], 100)

    def test_render_closed_table_handles_empty(self) -> None:
        out = display.render_closed_table([])
        self.assertIn("No recently-closed", out)

    def test_render_dashboard_contains_sections(self) -> None:
        opens = [_issue(10, title="Open A", assignees=["alice"], milestone="v1", comments=3)]
        closes = [_issue(11, state="CLOSED", title="Closed A", closed_days_ago=1, closed_by="bob")]
        md = display.render_dashboard(
            repo="example/repo",
            open_issues=opens,
            closed_issues=closes,
        )
        self.assertIn("# 📡 Issue Pulse", md)
        self.assertIn("## 🔴 Open Issues", md)
        self.assertIn("## 🟢 Recently Closed", md)
        self.assertIn("## 📈 Stats", md)
        self.assertIn("example/repo", md)
        self.assertIn("Open A", md)
        self.assertIn("Closed A", md)
        self.assertIn("bob", md)
        self.assertIn("@alice", md)
        self.assertIn("v1", md)

    def test_compute_stats_uses_rolling_counter(self) -> None:
        opens = [_issue(1, created_days_ago=40, updated_days_ago=40)]
        closes: list[tracker.Issue] = []
        # Provide a rolling counter: 2 closed issues averaging 4 days each.
        stats = display.compute_stats(
            opens, closes,
            rolling_total_seconds=8 * 86400,
            rolling_count=2,
        )
        self.assertEqual(stats["avg_close_days"], 4.0)
        self.assertEqual(stats["stale_count"], 1)

    def test_escape_pipe_in_title(self) -> None:
        issue = _issue(99, title="Pipe | in title")
        out = display.render_open_table([issue], datetime.now(timezone.utc))
        self.assertIn("Pipe \\| in title", out)


class GhMockingTests(unittest.TestCase):
    def test_fetch_issues_parses_gh_output(self) -> None:
        sample = json.dumps([
            {
                "number": 7,
                "title": "Hello",
                "state": "OPEN",
                "labels": [{"name": "bug"}, {"name": "p1"}],
                "createdAt": "2026-05-01T10:00:00Z",
                "updatedAt": "2026-05-01T10:00:00Z",
                "closedAt": None,
                "url": "https://github.com/example/repo/issues/7",
                "assignees": [{"login": "alice"}],
                "milestone": {"title": "v2"},
                "comments": 4,
            }
        ])
        with mock.patch.object(tracker, "_run_gh", return_value=sample) as mocked:
            issues = tracker.fetch_issues("example/repo", state="open")
            mocked.assert_called_once()
        self.assertEqual(len(issues), 1)
        issue = issues[0]
        self.assertEqual(issue.number, 7)
        self.assertEqual(issue.labels, ["bug", "p1"])
        self.assertEqual(issue.assignees, ["alice"])
        self.assertEqual(issue.milestone, "v2")
        self.assertEqual(issue.comments, 4)

    def test_fetch_issues_drops_non_github_url(self) -> None:
        sample = json.dumps([{
            "number": 1, "title": "x", "state": "OPEN",
            "labels": [], "createdAt": "", "updatedAt": "",
            "closedAt": None, "url": "https://evil.example/issues/1",
            "assignees": [], "milestone": None, "comments": 0,
        }])
        with mock.patch.object(tracker, "_run_gh", return_value=sample):
            issues = tracker.fetch_issues("example/repo", state="open")
        self.assertEqual(issues[0].url, "")

    def test_fetch_issues_passes_search(self) -> None:
        with mock.patch.object(tracker, "_run_gh", return_value="[]") as mocked:
            tracker.fetch_issues("example/repo", state="all", search="updated:>=2026-04-01")
        args = mocked.call_args[0][0]
        self.assertIn("--search", args)
        self.assertIn("updated:>=2026-04-01", args)

    def test_fetch_closed_by_uses_timeline_api(self) -> None:
        timeline = json.dumps([
            {"event": "labeled", "actor": {"login": "x"}},
            {"event": "closed", "actor": {"login": "alice"}},
        ])
        with mock.patch.object(tracker, "_run_gh", return_value=timeline) as mocked:
            who = tracker.fetch_closed_by("example/repo", 42)
        # The call must hit the REST timeline endpoint.
        args = mocked.call_args[0][0]
        self.assertEqual(args[0], "api")
        self.assertIn("repos/example/repo/issues/42/timeline", args[1])
        self.assertEqual(who, "alice")

    def test_fetch_closed_by_falls_back_to_pr_author(self) -> None:
        timeline = json.dumps([
            {
                "event": "cross-referenced",
                "source": {
                    "issue": {
                        "pull_request": {"url": "..."},
                        "user": {"login": "carol"},
                    }
                }
            },
        ])
        with mock.patch.object(tracker, "_run_gh", return_value=timeline):
            who = tracker.fetch_closed_by("example/repo", 42)
        self.assertEqual(who, "PR by carol")

    def test_fetch_closed_by_returns_none_on_error(self) -> None:
        with mock.patch.object(tracker, "_run_gh", side_effect=RuntimeError("fail")):
            self.assertIsNone(tracker.fetch_closed_by("example/repo", 1))

    def test_run_gh_handles_failure(self) -> None:
        with mock.patch("subprocess.run") as mocked:
            from subprocess import CalledProcessError
            mocked.side_effect = CalledProcessError(
                returncode=1, cmd=["gh"], stderr="boom",
            )
            with self.assertRaises(RuntimeError) as ctx:
                tracker._run_gh(["issue", "list"])
            self.assertIn("boom", str(ctx.exception))


class RollingCounterTests(unittest.TestCase):
    def test_counter_accumulates_unique_closures(self) -> None:
        cache = {
            "close_time_total_seconds": 0.0,
            "close_time_count": 0,
            "counted_closed_numbers": [],
        }
        closed = [
            _issue(1, state="CLOSED", created_days_ago=10, closed_days_ago=8),
            _issue(2, state="CLOSED", created_days_ago=5, closed_days_ago=3),
        ]
        tracker._update_close_time_counter(cache, closed)
        self.assertEqual(cache["close_time_count"], 2)
        # Re-running with the same set must NOT double-count.
        tracker._update_close_time_counter(cache, closed)
        self.assertEqual(cache["close_time_count"], 2)

        # Adding a brand-new closure increments by 1.
        closed.append(_issue(3, state="CLOSED", created_days_ago=4, closed_days_ago=1))
        tracker._update_close_time_counter(cache, closed)
        self.assertEqual(cache["close_time_count"], 3)


class IncrementalSyncTests(unittest.TestCase):
    def test_first_run_does_full_sync(self) -> None:
        with TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "cache.json"
            changelog = Path(tmp) / "log.jsonl"
            with mock.patch.object(tracker, "fetch_issues", return_value=[]) as fetched, \
                 mock.patch.object(tracker, "_populate_closed_by_parallel"):
                tracker.scan(repo="x/y", cache_path=cache_path, changelog_path=changelog)
            # First run must fetch open + closed (2 calls), no `--search`.
            calls = fetched.call_args_list
            self.assertEqual(len(calls), 2)
            for call in calls:
                self.assertNotIn("search", call.kwargs)

    def test_subsequent_run_uses_incremental(self) -> None:
        with TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "cache.json"
            changelog = Path(tmp) / "log.jsonl"
            now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
            seed = {
                "repo": "x/y",
                "fetched_at": now_iso,
                "last_synced_at": now_iso,
                "issues": {"1": _issue(1).to_dict()},
                "close_time_total_seconds": 0.0,
                "close_time_count": 0,
                "counted_closed_numbers": [],
            }
            tracker.save_cache(seed, cache_path)

            with mock.patch.object(tracker, "fetch_issues", return_value=[]) as fetched, \
                 mock.patch.object(tracker, "_populate_closed_by_parallel"):
                tracker.scan(repo="x/y", cache_path=cache_path, changelog_path=changelog)
            # Incremental: exactly 1 call, with a `search` kwarg.
            self.assertEqual(len(fetched.call_args_list), 1)
            call = fetched.call_args_list[0]
            self.assertIn("search", call.kwargs)
            self.assertTrue(call.kwargs["search"].startswith("updated:>="))

    def test_force_full_overrides_incremental(self) -> None:
        with TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "cache.json"
            changelog = Path(tmp) / "log.jsonl"
            now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
            seed = {
                "repo": "x/y",
                "fetched_at": now_iso,
                "last_synced_at": now_iso,
                "issues": {"1": _issue(1).to_dict()},
            }
            tracker.save_cache(seed, cache_path)
            with mock.patch.object(tracker, "fetch_issues", return_value=[]) as fetched, \
                 mock.patch.object(tracker, "_populate_closed_by_parallel"):
                tracker.scan(
                    repo="x/y",
                    cache_path=cache_path,
                    changelog_path=changelog,
                    force_full=True,
                )
            self.assertEqual(len(fetched.call_args_list), 2)


if __name__ == "__main__":
    unittest.main()
