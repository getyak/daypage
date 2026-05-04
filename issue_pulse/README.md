# 📡 Issue Pulse

A small Python tool that tracks the state of GitHub issues for a repository,
caches snapshots locally, detects state transitions between scans, and renders
a clean Markdown dashboard.

Default target repo: **`getyak/daypage`**.

## Requirements

- Python 3.10+
- [`gh` CLI](https://cli.github.com/) authenticated against GitHub
  (`gh auth status` should report a logged-in account)

No third-party Python packages are needed — only the standard library.

## Layout

```
issue_pulse/
  __init__.py
  config.py          # default repo, paths, thresholds (env-overridable)
  tracker.py         # gh CLI calls, cache I/O, diff detection, incremental sync
  display.py         # ISSUE_STATUS.md rendering
  cli.py             # scan / status / watch / diff
  pyproject.toml     # `pip install .` → `issue-pulse` entry point
  README.md
  tests/
    test_tracker.py  # tracker + display unit tests (gh mocked)
    test_cli.py      # CLI tests (tracker.scan mocked)
```

Generated artefacts live alongside the package (override paths via env vars):

- `.issue_cache.json`      — last fetched snapshot (atomic JSON write)
- `issue_changelog.log`    — append-only JSONL log of every state change
- `ISSUE_STATUS.md`        — the human-readable dashboard

## Install

Install as a CLI from the package dir:

```bash
pip install ./issue_pulse
issue-pulse scan
```

Or run directly from the repo root without installing:

```bash
python3 -m issue_pulse.cli scan
```

## Usage

```bash
# Query GitHub, refresh the cache, and regenerate ISSUE_STATUS.md
issue-pulse scan

# Force a full sync (bypass incremental delta)
issue-pulse scan --full

# Print the current dashboard to stdout
issue-pulse status

# Show the most recent state changes from the changelog
issue-pulse diff --limit 30

# Poll on an interval (default 300s) — auto-backs off on errors
issue-pulse watch --interval 600

# Override the default repo
issue-pulse --repo someone/other-repo scan
```

## Sync strategy

- **First run** — full sync: fetches all OPEN issues plus the most recent
  N CLOSED issues (`RECENT_CLOSED_LIMIT`).
- **Subsequent runs** — incremental: queries only issues with
  `updated:>=<last_synced_at - 5m>` and overlays them on the cached
  snapshot. Falls back to full sync if the cache is older than
  `INCREMENTAL_MAX_AGE_DAYS` (7 by default) or if `--full` is passed.

## What it tracks

For each issue: `number`, `title`, `state`, `labels`, `assignees`,
`milestone`, `comments`, `created_at`, `updated_at`, `closed_at`,
`closed_by`, `url`.

`closed_by` is resolved from the GitHub REST timeline endpoint
(`repos/{owner}/{repo}/issues/{n}/timeline`) — `gh issue view --json closedBy`
does **not** exist. Lookups for newly-closed issues run in parallel
(`ThreadPoolExecutor`, default 5 workers).

State transitions detected and written to the changelog:

| Kind               | Trigger                                                                       |
| ------------------ | ----------------------------------------------------------------------------- |
| `opened`           | issue appeared in this scan and is OPEN                                       |
| `closed`           | issue was OPEN previously and CLOSED was observed via API                     |
| `reopened`         | issue was CLOSED previously, OPEN now                                         |
| `labels_changed`   | label set differs (with added/removed list)                                   |
| `unknown_dropped`  | issue dropped out of the open window without a confirmed CLOSED observation   |

`unknown_dropped` exists so the tool never fabricates a "closed" event
just because an issue scrolled past the fetch window.

## Dashboard

`ISSUE_STATUS.md` includes:

- header with repo, fetch timestamp, generation timestamp
- 🔴 **Open Issues** — table sorted by age, with assignees, milestone,
  comment count, ⚠️ for >7 days no activity and 🚨 for >30 days
  no activity (staleness is by `updated_at`, not `created_at`)
- 🟢 **Recently Closed** — most recent N closed issues with `closed_by`
- 📈 **Stats** — open/closed counts, total, avg time to close (rolling),
  stale count, oldest open issue by creation

Average time-to-close is computed from a **persistent rolling counter**
stored in `.issue_cache.json` (`close_time_total_seconds`,
`close_time_count`), not just the visible 25-issue window — so the metric
remains meaningful across many scans.

## Testing

```bash
python3 -m pytest issue_pulse/tests/ -v
# or:
python3 -m unittest discover -s issue_pulse/tests -v
```

The suite covers cache round-trip, change detection, display formatting,
incremental sync, rolling stats, and `gh` CLI invocation — all with
network calls mocked.

## Configuration

Tweak `issue_pulse/config.py` or set environment variables:

| Setting                       | Env var          | Default                       |
| ----------------------------- | ---------------- | ----------------------------- |
| `DEFAULT_REPO`                | `IP_REPO`        | `getyak/daypage`              |
| `CACHE_PATH`                  | `IP_CACHE_PATH`  | `<repo>/.issue_cache.json`    |
| `CHANGELOG_PATH`              | `IP_CHANGELOG`   | `<repo>/issue_changelog.log`  |
| `OUTPUT_PATH`                 | `IP_OUTPUT`      | `<repo>/ISSUE_STATUS.md`      |
| `REFRESH_INTERVAL_SECONDS`    | —                | `300`                         |
| `WARNING_THRESHOLD_DAYS`      | —                | `7`                           |
| `STALE_THRESHOLD_DAYS`        | —                | `30`                          |
| `RECENT_CLOSED_LIMIT`         | —                | `25`                          |
| `ISSUE_FETCH_LIMIT`           | —                | `500` (see below)             |
| `CLOSED_BY_MAX_WORKERS`       | —                | `5`                           |
| `INCREMENTAL_MAX_AGE_DAYS`    | —                | `7`                           |

### Note on the 500-issue fetch cap

`ISSUE_FETCH_LIMIT = 500` is a hard ceiling on how many issues we ask
`gh issue list` to return per request. For most repos this is far more
than needed; for very large repos with thousands of open issues, lift
this cap in `config.py`. The incremental sync path mitigates this in
day-to-day use because each delta query only fetches issues touched
since the last scan.

## Error handling

- `gh` failures (auth, rate limit, network) raise a `RuntimeError` and
  are surfaced as a non-zero exit from `issue-pulse scan`.
- `issue-pulse watch` keeps running on errors and uses **exponential
  backoff** (`interval × 2^(consecutive_errors-1)`, capped at
  `max(interval × 8, 600)` seconds).
- Missing or corrupt cache files are treated as "first run" — the next
  scan rebuilds the cache.
- Cache writes are atomic (`tempfile` + `os.replace`) so an interrupted
  scan cannot leave a half-written file.
- URLs returned by `gh` are validated against the
  `https://github.com/` prefix; anything else is dropped.
