"""Status dashboard generator.

Renders ISSUE_STATUS.md from the cache produced by `tracker.py`.
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from . import config
from .tracker import Issue, load_cache


# ---------------------------------------------------------------------------
# Helpers
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


def _days_since(ts: str | None, now: datetime) -> int | None:
    parsed = _parse_iso(ts)
    if parsed is None:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return (now - parsed).days


def _urgency_marker(days: int | None) -> str:
    if days is None:
        return ""
    if days >= config.STALE_THRESHOLD_DAYS:
        return "🚨"
    if days >= config.WARNING_THRESHOLD_DAYS:
        return "⚠️"
    return ""


def _escape_md(text: str) -> str:
    """Escape characters that would break a markdown table cell."""
    return text.replace("|", "\\|").replace("\n", " ").strip()


def _format_labels(labels: Iterable[str]) -> str:
    items = [f"`{lbl}`" for lbl in labels if lbl]
    return ", ".join(items) if items else "—"


def _format_assignees(assignees: Iterable[str]) -> str:
    items = [f"@{a}" for a in assignees if a]
    return ", ".join(items) if items else "—"


def _format_short_date(ts: str | None) -> str:
    parsed = _parse_iso(ts)
    if parsed is None:
        return "—"
    return parsed.strftime("%Y-%m-%d")


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

def compute_stats(
    open_issues: list[Issue],
    closed_issues: list[Issue],
    now: datetime | None = None,
    rolling_total_seconds: float | None = None,
    rolling_count: int | None = None,
) -> dict[str, float | int]:
    """Compute summary stats over the cached issues.

    Staleness is measured by `updated_at` (last activity) rather than
    `created_at`, so a still-discussed issue isn't flagged as stale.

    If `rolling_total_seconds` and `rolling_count` are provided, avg
    time-to-close is computed from that persistent counter; otherwise it
    falls back to the in-window closed issues.
    """
    now = now or datetime.now(timezone.utc)
    stale = 0
    for issue in open_issues:
        # Prefer updated_at; fall back to created_at if missing.
        days = _days_since(issue.updated_at or issue.created_at, now)
        if days is not None and days >= config.STALE_THRESHOLD_DAYS:
            stale += 1

    if rolling_count and rolling_total_seconds is not None and rolling_count > 0:
        avg_close_days = (rolling_total_seconds / rolling_count) / 86400
    else:
        durations: list[float] = []
        for issue in closed_issues:
            created = _parse_iso(issue.created_at)
            closed = _parse_iso(issue.closed_at)
            if created and closed:
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                if closed.tzinfo is None:
                    closed = closed.replace(tzinfo=timezone.utc)
                durations.append((closed - created).total_seconds() / 86400)
        avg_close_days = sum(durations) / len(durations) if durations else 0.0

    # Also expose oldest-by-creation, since "age by creation" is still useful.
    oldest_age = 0
    for issue in open_issues:
        days = _days_since(issue.created_at, now)
        if days is not None and days > oldest_age:
            oldest_age = days

    return {
        "open_count": len(open_issues),
        "closed_count": len(closed_issues),
        "total": len(open_issues) + len(closed_issues),
        "avg_close_days": round(avg_close_days, 2),
        "stale_count": stale,
        "oldest_open_age_days": oldest_age,
    }


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------

def render_open_table(open_issues: list[Issue], now: datetime) -> str:
    if not open_issues:
        return "_No open issues — inbox zero._\n"

    sorted_issues = sorted(
        open_issues,
        key=lambda i: _parse_iso(i.created_at) or datetime.min.replace(tzinfo=timezone.utc),
    )

    lines = [
        "| # | Title | Labels | Assignees | Milestone | 💬 | Created | Updated | Age (created) | Stale (updated) |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for issue in sorted_issues:
        age_days = _days_since(issue.created_at, now)
        stale_days = _days_since(issue.updated_at or issue.created_at, now)
        marker = _urgency_marker(stale_days)
        age_text = f"{age_days}d" if age_days is not None else "—"
        stale_text = f"{marker} {stale_days}d".strip() if stale_days is not None else "—"
        title = _escape_md(issue.title)
        title_cell = f"[{title}]({issue.url})" if issue.url else title
        lines.append(
            f"| #{issue.number} "
            f"| {title_cell} "
            f"| {_format_labels(issue.labels)} "
            f"| {_format_assignees(issue.assignees)} "
            f"| {issue.milestone or '—'} "
            f"| {issue.comments} "
            f"| {_format_short_date(issue.created_at)} "
            f"| {_format_short_date(issue.updated_at)} "
            f"| {age_text} "
            f"| {stale_text} |"
        )
    return "\n".join(lines) + "\n"


def render_closed_table(closed_issues: list[Issue]) -> str:
    if not closed_issues:
        return "_No recently-closed issues._\n"

    sorted_issues = sorted(
        closed_issues,
        key=lambda i: _parse_iso(i.closed_at) or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )[: config.RECENT_CLOSED_LIMIT]

    lines = [
        "| # | Title | Closed by | Closed |",
        "|---|---|---|---|",
    ]
    for issue in sorted_issues:
        title = _escape_md(issue.title)
        title_cell = f"[{title}]({issue.url})" if issue.url else title
        lines.append(
            f"| #{issue.number} "
            f"| {title_cell} "
            f"| {issue.closed_by or '—'} "
            f"| {_format_short_date(issue.closed_at)} |"
        )
    return "\n".join(lines) + "\n"


def render_stats(stats: dict[str, float | int]) -> str:
    return (
        f"- 🔴 Open: **{stats['open_count']}**\n"
        f"- 🟢 Closed (recent window): **{stats['closed_count']}**\n"
        f"- Σ Tracked total: **{stats['total']}**\n"
        f"- ⏱️ Avg time to close (rolling): **{stats['avg_close_days']} days**\n"
        f"- 🚨 Stale open by last activity (>{config.STALE_THRESHOLD_DAYS}d): **{stats['stale_count']}**\n"
        f"- 📅 Oldest open by creation: **{stats['oldest_open_age_days']}d**\n"
    )


def render_dashboard(
    repo: str,
    open_issues: list[Issue],
    closed_issues: list[Issue],
    fetched_at: str | None = None,
    now: datetime | None = None,
    rolling_total_seconds: float | None = None,
    rolling_count: int | None = None,
) -> str:
    """Render the full ISSUE_STATUS.md content as a string."""
    now = now or datetime.now(timezone.utc)
    stats = compute_stats(
        open_issues,
        closed_issues,
        now=now,
        rolling_total_seconds=rolling_total_seconds,
        rolling_count=rolling_count,
    )
    fetched_display = fetched_at or now.isoformat(timespec="seconds")

    parts = [
        "# 📡 Issue Pulse — Status Dashboard\n",
        f"**Repository:** [`{repo}`](https://github.com/{repo})  \n",
        f"**Last update:** `{fetched_display}`  \n",
        f"**Generated:** `{now.isoformat(timespec='seconds')}`\n",
        "\n---\n",
        "\n## 🔴 Open Issues\n\n",
        render_open_table(open_issues, now),
        "\n## 🟢 Recently Closed\n\n",
        render_closed_table(closed_issues),
        "\n## 📈 Stats\n\n",
        render_stats(stats),
        "\n---\n\n",
        "_Legend: ⚠️ no activity >7 days · 🚨 no activity >30 days_\n",
    ]
    return "".join(parts)


def write_dashboard(
    output_path: Path = config.OUTPUT_PATH,
    cache_path: Path = config.CACHE_PATH,
    repo: str | None = None,
) -> Path:
    """Read the cache and write the rendered dashboard to disk."""
    cache: dict[str, Any] = load_cache(cache_path)
    repo_name = repo or cache.get("repo") or config.DEFAULT_REPO

    open_issues: list[Issue] = []
    closed_issues: list[Issue] = []
    for raw in (cache.get("issues") or {}).values():
        try:
            issue = Issue.from_dict(raw)
        except (KeyError, TypeError, ValueError):
            continue
        if issue.state == "OPEN":
            open_issues.append(issue)
        else:
            closed_issues.append(issue)

    rolling_total = float(cache.get("close_time_total_seconds") or 0.0)
    rolling_count = int(cache.get("close_time_count") or 0)

    content = render_dashboard(
        repo=repo_name,
        open_issues=open_issues,
        closed_issues=closed_issues,
        fetched_at=cache.get("fetched_at"),
        rolling_total_seconds=rolling_total,
        rolling_count=rolling_count,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")
    return output_path
