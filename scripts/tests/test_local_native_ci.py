"""Exercise the native CI shell's failure propagation with isolated command doubles.

This is host-side orchestration evidence only. No Xcode, Simulator, audio,
network listener, signing key or real native acceptance is used.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
UNSIGNED_BYTES = b"unsigned mock executable"
SIGNED_BYTES = b"signed mock executable"

TOOL_DOUBLE = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys

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
            "CFBundleIdentifier": "com.daypage.app.localqa"
        }))
        if signed or mode != "missing_unsigned_binary":
            (app / "DayPage").write_bytes(
                b"signed mock executable" if signed else b"unsigned mock executable")
        folder = derived / "Build/Intermediates.noindex/DayPageLocal.build/Debug-iphonesimulator/DayPage.build"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "mock.xcent").write_bytes(plistlib.dumps({
            "application-identifier": "MOCK.com.daypage.app.localqa",
            "keychain-access-groups": ["MOCK.com.daypage.app.localqa"],
        }))
    elif args[0] == "test-without-building":
        signed = "CODE_SIGNING_ALLOWED=YES" in args
        event("signed-tests" if signed else "negative-tests")
        pathlib.Path(option("-resultBundlePath")).mkdir()
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
    elif args[:4] == ["xcresulttool", "get", "test-results", "summary"]:
        negative = "negative-keychain" in option("--path")
        failed = negative_failed if negative else signed_failed
        total = 2 if negative else 16
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
                     "chat-streamed-markdown", "chat-accessibility-size"]
        (output / "manifest.json").write_text(json.dumps([{
            "attachments": [{"suggestedHumanReadableName": name} for name in names]
        }]))
    else:
        raise AssertionError(args)
elif tool == "lsof":
    path = state / "fixture.pid"
    if not path.exists():
        raise SystemExit(1)
    print(path.read_text())
elif tool == "curl":
    print("GET-326-local-fixture")
elif tool == "codesign":
    event("mock-signature-check")
elif tool == "otool":
    print("sectname __entitlements")
else:
    raise AssertionError(tool)
'''


class NativeCIOrchestrationTests(unittest.TestCase):
    def run_fixture(self, mode):
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
        for name in ("CardToolsSpeechUITests.swift", "ChatExperienceUITests.swift"):
            shutil.copy2(ROOT / "DayPageLocalUITests" / name, sources)
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
        for tool in ("git", "xcodebuild", "xcrun", "lsof", "curl", "codesign", "otool"):
            (binaries / tool).symlink_to(double.name)
        runner = root / "runner"
        runner.mkdir()
        evidence = runner / "evidence"
        environment = {
            **os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_RUN_ID": "host-mock",
            "RUNNER_TEMP": str(runner), "DAYPAGE_NATIVE_CI_OUTPUT_DIR": str(evidence),
            "DAYPAGE_NATIVE_UI_SUITE": "card_tools_speech",
            "NATIVE_CI_MOCK_MODE": mode, "NATIVE_CI_MOCK_STATE": str(state),
        }
        process = subprocess.Popen(
            ["bash", str(qa / "run_local_native_ci.sh")], cwd=root, env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            # Only this test's newly created process group is terminated.
            os.killpg(process.pid, signal.SIGTERM)
            output, _ = process.communicate(timeout=5)
            self.fail("Host orchestration fixture timed out:\n" + output[-2000:])
        events = (state / "events").read_text().splitlines()
        return process.returncode, output, evidence, events

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
        self.assertNotIn("signed-build", events)
        self.assertFalse((evidence / "native-acceptance.json").exists())


if __name__ == "__main__":
    unittest.main()
