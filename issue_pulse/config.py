"""Configuration constants for Issue Pulse.

Env-var overrides (read at import time):
    IP_REPO                — default repository (OWNER/NAME)
    IP_CACHE_PATH          — path to the JSON cache file
    IP_CHANGELOG           — path to the JSONL changelog
    IP_OUTPUT              — path to the rendered dashboard
    IP_STALE_DAYS          — staleness threshold (days) for 🚨 marker
    IP_WARNING_DAYS        — warning threshold (days) for ⚠️ marker
    IP_CLOSED_LIMIT        — recent closed issues to fetch/display
    IP_INCREMENTAL_MAX_AGE — max cache age (days) before forcing full sync
"""
from __future__ import annotations

import os
from pathlib import Path


def _int_from_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


DEFAULT_REPO: str = os.environ.get("IP_REPO", "getyak/daypage")
REFRESH_INTERVAL_SECONDS: int = 300
STALE_THRESHOLD_DAYS: int = _int_from_env("IP_STALE_DAYS", 30)
WARNING_THRESHOLD_DAYS: int = _int_from_env("IP_WARNING_DAYS", 7)

# Paths are anchored to this package directory so the tool works from any cwd.
PACKAGE_DIR: Path = Path(__file__).resolve().parent
ROOT_DIR: Path = PACKAGE_DIR.parent


def _path_from_env(name: str, default: Path) -> Path:
    raw = os.environ.get(name)
    return Path(raw).expanduser() if raw else default


CACHE_PATH: Path = _path_from_env("IP_CACHE_PATH", ROOT_DIR / ".issue_cache.json")
CHANGELOG_PATH: Path = _path_from_env("IP_CHANGELOG", ROOT_DIR / "issue_changelog.log")
OUTPUT_PATH: Path = _path_from_env("IP_OUTPUT", ROOT_DIR / "ISSUE_STATUS.md")

# How many recently-closed issues to fetch and display.
RECENT_CLOSED_LIMIT: int = _int_from_env("IP_CLOSED_LIMIT", 25)
# Hard cap on how many issues to request from the GitHub API per state.
# This is a deliberate ceiling to keep scans bounded; very large repos may
# need to lift it. See README for details.
ISSUE_FETCH_LIMIT: int = 500

# Concurrency for per-issue lookups (closed_by) on newly-closed issues.
CLOSED_BY_MAX_WORKERS: int = 5

# Incremental-sync window: if cache.last_synced_at is older than this many
# days, fall back to a full scan rather than relying on a delta query.
INCREMENTAL_MAX_AGE_DAYS: int = _int_from_env("IP_INCREMENTAL_MAX_AGE", 7)

# Prune closed issues older than this from the persisted cache to bound size.
CLOSED_CACHE_RETENTION_DAYS: int = 90

# Cap on the rolling-counter "counted" set persisted to disk.
COUNTED_CLOSED_CAP: int = 1000
