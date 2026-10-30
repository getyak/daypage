#!/usr/bin/env python3
"""Allow publication only after the latest exact-main-commit CI succeeds."""
import json
import os
import re
import subprocess
import sys
import time


class GateError(Exception):
    pass


def fetch_runs(repo, sha, timeout, workflow="ci.yml"):
    endpoint = (f"repos/{repo}/actions/workflows/{workflow}/runs?branch=main"
                f"&event=push&head_sha={sha}&per_page=1")
    try:
        result = subprocess.run(["gh", "api", endpoint], capture_output=True,
                                text=True, stdin=subprocess.DEVNULL, timeout=timeout)
        if result.returncode != 0:
            raise GateError("CI API request failed")
        return json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        raise GateError("CI API response unavailable or malformed") from None


def validate_packet(payload, repo, sha, workflow="ci.yml"):
    if not isinstance(payload, dict):
        raise GateError("invalid CI response")
    total, runs = payload.get("total_count"), payload.get("workflow_runs")
    if (type(total) is not int or total < 0 or not isinstance(runs, list)
            or len(runs) > 1 or total < len(runs) or (total == 0) != (len(runs) == 0)):
        raise GateError("incomplete CI response")
    if not runs:
        return None
    run = runs[0]  # GitHub returns newest run; never search older successes.
    if not isinstance(run, dict):
        raise GateError("invalid CI run")
    for field, value in [("head_sha", sha), ("head_branch", "main"), ("event", "push"),
                         ("path", f".github/workflows/{workflow}")]:
        if run.get(field) != value:
            raise GateError("CI run does not match the release candidate")
    for field in ["repository", "head_repository"]:
        if not isinstance(run.get(field), dict) or run[field].get("full_name") != repo:
            raise GateError("CI repository does not match the release candidate")
    for field in ["id", "run_attempt"]:
        if type(run.get(field)) is not int or run[field] < 1:
            raise GateError("invalid CI run identity")
    return run


def wait_for_ci(repo, sha, ref, *, fetch=fetch_runs, clock=time.monotonic,
                sleep=time.sleep, timeout=3600, interval=30, workflow="ci.yml"):
    if (workflow not in {"ci.yml", "ios-local.yml"} or ref != "refs/heads/main" or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*", repo)
            or not re.fullmatch(r"[0-9a-f]{40}", sha)):
        raise GateError("publication requires an exact main commit")
    deadline = clock() + timeout
    last_state = None
    while True:
        remaining = deadline - clock()
        if remaining <= 0:
            raise GateError("timed out waiting for candidate CI")
        run = validate_packet(fetch(repo, sha, min(30, remaining)), repo, sha, workflow)
        if clock() >= deadline:
            raise GateError("timed out waiting for candidate CI")
        state = (run["id"], run["run_attempt"], run.get("status")) if run else None
        if state != last_state:
            print(f"[release-ci] {workflow} candidate CI state: {state}", flush=True)
            last_state = state
        if run:
            status = run.get("status")
            if status == "completed":
                if run.get("conclusion") != "success":
                    raise GateError("latest candidate CI did not succeed")
                print(f"[release-ci] verified https://github.com/{repo}/actions/runs/{run['id']}")
                return run["id"]
            if status not in {"queued", "in_progress", "waiting", "requested", "pending"}:
                raise GateError("candidate CI has an unsupported state")
            if run.get("conclusion") is not None:
                raise GateError("inconsistent candidate CI status")
        sleep(min(interval, max(0, deadline - clock())))


def main():
    try:
        deadline = time.monotonic() + 3600
        for workflow in ("ci.yml", "ios-local.yml"):
            wait_for_ci(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_SHA", ""),
                        os.environ.get("GITHUB_REF", ""), workflow=workflow,
                        timeout=max(0, deadline - time.monotonic()),
                        fetch=lambda repo, sha, timeout: fetch_runs(repo, sha, timeout, workflow))
        # A previously green workflow may have been rerun while the other one
        # was building. Do not carry that old success across a long wait.
        repo, sha = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_SHA", "")
        for workflow in ("ci.yml", "ios-local.yml"):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise GateError("timed out confirming candidate CI")
            run = validate_packet(fetch_runs(repo, sha, min(30, remaining), workflow), repo, sha, workflow)
            if (time.monotonic() >= deadline or not run or run.get("status") != "completed"
                    or run.get("conclusion") != "success"):
                raise GateError("candidate CI changed while waiting; retry after both workflows succeed")
    except GateError as error:
        print(f"[release-ci] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
