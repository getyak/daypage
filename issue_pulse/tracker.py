"""Issue tracking engine.

Queries GitHub via the `gh` CLI, caches results to a JSON file, and
detects state transitions (open <-> closed, label changes) by diffing
against the previous cache.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

from . import config


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Issue:
    """A snapshot of a single GitHub issue."""

    number: int
    title: str
    state: str  # "OPEN" or "CLOSED"
    labels: list[str] = field(default_factory=list)
    created_at: str = ""
    updated_at: str = ""
    closed_at: str | None = None
    closed_by: str | None = None
    url: str = ""
    assignees: list[str] = field(default_factory=list)
    milestone: str | None = None
    comments: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "number": self.number,
            "title": self.title,
            "state": self.state,
            "labels": list(self.labels),
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "closed_at": self.closed_at,
            "closed_by": self.closed_by,
            "url": self.url,
            "assignees": list(self.assignees),
            "milestone": self.milestone,
            "comments": self.comments,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Issue":
        return cls(
            number=int(data["number"]),
            title=str(data.get("title", "")),
            state=str(data.get("state", "OPEN")).upper(),
            labels=list(data.get("labels", [])),
            created_at=str(data.get("created_at", "")),
            updated_at=str(data.get("updated_at", "")),
            closed_at=data.get("closed_at"),
            closed_by=data.get("closed_by"),
            url=str(data.get("url", "")),
            assignees=list(data.get("assignees", [])),
            milestone=data.get("milestone"),
            comments=int(data.get("comments", 0) or 0),
        )


@dataclass
class StateChange:
    """A single state transition between two cache snapshots."""

    number: int
    title: str
    # "opened" | "closed" | "reopened" | "labels_changed" | "unknown_dropped"
    kind: str
    detail: str = ""
    timestamp: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "number": self.number,
            "title": self.title,
            "kind": self.kind,
            "detail": self.detail,
            "timestamp": self.timestamp,
        }


# ---------------------------------------------------------------------------
# gh CLI calls
# ---------------------------------------------------------------------------

_ISSUE_FIELDS = (
    "number,title,state,labels,createdAt,updatedAt,closedAt,url,"
    "assignees,milestone,comments"
)


def _run_gh(args: list[str]) -> str:
    """Run a `gh` command and return stdout. Raises RuntimeError on failure."""
    # Paginated API calls (timeline, etc.) can be much slower than a single
    # `gh issue list`, so give them a longer budget.
    timeout = 120 if "--paginate" in args else 60
    try:
        result = subprocess.run(
            ["gh", *args],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("gh CLI not found on PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"gh command timed out: {' '.join(args)}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        raise RuntimeError(f"gh command failed ({exc.returncode}): {stderr}") from exc
    return result.stdout


def _normalize(raw: dict[str, Any]) -> Issue:
    """Convert a raw `gh issue list --json` record to our Issue model."""
    labels = [lbl.get("name", "") for lbl in raw.get("labels") or [] if lbl.get("name")]
    assignees = [
        a.get("login", "")
        for a in raw.get("assignees") or []
        if a.get("login")
    ]
    milestone_raw = raw.get("milestone")
    milestone = None
    if isinstance(milestone_raw, dict):
        milestone = milestone_raw.get("title") or None
    comments_raw = raw.get("comments")
    if isinstance(comments_raw, list):
        comments_count = len(comments_raw)
    elif isinstance(comments_raw, int):
        comments_count = comments_raw
    else:
        comments_count = 0
    url = str(raw.get("url", ""))
    if url and not url.startswith("https://github.com/"):
        # Defensive: drop anything that isn't a real GitHub URL.
        url = ""
    return Issue(
        number=int(raw["number"]),
        title=str(raw.get("title", "")),
        state=str(raw.get("state", "OPEN")).upper(),
        labels=labels,
        created_at=str(raw.get("createdAt", "")),
        updated_at=str(raw.get("updatedAt", "")),
        closed_at=raw.get("closedAt") or None,
        closed_by=None,  # filled in lazily for newly-closed issues
        url=url,
        assignees=assignees,
        milestone=milestone,
        comments=comments_count,
    )


def fetch_issues(
    repo: str,
    state: str,
    limit: int = config.ISSUE_FETCH_LIMIT,
    search: str | None = None,
) -> list[Issue]:
    """Fetch issues from GitHub for the given repo + state ("open"|"closed"|"all").

    If `search` is provided, it's passed to `gh issue list --search` and
    typically restricts results to a time window (e.g. "updated:>=2026-04-01").
    """
    args = [
        "issue", "list",
        "--repo", repo,
        "--state", state,
        "--limit", str(limit),
        "--json", _ISSUE_FIELDS,
    ]
    if search:
        args.extend(["--search", search])
    out = _run_gh(args)
    try:
        records = json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Could not parse gh JSON output: {exc}") from exc
    return [_normalize(r) for r in records]


def fetch_closed_by(repo: str, number: int) -> str | None:
    """Look up who closed an issue. Returns None on error or if not closed.

    Uses the GitHub REST timeline endpoint via `gh api` because
    `gh issue view --json closedByPullRequestsReferences,timelineItems`
    is not actually a supported field set.
    """
    try:
        out = _run_gh([
            "api",
            f"repos/{repo}/issues/{number}/timeline",
            "--paginate",
        ])
    except RuntimeError:
        return None
    try:
        items = json.loads(out)
    except json.JSONDecodeError:
        return None
    if not isinstance(items, list):
        return None

    pr_author: str | None = None
    last_closer: str | None = None

    for item in items:
        if not isinstance(item, dict):
            continue
        event = item.get("event")
        if event == "closed":
            actor = item.get("actor") or {}
            login = actor.get("login")
            if login:
                last_closer = str(login)
        elif event == "cross-referenced":
            source = item.get("source") or {}
            issue_obj = source.get("issue") or {}
            if issue_obj.get("pull_request"):
                user = issue_obj.get("user") or {}
                login = user.get("login")
                if login and pr_author is None:
                    pr_author = str(login)

    if last_closer:
        return last_closer
    if pr_author:
        return f"PR by {pr_author}"
    return None


def _populate_closed_by_parallel(
    repo: str,
    issues: list[Issue],
    max_workers: int = config.CLOSED_BY_MAX_WORKERS,
) -> None:
    """Fill in `closed_by` for the given issues, in parallel."""
    if not issues:
        return
    workers = max(1, min(max_workers, len(issues)))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(fetch_closed_by, repo, issue.number): issue
            for issue in issues
        }
        for fut in as_completed(futures):
            issue = futures[fut]
            try:
                issue.closed_by = fut.result()
            except Exception:
                issue.closed_by = None


# ---------------------------------------------------------------------------
# Cache I/O
# ---------------------------------------------------------------------------

_CACHE_SKELETON: dict[str, Any] = {
    "repo": None,
    "fetched_at": None,
    "last_synced_at": None,
    "issues": {},
    # Persistent rolling counter for avg-time-to-close.
    "close_time_total_seconds": 0.0,
    "close_time_count": 0,
    # Numbers we've already counted in the rolling avg, to avoid double-counting.
    "counted_closed_numbers": [],
}


def _skeleton() -> dict[str, Any]:
    data = dict(_CACHE_SKELETON)
    data["issues"] = {}
    data["counted_closed_numbers"] = []
    return data


def load_cache(path: Path = config.CACHE_PATH) -> dict[str, Any]:
    """Load the JSON cache file. Returns an empty skeleton on missing/invalid."""
    if not path.exists():
        return _skeleton()
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return _skeleton()
    if not isinstance(data, dict):
        return _skeleton()
    for key, value in _CACHE_SKELETON.items():
        if key not in data:
            data[key] = value if not isinstance(value, (dict, list)) else type(value)()
    return data


def save_cache(data: dict[str, Any], path: Path = config.CACHE_PATH) -> None:
    """Atomically persist the cache to disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".issue_cache.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Diffing
# ---------------------------------------------------------------------------

def diff_issues(
    previous: dict[int, Issue],
    current: dict[int, Issue],
    *,
    confirmed_closed: set[int] | None = None,
) -> list[StateChange]:
    """Compare two {number: Issue} maps and return state changes.

    `confirmed_closed` lists issue numbers that we positively know are closed
    (because the API just returned state=CLOSED for them). Issues that simply
    drop out of the fetch window are emitted as `unknown_dropped`, not
    `closed`, to avoid false-positive closure events.
    """
    confirmed_closed = confirmed_closed or set()
    changes: list[StateChange] = []
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")

    for number, issue in current.items():
        prev = previous.get(number)
        if prev is None:
            kind = "opened" if issue.state == "OPEN" else "closed"
            changes.append(StateChange(
                number=issue.number,
                title=issue.title,
                kind=kind,
                detail=f"state={issue.state}",
                timestamp=now,
            ))
            continue

        if prev.state != issue.state:
            if issue.state == "CLOSED":
                kind = "closed"
                detail = f"closed_by={issue.closed_by or 'unknown'}"
            else:
                kind = "reopened"
                detail = "reopened"
            changes.append(StateChange(
                number=issue.number,
                title=issue.title,
                kind=kind,
                detail=detail,
                timestamp=now,
            ))
            continue

        if set(prev.labels) != set(issue.labels):
            added = sorted(set(issue.labels) - set(prev.labels))
            removed = sorted(set(prev.labels) - set(issue.labels))
            parts: list[str] = []
            if added:
                parts.append(f"+{','.join(added)}")
            if removed:
                parts.append(f"-{','.join(removed)}")
            changes.append(StateChange(
                number=issue.number,
                title=issue.title,
                kind="labels_changed",
                detail=" ".join(parts),
                timestamp=now,
            ))

    for number, issue in previous.items():
        if number in current:
            continue
        if issue.state != "OPEN":
            # Already closed in the prev snapshot; dropping out is expected.
            continue
        if number in confirmed_closed:
            changes.append(StateChange(
                number=issue.number,
                title=issue.title,
                kind="closed",
                detail="confirmed via API",
                timestamp=now,
            ))
        else:
            # Don't claim it's closed — we genuinely don't know.
            changes.append(StateChange(
                number=issue.number,
                title=issue.title,
                kind="unknown_dropped",
                detail="dropped from open window without observed close",
                timestamp=now,
            ))
    return changes


def append_changelog(
    changes: Iterable[StateChange],
    path: Path = config.CHANGELOG_PATH,
) -> None:
    """Append change records as one JSON object per line."""
    changes = list(changes)
    if not changes:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        for change in changes:
            fh.write(json.dumps(change.to_dict(), ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# Rolling avg-time-to-close
# ---------------------------------------------------------------------------

def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        return datetime.fromisoformat(ts)
    except ValueError:
        return None


def _update_close_time_counter(
    cache: dict[str, Any],
    closed_issues: list[Issue],
) -> None:
    """Add any newly-observed closed issues to the persistent rolling counter."""
    counted = set(cache.get("counted_closed_numbers") or [])
    total_seconds = float(cache.get("close_time_total_seconds") or 0.0)
    count = int(cache.get("close_time_count") or 0)
    for issue in closed_issues:
        if issue.number in counted:
            continue
        created = _parse_iso(issue.created_at)
        closed = _parse_iso(issue.closed_at)
        if not created or not closed:
            continue
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        if closed.tzinfo is None:
            closed = closed.replace(tzinfo=timezone.utc)
        seconds = (closed - created).total_seconds()
        if seconds < 0:
            continue
        total_seconds += seconds
        count += 1
        counted.add(issue.number)
    cache["close_time_total_seconds"] = total_seconds
    cache["close_time_count"] = count
    # Cap the persisted "counted" set to the last N entries (highest issue
    # numbers ≈ most recent). The sum and count remain accurate; only the
    # dedupe set is bounded so the JSON file doesn't grow unboundedly.
    counted_sorted = sorted(counted)
    if len(counted_sorted) > config.COUNTED_CLOSED_CAP:
        counted_sorted = counted_sorted[-config.COUNTED_CLOSED_CAP:]
    cache["counted_closed_numbers"] = counted_sorted


def _prune_closed_issues(
    current_map: dict[int, "Issue"],
    retention_days: int = config.CLOSED_CACHE_RETENTION_DAYS,
) -> dict[int, "Issue"]:
    """Drop closed issues older than `retention_days` to bound cache size."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
    pruned: dict[int, Issue] = {}
    for number, issue in current_map.items():
        if issue.state == "CLOSED":
            closed = _parse_iso(issue.closed_at)
            if closed is not None:
                if closed.tzinfo is None:
                    closed = closed.replace(tzinfo=timezone.utc)
                if closed < cutoff:
                    continue
        pruned[number] = issue
    return pruned


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def _should_use_incremental(cache: dict[str, Any]) -> bool:
    last_synced = _parse_iso(cache.get("last_synced_at"))
    if last_synced is None:
        return False
    if last_synced.tzinfo is None:
        last_synced = last_synced.replace(tzinfo=timezone.utc)
    age = datetime.now(timezone.utc) - last_synced
    if age > timedelta(days=config.INCREMENTAL_MAX_AGE_DAYS):
        return False
    if not cache.get("issues"):
        return False
    return True


def scan(
    repo: str = config.DEFAULT_REPO,
    cache_path: Path = config.CACHE_PATH,
    changelog_path: Path = config.CHANGELOG_PATH,
    *,
    force_full: bool = False,
) -> tuple[list[Issue], list[Issue], list[StateChange]]:
    """Fetch issues, diff, persist, and return results.

    Strategy:
      - First run (or stale cache): full sync of open + recent closed.
      - Subsequent runs: delta query for issues updated since `last_synced_at`,
        merged on top of the previous snapshot.

    Returns:
        (open_issues, closed_issues, state_changes)
    """
    cache = load_cache(cache_path)
    previous_map: dict[int, Issue] = {}
    for num_str, raw in (cache.get("issues") or {}).items():
        try:
            previous_map[int(num_str)] = Issue.from_dict(raw)
        except (ValueError, KeyError, TypeError):
            continue

    use_incremental = (not force_full) and _should_use_incremental(cache)

    if use_incremental:
        last_synced = _parse_iso(cache.get("last_synced_at"))
        assert last_synced is not None
        # Subtract a small overlap to avoid missing edits at the boundary.
        delta_since = (last_synced - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        delta = fetch_issues(
            repo,
            state="all",
            search=f"updated:>={delta_since}",
        )
        # Start from the previous snapshot, overlay deltas.
        current_map: dict[int, Issue] = {n: i for n, i in previous_map.items()}
        for issue in delta:
            current_map[issue.number] = issue
        # Closed-window for display: use what we have in cache + delta.
        closed_issues = [i for i in current_map.values() if i.state == "CLOSED"]
        open_issues = [i for i in current_map.values() if i.state == "OPEN"]
    else:
        open_issues = fetch_issues(repo, state="open")
        closed_issues = fetch_issues(repo, state="closed", limit=config.RECENT_CLOSED_LIMIT)
        current_map = {i.number: i for i in open_issues}
        for issue in closed_issues:
            current_map[issue.number] = issue

    # Identify newly-closed issues (state transitioned to CLOSED since prev).
    newly_closed: list[Issue] = []
    for issue in current_map.values():
        if issue.state != "CLOSED":
            continue
        prev = previous_map.get(issue.number)
        if prev is None or prev.state != "CLOSED" or not prev.closed_by:
            newly_closed.append(issue)
        else:
            issue.closed_by = prev.closed_by

    _populate_closed_by_parallel(repo, newly_closed)

    confirmed_closed = {i.number for i in current_map.values() if i.state == "CLOSED"}
    changes = diff_issues(previous_map, current_map, confirmed_closed=confirmed_closed)

    # Update persistent rolling counter for avg time-to-close.
    _update_close_time_counter(cache, [i for i in current_map.values() if i.state == "CLOSED"])

    now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
    persisted_map = _prune_closed_issues(current_map)
    cache_payload = {
        "repo": repo,
        "fetched_at": now_iso,
        "last_synced_at": now_iso,
        "issues": {str(num): iss.to_dict() for num, iss in persisted_map.items()},
        "close_time_total_seconds": cache.get("close_time_total_seconds", 0.0),
        "close_time_count": cache.get("close_time_count", 0),
        "counted_closed_numbers": cache.get("counted_closed_numbers", []),
    }
    save_cache(cache_payload, cache_path)
    append_changelog(changes, changelog_path)

    # Re-derive the returned lists from the merged map so callers see all
    # tracked open issues, not just what came back in this delta.
    open_issues = [i for i in current_map.values() if i.state == "OPEN"]
    closed_issues_out = [i for i in current_map.values() if i.state == "CLOSED"]
    closed_issues_out.sort(
        key=lambda i: _parse_iso(i.closed_at) or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )
    return open_issues, closed_issues_out[: config.RECENT_CLOSED_LIMIT], changes
