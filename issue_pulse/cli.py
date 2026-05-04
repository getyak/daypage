"""Command-line interface for Issue Pulse.

Subcommands:
    scan    — query GitHub, update cache, regenerate ISSUE_STATUS.md
    status  — print the current dashboard to the terminal
    watch   — repeatedly scan on an interval
    diff    — show changes since the last scan (from the changelog)
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from . import config
from .display import write_dashboard
from .tracker import scan


_KIND_MARKERS: dict[str, str] = {
    "opened": "✨",
    "reopened": "🔁",
    "closed": "✅",
    "labels_changed": "🏷️ ",
    "unknown_dropped": "❓",
}


def _print_summary(repo: str, scan_result: tuple) -> None:
    open_issues, closed_issues, changes = scan_result
    print(f"[issue-pulse] repo={repo}")
    print(f"  open    : {len(open_issues)}")
    print(f"  closed  : {len(closed_issues)} (recent window)")
    print(f"  changes : {len(changes)}")
    for change in changes:
        marker = _KIND_MARKERS.get(change.kind, "•")
        title = change.title[:60]
        print(f"    {marker} #{change.number} {change.kind:<16} {title}")


def cmd_scan(args: argparse.Namespace) -> int:
    try:
        result = scan(repo=args.repo, force_full=getattr(args, "full", False))
    except RuntimeError as exc:
        print(f"[issue-pulse] scan failed: {exc}", file=sys.stderr)
        return 2
    _print_summary(args.repo, result)
    out_path = write_dashboard(repo=args.repo)
    print(f"[issue-pulse] wrote {out_path}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    path: Path = config.OUTPUT_PATH
    if not path.exists():
        print(
            "[issue-pulse] no dashboard yet — run `python -m issue_pulse.cli scan` first",
            file=sys.stderr,
        )
        return 1
    sys.stdout.write(path.read_text(encoding="utf-8"))
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    interval = max(10, int(args.interval))
    print(f"[issue-pulse] watching {args.repo} every {interval}s — Ctrl+C to stop")
    consecutive_errors = 0
    max_backoff = max(interval * 8, 600)
    try:
        while True:
            try:
                result = scan(repo=args.repo)
                _print_summary(args.repo, result)
                write_dashboard(repo=args.repo)
                consecutive_errors = 0
                sleep_for = interval
            except RuntimeError as exc:
                consecutive_errors += 1
                # Exponential backoff: interval * 2^(n-1), capped.
                sleep_for = min(interval * (2 ** (consecutive_errors - 1)), max_backoff)
                print(
                    f"[issue-pulse] scan failed (#{consecutive_errors}, backing off {sleep_for}s): {exc}",
                    file=sys.stderr,
                )
            time.sleep(sleep_for)
    except KeyboardInterrupt:
        print("\n[issue-pulse] stopped")
        return 0


def cmd_diff(args: argparse.Namespace) -> int:
    path: Path = config.CHANGELOG_PATH
    if not path.exists():
        print("[issue-pulse] no changelog yet — run a scan first")
        return 0
    lines = path.read_text(encoding="utf-8").splitlines()
    tail = lines[-args.limit:] if args.limit > 0 else lines
    if not tail:
        print("[issue-pulse] changelog is empty")
        return 0
    for raw in tail:
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        ts = entry.get("timestamp", "")
        kind = entry.get("kind", "?")
        number = entry.get("number", "?")
        title = entry.get("title", "")
        detail = entry.get("detail", "")
        print(f"{ts}  {kind:<16} #{number}  {title}  ({detail})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="issue-pulse",
        description="Track GitHub issue status for a repository.",
    )
    parser.add_argument(
        "--repo",
        default=config.DEFAULT_REPO,
        help=f"Repo in OWNER/NAME form (default: {config.DEFAULT_REPO})",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    scan_p = sub.add_parser("scan", help="Query GitHub, update cache, regenerate dashboard")
    scan_p.add_argument(
        "--full",
        action="store_true",
        help="Force a full sync instead of incremental delta",
    )
    sub.add_parser("status", help="Print the current dashboard markdown")

    watch = sub.add_parser("watch", help="Poll repeatedly")
    watch.add_argument(
        "--interval",
        type=int,
        default=config.REFRESH_INTERVAL_SECONDS,
        help=f"Seconds between polls (default: {config.REFRESH_INTERVAL_SECONDS})",
    )

    diff = sub.add_parser("diff", help="Show recent changes from the changelog")
    diff.add_argument(
        "--limit", type=int, default=20, help="How many recent entries to show",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "scan":
        return cmd_scan(args)
    if args.command == "status":
        return cmd_status(args)
    if args.command == "watch":
        return cmd_watch(args)
    if args.command == "diff":
        return cmd_diff(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
