"""Exercise the native CI shell's failure propagation with isolated command doubles.

This is host-side orchestration evidence only. No Xcode, Simulator, audio,
network listener, signing key or real native acceptance is used.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
UNSIGNED_BYTES = b"unsigned mock executable"
SIGNED_BYTES = b"signed mock executable"

TOOL_DOUBLE = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, re, sys

tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ["NATIVE_CI_MOCK_MODE"]
state = pathlib.Path(os.environ["NATIVE_CI_MOCK_STATE"])

def event(name):
    with (state / "events").open("a") as file:
        file.write(name + "\n")

def option(name):
    return args[args.index(name) + 1]

negative_failed = mode in {"negative_failure", "both_failure"}
signed_failed = mode in {"signed_failure", "both_failure"}
if tool == "git":
    assert args == ["rev-parse", "HEAD"]
    print("a" * 40)
elif tool == "xcodebuild":
    if args == ["-version"]:
        print("Xcode 26.5\nBuild version MOCK")
    elif args[0] == "build-for-testing":
        signed = "CODE_SIGNING_ALLOWED=YES" in args
        event("signed-build" if signed else "unsigned-build")
        derived = pathlib.Path(option("-derivedDataPath"))
        app = derived / "Build/Products/Debug-iphonesimulator/DayPage.app"
        app.mkdir(parents=True, exist_ok=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.daypage.app.localqa",
            "DayPageCaptureAppGroup": "group.com.daypage.app.localqa.capture",
        }))
        share = app / "PlugIns/DayPageLocalShare.appex"
        share.mkdir(parents=True, exist_ok=True)
        (share / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.daypage.app.localqa.sharecapture",
            "DayPageCaptureAppGroup": "group.com.daypage.app.localqa.capture",
        }))
        if signed or mode != "missing_unsigned_binary":
            (app / "DayPage").write_bytes(
                b"signed mock executable" if signed else b"unsigned mock executable")
        folder = derived / "Build/Intermediates.noindex/DayPageLocal.build/Debug-iphonesimulator/DayPage.build"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "mock.xcent").write_bytes(plistlib.dumps({
            "application-identifier": "MOCK.com.daypage.app.localqa",
            "keychain-access-groups": ["MOCK.com.daypage.app.localqa"],
            "com.apple.security.application-groups": [
                "group.com.daypage.app.capture" if mode == "production_capture_group"
                else "group.foreign.capture" if mode == "foreign_capture_group"
                else "group.com.daypage.app.localqa.capture"
            ],
        }))
        share_folder = folder.with_name("DayPageLocalShare.build")
        share_folder.mkdir(parents=True, exist_ok=True)
        (share_folder / "mock.xcent").write_bytes(plistlib.dumps({
            "application-identifier": "MOCK.com.daypage.app.localqa.sharecapture",
            "com.apple.security.application-groups": [
                "group.foreign.capture" if mode == "foreign_share_capture_group"
                else "group.com.daypage.app.localqa.capture"
            ],
        }))
    elif args[0] == "test-without-building":
        signed = "CODE_SIGNING_ALLOWED=YES" in args
        event("signed-tests" if signed else "negative-tests")
        pathlib.Path(option("-resultBundlePath")).mkdir()
        selected = [arg.split(":", 1)[1] for arg in args if arg.startswith("-only-testing:")]
        identifiers = []
        for path in sorted(pathlib.Path("DayPageLocalUITests").glob("*.swift")):
            for method in re.findall(r"^[ \t]+func (test\w+)\(", path.read_text(), re.M):
                item = "DayPageLocalUITests/" + path.stem + "/" + method
                if not selected or any(item == key or item.startswith(key + "/") for key in selected):
                    identifiers.append(item)
        if mode == "shard_extra":
            identifiers.append("DayPageLocalUITests/UnknownUITests/testUnselected")
        (state / ("signed-ids.json" if signed else "negative-ids.json")).write_text(json.dumps(identifiers))
        for index, item in enumerate(identifiers):
            _, suite, method = item.split("/")
            name = "-[DayPageLocalUITests." + suite + " " + method + "]"
            print("Test Case '" + name + "' started.")
            failed = (signed_failed if signed else negative_failed) and index == 0
            print("Test Case '" + name + "' " + ("failed" if failed else "passed") + " (0.100 seconds).")
        if signed and signed_failed:
            raise SystemExit(66)
        if not signed and negative_failed:
            raise SystemExit(65)
    else:
        raise AssertionError(args)
elif tool == "xcrun":
    if args == ["--sdk", "iphonesimulator", "--show-sdk-version"]:
        print("26.5")
    elif args[:4] == ["simctl", "list", "devices", "available"]:
        print(json.dumps({"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [{
                "name": "iPhone 17e", "udid": "00000000-0000-4000-8000-000000000001",
                "state": "Shutdown", "isAvailable": True,
            }]
        }}))
    elif args[:2] == ["simctl", "bootstatus"]:
        event("mock-boot")
        if mode == "boot_failure":
            raise SystemExit(70)
    elif args[:4] == ["xcresulttool", "get", "test-results", "summary"]:
        negative = "negative-keychain" in option("--path")
        failed = negative_failed if negative else signed_failed
        total = len(json.loads((state / ("negative-ids.json" if negative else "signed-ids.json")).read_text()))
        print(json.dumps({
            "result": "Failed" if failed else "Passed",
            "failedTests": int(failed), "skippedTests": 0,
            "passedTests": total - int(failed), "totalTestCount": total,
        }))
    elif args[:3] == ["xcresulttool", "export", "attachments"]:
        negative = "negative-keychain" in option("--path")
        event("negative-export" if negative else "signed-export")
        if negative and mode == "negative_export_failure":
            raise SystemExit(74)
        output = pathlib.Path(option("--output-path"))
        output.mkdir()
        if negative:
            names = ["ai-key-unavailable-inline"]
            if mode != "missing_negative_attachment":
                names.append("speech-anonymous-no-keychain")
        else:
            names = ["chat-dedicated-model-page", "chat-compact-composer",
                     "chat-saved-history", "chat-character-library",
                     "chat-streamed-markdown", "chat-accessibility-size",
                     "diary-home-today", "diary-earlier-days", "diary-sidebar-en",
                     "diary-sidebar-zh-normal", "diary-sidebar-zh-dark-large-text",
                     "diary-month-position", "diary-rediscovered-note"]
        (output / "manifest.json").write_text(json.dumps([{
            "attachments": [{"suggestedHumanReadableName": name} for name in names]
        }]))
    else:
        raise AssertionError(args)
elif tool == "lsof":
    path = state / "fixture.pid"
    if not path.exists():
        raise SystemExit(1)
    owner = path.read_text().strip()
    observed = "99999999" if mode in {"foreign_listener", "foreign_response"} else owner
    calls_path = state / "health-calls"
    calls = int(calls_path.read_text()) if calls_path.exists() else 0
    if mode == "listener_after_health" and calls == 0:
        raise SystemExit(1)
    if mode == "foreign_handoff_failed_health" and calls == 0:
        observed = "99999999"
    if "-t" in args:
        if mode == "terse_missing":
            raise SystemExit(1)
        print(observed)
    elif "-Fp" in args:
        if mode == "empty_fields":
            raise SystemExit(0)
        print("p" + observed + "\nf3")
        if mode == "multiple_fields":
            print("p99999999\nf4")
        elif mode == "invalid_fields":
            print("pnot-a-pid")
        elif mode == "invalid_fd_fields":
            print("fnot-a-descriptor")
        elif mode == "empty_fd_fields":
            print("f")
        elif mode == "error_fields":
            raise SystemExit(74)
    else:
        print("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME")
        print("Python " + observed + " runner 3u IPv4 0x0 0t0 TCP 127.0.0.1:18763 (LISTEN)")
elif tool == "curl":
    calls_path = state / "health-calls"
    calls = int(calls_path.read_text()) + 1 if calls_path.exists() else 1
    calls_path.write_text(str(calls))
    body = b"GET-326-local-fixture"
    if mode == "foreign_response":
        body = b"UNTRUSTED_BODY_SENTINEL"
    elif mode == "wrong_health":
        body = b"wrong-health-marker"
    elif mode == "newline_health":
        body += b"\n"
    elif mode == "nul_health":
        body += b"\0"
    status = "302" if mode == "redirect_health" else "200"
    if "--output" in args:
        foreign = mode == "foreign_response"
        pathlib.Path(option("--output")).write_bytes(body)
        if "--dump-header" in args:
            pathlib.Path(option("--dump-header")).write_text(
                "HTTP/1.1 200 OK\nSet-Cookie: UNTRUSTED_HEADER_SENTINEL\n")
        if foreign:
            print("UNTRUSTED_ERROR_SENTINEL", file=sys.stderr)
        print(status, end="")
    else:
        sys.stdout.buffer.write(body)
    if mode == "failed_health" or (mode == "foreign_handoff_failed_health" and calls > 1):
        raise SystemExit(28)
elif tool == "sleep":
    import time
    fast = {"foreign_listener", "foreign_response", "terse_missing", "empty_fields",
            "multiple_fields", "invalid_fields", "invalid_fd_fields", "empty_fd_fields", "error_fields",
            "listener_after_health", "foreign_handoff_failed_health", "wrong_health", "failed_health",
            "redirect_health", "newline_health", "nul_health"}
    time.sleep(0.005 if mode in fast else float(args[0]))
elif tool == "codesign":
    event("mock-signature-check")
elif tool == "otool":
    print("sectname __entitlements")
else:
    raise AssertionError(tool)
'''


class NativeCIOrchestrationTests(unittest.TestCase):
    def run_fixture(self, mode, *, runner_arch="ARM64", runner_environment="github-hosted",
                    suite="card_tools_speech", shard=None, wrong_plan=False, wrong_arch_plan=False):
        temporary = tempfile.TemporaryDirectory(prefix="native-ci-command-doubles-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        qa = root / "scripts/qa"
        qa.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/qa/run_local_native_ci.sh", qa)
        ci = root / "scripts/ci"
        ci.mkdir()
        shutil.copy2(ROOT / "scripts/ci/select_simulator.py", ci)
        sources = root / "DayPageLocalUITests"
        sources.mkdir()
        for name in (path.name for path in (ROOT / "DayPageLocalUITests").glob("*.swift")):
            shutil.copy2(ROOT / "DayPageLocalUITests" / name, sources)
        if shard:
            shutil.copy2(ROOT / "scripts/qa/native_ui_matrix.py", qa)
            project = Path("DayPageLocal/DayPageLocal.xcodeproj")
            shutil.copytree(ROOT / project, root / project)
            spec = importlib.util.spec_from_file_location("native_matrix_double", ROOT / "scripts/qa/native_ui_matrix.py")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            # The production shell records the real Python host architecture,
            # independently of the simulated RUNNER_ARCH boot-budget input.
            profiles = {"arm64": "arm64", "x86_64": "intel"}
            host_arch = platform.machine()
            self.assertIn(host_arch, profiles, "Unsupported host architecture for native CI command doubles")
            profile = profiles[host_arch]
            if wrong_arch_plan:
                profile = "intel" if profile == "arm64" else "arm64"
            plan = module.make_plan(root, "c" * 40 if wrong_plan else "a" * 40, "12345", "1", profile)
            (root / "plan.json").write_text(json.dumps(plan))
        state = root / "state"
        state.mkdir()
        # A task-owned, inert process satisfies the shell's PID ownership check.
        # Its cleanup trap terminates and waits for it; no TCP socket is opened.
        (qa / "local_notebook_ai_fixture.py").write_text(
            "import os, pathlib, signal\n"
            "pathlib.Path(os.environ['NATIVE_CI_MOCK_STATE'], 'fixture.pid').write_text(str(os.getpid()))\n"
            "signal.pause()\n"
        )
        binaries = root / "bin"
        binaries.mkdir()
        double = binaries / "command-double"
        double.write_text(TOOL_DOUBLE)
        double.chmod(0o700)
        for tool in ("git", "xcodebuild", "xcrun", "lsof", "curl", "sleep", "codesign", "otool"):
            (binaries / tool).symlink_to(double.name)
        runner = root / "runner"
        runner.mkdir()
        evidence = runner / "evidence"
        environment = {
            **os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_RUN_ID": "host-mock",
            "RUNNER_ARCH": runner_arch, "RUNNER_ENVIRONMENT": runner_environment,
            "RUNNER_TEMP": str(runner), "DAYPAGE_NATIVE_CI_OUTPUT_DIR": str(evidence),
            "DAYPAGE_NATIVE_UI_SUITE": "full" if shard else suite,
            "NATIVE_CI_MOCK_MODE": mode, "NATIVE_CI_MOCK_STATE": str(state),
        }
        if shard:
            environment.update({"GITHUB_RUN_ID": "12345", "GITHUB_RUN_ATTEMPT": "1", "ImageVersion": "host-mock",
                                "DAYPAGE_NATIVE_UI_SHARD": shard, "DAYPAGE_NATIVE_UI_PLAN": str(root / "plan.json")})
        process = subprocess.Popen(
            ["bash", str(qa / "run_local_native_ci.sh")], cwd=root, env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            # Rejection cases intentionally execute all 30 probe rounds, each
            # launching several Python command doubles. Cold hosted Intel
            # interpreters exceeded 30 seconds without an orchestration hang.
            # This budget affects only the command-double test, not native
            # readiness, ownership checks, boot budgets or test assertions.
            output, _ = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            # Only this test's newly created process group is terminated.
            os.killpg(process.pid, signal.SIGTERM)
            output, _ = process.communicate(timeout=5)
            probes = evidence / "fixture-listener-probes.log"
            diagnostics = probes.read_text()[-2000:] if probes.exists() else "No mock probe record"
            self.fail("Host orchestration fixture timed out:\n" + output[-2000:] + "\nMock probes:\n" + diagnostics)
        events_path = state / "events"
        events = events_path.read_text().splitlines() if events_path.exists() else []
        return process.returncode, output, evidence, events

    def test_only_hosted_intel_gets_the_fixed_cold_boot_budget(self):
        for arch, environment, budget in (("X64", "github-hosted", 360),
                                          ("ARM64", "github-hosted", 180),
                                          ("X64", "self-hosted", 180)):
            with self.subTest(arch=arch, environment=environment):
                code, output, evidence, events = self.run_fixture(
                    "success", runner_arch=arch, runner_environment=environment)
                self.assertEqual(code, 0, output)
                self.assert_signed_evidence(evidence, events)
                path = evidence / "simulator-boot-receipt.json"
                self.assertTrue(path.exists(), "A boot attempt must record its fixed budget and actual outcome")
                receipt = json.loads(path.read_text())
                self.assertEqual(receipt["timeoutSeconds"], budget)
                self.assertEqual(receipt["runnerArchitecture"], arch)
                self.assertEqual(receipt["runnerEnvironment"], environment)
                self.assertTrue(receipt["ready"])
                self.assertEqual(receipt["outcome"], "success")

    def test_failed_boot_still_blocks_every_xctest_and_acceptance(self):
        code, output, evidence, events = self.run_fixture("boot_failure", runner_arch="X64")
        self.assertNotEqual(code, 0, output)
        self.assertIn("unsigned-build", events)
        self.assertIn("mock-boot", events)
        self.assertNotIn("negative-tests", events)
        self.assertNotIn("signed-build", events)
        self.assertFalse((evidence / "native-acceptance.json").exists())
        receipt = json.loads((evidence / "simulator-boot-receipt.json").read_text())
        self.assertFalse(receipt["ready"])
        self.assertEqual(receipt["outcome"], "failed")
        self.assertEqual(receipt["exitCode"], 70)

    def test_foreign_listener_keeps_readiness_failure_and_collects_both_boundary_diagnostics(self):
        code, output, evidence, events = self.run_fixture("foreign_listener")
        self.assertEqual(code, 1, output)
        self.assertEqual(events, [])
        self.assertFalse((evidence / "native-acceptance.json").exists())
        self.assertFalse((evidence / "negative-build.log").exists())
        diagnostics = evidence / "fixture-readiness.log"
        self.assertTrue(diagnostics.exists(), "A readiness failure must preserve ownership and HTTP evidence")
        text = diagnostics.read_text()
        self.assertIn("fixture_pid=", text)
        self.assertIn("last_listener=99999999", text)
        self.assertIn("listener_exit=0", text)
        self.assertIn("health_exit=0", text)
        self.assertIn("99999999", (evidence / "fixture-listeners.log").read_text())
        health = json.loads((evidence / "fixture-health.log").read_text())
        self.assertEqual(health["httpCode"], "200")
        self.assertTrue(health["expectedMarkerMatches"])

    def test_unknown_listener_http_content_never_enters_uploaded_evidence(self):
        code, output, evidence, events = self.run_fixture("foreign_response")
        self.assertEqual(code, 1, output)
        self.assertEqual(events, [])
        for path in evidence.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"UNTRUSTED_", path.read_bytes(), path.name)
        self.assertNotIn("UNTRUSTED_", output)
        self.assertFalse((evidence / "fixture-health-body.log").exists())
        self.assertFalse((evidence / "fixture-health-headers.log").exists())
        health = json.loads((evidence / "fixture-health.log").read_text())
        self.assertEqual(health["httpCode"], "200")
        self.assertFalse(health["expectedMarkerMatches"])
        self.assertLessEqual(health["bodyBytesRead"], 1025)

    def test_machine_fields_verify_the_owned_listener_when_terse_output_is_empty(self):
        code, output, evidence, events = self.run_fixture("terse_missing")
        self.assertEqual(code, 0, output)
        self.assert_signed_evidence(evidence, events)
        self.assertTrue(json.loads((evidence / "native-acceptance.json").read_text())["passed"])
        self.assertIn("terse_exit=1", (evidence / "fixture-listener-probes.log").read_text())

    def test_missing_ambiguous_malformed_and_failed_owner_records_cannot_authorize_tests(self):
        for mode in ("empty_fields", "multiple_fields", "invalid_fields", "invalid_fd_fields", "empty_fd_fields", "error_fields"):
            with self.subTest(mode=mode):
                code, output, evidence, events = self.run_fixture(mode)
                self.assertEqual(code, 1, output)
                self.assertEqual(events, [])
                self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_listener_first_visible_after_get_requires_a_new_stable_round(self):
        code, output, evidence, events = self.run_fixture("listener_after_health")
        self.assertEqual(code, 0, output)
        self.assert_signed_evidence(evidence, events)
        probes = (evidence / "fixture-listener-probes.log").read_text()
        self.assertIn("attempt=1 phase=before-health fields_exit=1", probes)
        self.assertIn("attempt=1 phase=after-health fields_exit=0", probes)
        self.assertIn("accepted_attempt=2", probes)

    def test_foreign_handoff_and_unhealthy_owned_responses_cannot_authorize_tests(self):
        for mode in ("foreign_handoff_failed_health", "wrong_health", "failed_health",
                     "redirect_health", "newline_health", "nul_health"):
            with self.subTest(mode=mode):
                code, output, evidence, events = self.run_fixture(mode)
                self.assertEqual(code, 1, output)
                self.assertEqual(events, [])
                self.assertFalse((evidence / "native-acceptance.json").exists())

    def assert_signed_evidence(self, evidence, events):
        self.assertIn("signed-tests", events)
        self.assertTrue((evidence / "signed-summary.log").exists())
        self.assertTrue((evidence / "signed-attachments/manifest.json").exists())

    def test_success_requires_both_stages_and_preserves_unsigned_hash_before_overwrite(self):
        code, output, evidence, events = self.run_fixture("success")
        self.assertEqual(code, 0, output)
        self.assert_signed_evidence(evidence, events)
        receipt = json.loads((evidence / "native-acceptance.json").read_text())
        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["positive"]["passedTests"], 16)
        self.assertTrue(receipt["negative"]["verified"])
        recorded = (evidence / "negative-executable.sha256").read_text().split()[0]
        self.assertEqual(recorded, hashlib.sha256(UNSIGNED_BYTES).hexdigest())
        executables = list(evidence.parent.glob("daypage-native-ci.*/NegativeDerivedData/Build/Products/Debug-iphonesimulator/DayPage.app/DayPage"))
        self.assertEqual(len(executables), 1)
        self.assertEqual(executables[0].read_bytes(), SIGNED_BYTES)
        self.assertLess(events.index("negative-tests"), events.index("signed-build"))

    def test_production_and_foreign_capture_groups_cannot_authorize_native_tests(self):
        for mode in ("production_capture_group", "foreign_capture_group", "foreign_share_capture_group"):
            with self.subTest(mode=mode):
                code, output, evidence, events = self.run_fixture(mode)
                self.assertNotEqual(code, 0, output)
                self.assertIn("Unexpected production or foreign capture App Group", output)
                self.assertNotIn("signed-tests", events)
                self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_unsigned_command_failure_collects_signed_results_and_keeps_original_failure(self):
        code, output, evidence, events = self.run_fixture("negative_failure")
        self.assertEqual(code, 65, output)
        self.assert_signed_evidence(evidence, events)
        self.assertFalse((evidence / "negative-receipt.json").exists())
        self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_missing_unsigned_attachment_runs_actual_validator_and_still_collects_signed(self):
        code, output, evidence, events = self.run_fixture("missing_negative_attachment")
        self.assertNotEqual(code, 0, output)
        self.assert_signed_evidence(evidence, events)
        self.assertIn("AssertionError", (evidence / "negative-receipt.log").read_text())
        self.assertFalse((evidence / "negative-receipt.json").exists())
        self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_unsigned_export_failure_never_creates_verified_receipt_or_acceptance(self):
        code, output, evidence, events = self.run_fixture("negative_export_failure")
        self.assertEqual(code, 74, output)
        self.assert_signed_evidence(evidence, events)
        self.assertFalse((evidence / "negative-receipt.json").exists())
        self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_both_failed_stages_are_collected_and_unsigned_failure_has_priority(self):
        code, output, evidence, events = self.run_fixture("both_failure")
        self.assertEqual(code, 65, output)
        self.assert_signed_evidence(evidence, events)
        self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_signed_failure_keeps_unsigned_receipt_but_denies_acceptance(self):
        code, output, evidence, events = self.run_fixture("signed_failure")
        self.assertEqual(code, 66, output)
        self.assert_signed_evidence(evidence, events)
        self.assertTrue(json.loads((evidence / "negative-receipt.json").read_text())["verified"])
        self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_missing_unsigned_binary_stops_before_it_can_be_overwritten(self):
        code, output, evidence, events = self.run_fixture("missing_unsigned_binary")
        self.assertNotEqual(code, 0, output)
        self.assertIn("unsigned-build", events)
        self.assertNotIn("signed-build", events)
        self.assertFalse((evidence / "native-acceptance.json").exists())

    def test_original_full_and_diary_preset_still_run_their_complete_selected_scope(self):
        for suite, count, negative in (("full", 78, True), ("diary_navigation", 51, False)):
            with self.subTest(suite=suite):
                code, output, evidence, events = self.run_fixture("success", suite=suite)
                self.assertEqual(code, 0, output)
                receipt = json.loads((evidence / "native-acceptance.json").read_text())
                self.assertEqual(receipt["positive"]["passedTests"], count)
                self.assertEqual("negative-tests" in events, negative)

    def test_signed_shard_cold_builds_only_signed_and_runs_exact_methods(self):
        code, output, evidence, events = self.run_fixture("success", shard="speech")
        self.assertEqual(code, 0, output + (evidence / "shard-receipt.log").read_text())
        self.assertEqual([event for event in events if event.endswith("-build")], ["signed-build"])
        self.assertNotIn("negative-tests", events)
        receipt = json.loads((evidence / "shard-receipt.json").read_text())
        self.assertTrue(receipt["passed"])
        self.assertEqual(len(receipt["observed"]["passed"]), 4)
        self.assertIn("DayPageLocalUITests/CardToolsSpeechUITests/testAnonymousSpeechWorksWithoutKeychain", receipt["observed"]["passed"])

    def test_unsigned_shard_never_signs_and_proves_both_negative_branches(self):
        code, output, evidence, events = self.run_fixture("success", shard="unsigned")
        self.assertEqual(code, 0, output + (evidence / "shard-receipt.log").read_text())
        self.assertNotIn("signed-build", events)
        self.assertNotIn("signed-tests", events)
        self.assertNotIn("mock-signature-check", events)
        receipt = json.loads((evidence / "shard-receipt.json").read_text())
        self.assertTrue(receipt["passed"])
        self.assertEqual(len(receipt["observed"]["passed"]), 2)
        self.assertFalse((evidence / "signed-summary.log").exists())

    def test_wrong_host_architecture_still_denies_a_complete_shard(self):
        code, output, evidence, events = self.run_fixture("success", shard="speech", wrong_arch_plan=True)
        self.assertNotEqual(code, 0, output)
        self.assertIn("signed-tests", events)
        receipt = json.loads((evidence / "shard-receipt.json").read_text())
        self.assertFalse(receipt["passed"])
        self.assertEqual(len(receipt["observed"]["passed"]), 4)
        self.assertEqual(receipt["summary"]["passedTests"], 4)
        self.assertIn("wrong runner architecture", receipt["errors"])

    def test_shard_wrong_source_denies_before_fixture_build_or_simulator(self):
        code, output, evidence, events = self.run_fixture("success", shard="speech", wrong_plan=True)
        self.assertNotEqual(code, 0, output)
        self.assertEqual(events, [])
        self.assertFalse(json.loads((evidence / "shard-receipt.json").read_text())["passed"])

    def test_zero_xcode_exit_with_unselected_case_is_still_denied(self):
        code, output, evidence, events = self.run_fixture("shard_extra", shard="speech")
        self.assertNotEqual(code, 0, output)
        receipt = json.loads((evidence / "shard-receipt.json").read_text())
        self.assertFalse(receipt["passed"])
        self.assertIn("DayPageLocalUITests/UnknownUITests/testUnselected", receipt["observed"]["passed"])

    def test_failed_unsigned_shard_keeps_real_exit_and_failed_case_observation(self):
        code, output, evidence, events = self.run_fixture("negative_failure", shard="unsigned")
        self.assertEqual(code, 65, output)
        self.assertNotIn("signed-build", events)
        receipt = json.loads((evidence / "shard-receipt.json").read_text())
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["exitCode"], 65)
        self.assertEqual(len(receipt["observed"]["failed"]), 1)


if __name__ == "__main__":
    unittest.main()
