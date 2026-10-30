#!/usr/bin/env python3
"""The real release gate, with synthetic GitHub and clock boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/wait_for_release_ci.py"
SHA = "a" * 40
REPO = "example/daypage"


def packet(status="completed", conclusion="success", **changes):
    run = {"id": 10, "run_attempt": 1, "head_sha": SHA, "head_branch": "main",
           "event": "push", "path": ".github/workflows/ci.yml", "status": status,
           "conclusion": conclusion, "repository": {"full_name": REPO},
           "head_repository": {"full_name": REPO}}
    run.update(changes)
    return {"total_count": 1, "workflow_runs": [run]}


class ReleaseCIGateTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("release_ci_gate", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.now = 0
        self.calls = []

    def run_gate(self, packets, **kwargs):
        replies = iter(packets)
        def fetch(repo, sha, timeout):
            self.calls.append((repo, sha, timeout))
            reply = next(replies)
            if isinstance(reply, Exception):
                raise reply
            return reply
        def sleep(seconds):
            self.now += seconds
        return self.module.wait_for_ci(REPO, SHA, "refs/heads/main", fetch=fetch,
            clock=lambda: self.now, sleep=sleep, timeout=60, interval=10, **kwargs)

    def test_same_sha_success(self):
        self.assertEqual(self.run_gate([packet()]), 10)
        self.assertEqual(self.calls, [(REPO, SHA, 30)])

    def test_local_gate_requires_its_own_workflow_identity(self):
        self.assertEqual(self.run_gate([packet(path=".github/workflows/ios-local.yml")],
                                       workflow="ios-local.yml"), 10)
        with self.assertRaises(self.module.GateError):
            self.run_gate([packet()], workflow="ios-local.yml")

    def test_both_gates_share_one_hour_budget(self):
        with mock.patch.object(self.module.time, "monotonic", side_effect=[10, 20, 30]), \
             mock.patch.object(self.module, "wait_for_ci") as wait:
            self.assertEqual(self.module.main(), 0)
        self.assertEqual([call.kwargs.get("timeout") for call in wait.call_args_list], [3590, 3580])

    def test_discovery_then_latest_rerun_running_then_success(self):
        self.assertEqual(self.run_gate([
            {"total_count": 0, "workflow_runs": []},
            packet("queued", None, run_attempt=2),
            packet("in_progress", None, run_attempt=2), packet(run_attempt=2)]), 10)
        self.assertEqual(self.now, 30)

    def test_latest_failure_is_never_replaced_with_older_success(self):
        for conclusion in ["failure", "cancelled", "timed_out", "skipped", "neutral", "startup_failure"]:
            with self.subTest(conclusion=conclusion):
                latest = packet(conclusion=conclusion)
                latest["total_count"] = 2  # API requests only the newest run.
                with self.assertRaises(self.module.GateError):
                    self.run_gate([latest, packet()])

    def test_wrong_sha_branch_workflow_repo_or_event_refuses(self):
        for changes in [{"head_sha": "b" * 40}, {"head_branch": "feature"},
                        {"event": "pull_request"}, {"path": ".github/workflows/other.yml"},
                        {"repository": {"full_name": "other/repo"}},
                        {"head_repository": {"full_name": "fork/daypage"}}, {"run_attempt": 0}]:
            with self.subTest(changed=next(iter(changes))):
                with self.assertRaises(self.module.GateError):
                    self.run_gate([packet(**changes)])

    def test_malformed_api_payload_and_request_failure_refuse(self):
        for reply in [{}, {"total_count": 1, "workflow_runs": []},
                      {"total_count": 1, "workflow_runs": "bad"},
                      {"total_count": 2, "workflow_runs": [packet()["workflow_runs"][0]] * 2},
                      self.module.GateError("API refused")]:
            with self.subTest(shape=type(reply).__name__):
                with self.assertRaises(self.module.GateError):
                    self.run_gate([reply])

    def test_discovery_and_waiting_are_bounded(self):
        for reply in [{"total_count": 0, "workflow_runs": []}, packet("waiting", None)]:
            with self.assertRaises(self.module.GateError):
                self.run_gate([reply] * 10)
            self.assertLessEqual(self.now, 60)
            self.now = 0

    def test_manual_non_main_ref_fails_before_api(self):
        fetch = mock.Mock()
        with self.assertRaises(self.module.GateError):
            self.module.wait_for_ci(REPO, SHA, "refs/heads/feature", fetch=fetch)
        fetch.assert_not_called()

    def test_late_api_success_cannot_escape_total_deadline(self):
        def late_fetch(*args):
            self.now = 61
            return packet()
        with self.assertRaises(self.module.GateError):
            self.module.wait_for_ci(REPO, SHA, "refs/heads/main", fetch=late_fetch,
                                    clock=lambda: self.now, timeout=60)

    def test_cli_uses_environment_and_real_fetch_without_exposing_token(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "packet.json"
            fixture.write_text(json.dumps(packet()))
            marker = root / "called"
            gh = root / "gh"
            gh.write_text('#!' + sys.executable + '\n'
                'import os,pathlib,sys\n'
                'assert sys.argv[1] == "api"\n'
                'with pathlib.Path(os.environ["FAKE_MARKER"]).open("a") as f: f.write(sys.argv[2]+"\\n")\n'
                'import json\n'
                'p=json.loads(pathlib.Path(os.environ["FAKE_PACKET"]).read_text())\n'
                'if "/workflows/ios-local.yml/" in sys.argv[2]:\n'
                ' p["workflow_runs"][0]["path"]=".github/workflows/ios-local.yml"\n'
                ' p["workflow_runs"][0]["conclusion"]=os.environ.get("FAKE_LOCAL_CONCLUSION","success")\n'
                'sys.stdout.write(json.dumps(p))\n')
            gh.chmod(0o700)
            env = {"PATH": str(root) + os.pathsep + os.environ.get("PATH", ""),
                   "GITHUB_REPOSITORY": REPO, "GITHUB_SHA": SHA,
                   "GITHUB_REF": "refs/heads/main", "GH_TOKEN": "private-token-sentinel",
                   "FAKE_PACKET": str(fixture), "FAKE_MARKER": str(marker)}
            for conclusion, expected in [("success", 0), ("failure", 1)]:
                fixture.write_text(json.dumps(packet(conclusion=conclusion)))
                result = subprocess.run([sys.executable, str(SCRIPT)], env=env,
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, expected)
                self.assertTrue(marker.exists())
                self.assertNotIn(b"private-token-sentinel", result.stdout + result.stderr)
            fixture.write_text(json.dumps(packet()))
            env["FAKE_LOCAL_CONCLUSION"] = "failure"
            result = subprocess.run([sys.executable, str(SCRIPT)], env=env,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1, "general CI success cannot bypass failed local-iOS CI")
            self.assertIn("/workflows/ios-local.yml/", marker.read_text())
            marker.unlink()
            env["GITHUB_REF"] = "refs/heads/feature"
            result = subprocess.run([sys.executable, str(SCRIPT)], env=env,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(marker.exists())

    def test_real_fetch_uses_fixed_workflow_query_and_bounded_subprocess(self):
        result = subprocess.CompletedProcess([], 0, json.dumps(packet()), "")
        with mock.patch.object(self.module.subprocess, "run", return_value=result) as run:
            self.assertEqual(self.module.fetch_runs(REPO, SHA, 12), packet())
        argv = run.call_args.args[0]
        self.assertEqual(argv[0:2], ["gh", "api"])
        self.assertIn("/actions/workflows/ci.yml/runs?", argv[2])
        for query in ["branch=main", "event=push", "head_sha=" + SHA, "per_page=1"]:
            self.assertIn(query, argv[2])
        self.assertEqual(run.call_args.kwargs["timeout"], 12)
        for fake in [subprocess.CompletedProcess([], 1, "", "private-sentinel"),
                     subprocess.CompletedProcess([], 0, "bad-json-private-sentinel", "")]:
            with mock.patch.object(self.module.subprocess, "run", return_value=fake):
                with self.assertRaises(self.module.GateError) as raised:
                    self.module.fetch_runs(REPO, SHA, 12)
                self.assertNotIn("private-sentinel", str(raised.exception))
        for error in [OSError("private-sentinel"),
                      subprocess.TimeoutExpired(["private-sentinel"], 12)]:
            with mock.patch.object(self.module.subprocess, "run", side_effect=error):
                with self.assertRaises(self.module.GateError) as raised:
                    self.module.fetch_runs(REPO, SHA, 12)
                self.assertNotIn("private-sentinel", str(raised.exception))

    def test_workflow_deploy_requires_candidate_gate(self):
        source = (ROOT / ".github/workflows/testflight.yml").read_text()
        self.assertIn("  candidate-ci:", source)
        deploy = source.split("  deploy:", 1)[1]
        self.assertIn("needs: candidate-ci", deploy)
        self.assertIn("python3 scripts/ci/wait_for_release_ci.py", source)


if __name__ == "__main__":
    unittest.main()
