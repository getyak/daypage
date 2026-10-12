#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/select_simulator.py.

These exercise the real selector through its CLI and its public helpers so the
daily-device policy keeps its contract: numbered modern iPhones beat the SE
line, explicit UDIDs are validated and fail closed, and the remote-CI
--fallback-name output is preserved.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SELECTOR = REPO_ROOT / "scripts" / "ci" / "select_simulator.py"


def _load_selector():
    spec = importlib.util.spec_from_file_location("daypage_select_simulator", SELECTOR)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


selector = _load_selector()

IOS_18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
IOS_26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
NON_IOS = "com.apple.CoreSimulator.SimRuntime.xrOS-2-0"


def make_payload(*entries: tuple[str, str, str, bool]) -> dict:
    """Build a simctl-shaped payload from (runtime, name, udid, available)."""
    devices: dict[str, list[dict]] = {}
    for runtime, name, udid, available in entries:
        devices.setdefault(runtime, []).append(
            {"name": name, "udid": udid, "isAvailable": available, "state": "Shutdown"}
        )
    return {"devices": devices}


def run_selector(payload: dict, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(payload, handle)
        path = handle.name
    try:
        return subprocess.run(
            [sys.executable, str(SELECTOR), "--input", path, *args],
            capture_output=True,
            text=True,
            env=env,
        )
    finally:
        os.unlink(path)


class SelectionPolicyTests(unittest.TestCase):
    def test_numbered_beats_se_on_same_runtime(self) -> None:
        # Local repro: ascending natural sort put "iPhone SE" after "iPhone 17
        # Pro", so the old max() picked the SE.
        payload = make_payload(
            (IOS_26, "iPhone SE (3rd generation)", "SE-26", True),
            (IOS_26, "iPhone 17 Pro", "IPHONE-17-PRO", True),
        )
        self.assertEqual(selector.select_udid(payload), "IPHONE-17-PRO")

    def test_numbered_on_older_runtime_beats_newer_se(self) -> None:
        payload = make_payload(
            (IOS_26, "iPhone SE (3rd generation)", "SE-26", True),
            (IOS_18, "iPhone 16", "IPHONE-16-18", True),
        )
        self.assertEqual(selector.select_udid(payload), "IPHONE-16-18")

    def test_newer_runtime_wins_within_numbered(self) -> None:
        payload = make_payload(
            (IOS_18, "iPhone 17 Pro", "IPHONE-17-18", True),
            (IOS_26, "iPhone 16", "IPHONE-16-26", True),
        )
        self.assertEqual(selector.select_udid(payload), "IPHONE-16-26")

    def test_numeric_model_breaks_runtime_tie(self) -> None:
        payload = make_payload(
            (IOS_26, "iPhone 16", "IPHONE-16", True),
            (IOS_26, "iPhone 17 Pro Max", "IPHONE-17", True),
        )
        self.assertEqual(selector.select_udid(payload), "IPHONE-17")

    def test_se_is_used_only_when_no_numbered_device_exists(self) -> None:
        payload = make_payload(
            (IOS_18, "iPhone SE (3rd generation)", "SE-18", True),
            (IOS_26, "iPhone SE (3rd generation)", "SE-26", True),
        )
        self.assertEqual(selector.select_udid(payload), "SE-26")

    def test_booted_ipad_is_ignored(self) -> None:
        payload = make_payload(
            (IOS_26, "iPad Pro 13-inch (M4)", "IPAD-BOOTED", True),
            (IOS_26, "iPhone 16", "IPHONE-16", True),
        )
        payload["devices"][IOS_26][0]["state"] = "Booted"
        self.assertEqual(selector.select_udid(payload), "IPHONE-16")

    def test_ipad_only_payload_has_no_default_phone(self) -> None:
        payload = make_payload((IOS_26, "iPad Pro 13-inch (M4)", "IPAD-ONLY", True))
        self.assertIsNone(selector.select_udid(payload))

    def test_unavailable_devices_are_ignored(self) -> None:
        payload = make_payload(
            (IOS_26, "iPhone 17 Pro", "IPHONE-17", False),
            (IOS_26, "iPhone 16", "IPHONE-16", True),
        )
        self.assertEqual(selector.select_udid(payload), "IPHONE-16")

    def test_non_ios_runtime_is_ignored(self) -> None:
        payload = make_payload(
            (NON_IOS, "iPhone 18 Pro", "NON-IOS-NEWER", True),
            (IOS_26, "iPhone 16", "IPHONE-16", True),
        )
        self.assertEqual(selector.select_udid(payload), "IPHONE-16")

    def test_non_ios_runtime_alone_has_no_phone(self) -> None:
        payload = make_payload((NON_IOS, "iPhone 18 Pro", "NON-IOS-ONLY", True))
        self.assertIsNone(selector.select_udid(payload))


class ExplicitUdidTests(unittest.TestCase):
    payload = make_payload(
        (IOS_26, "iPhone 17 Pro", "IPHONE-17", True),
        (IOS_26, "iPhone SE (3rd generation)", "IPHONE-SE", True),
        (IOS_26, "iPad Pro 13-inch (M4)", "IPAD-1", True),
        (IOS_18, "iPhone 16", "IPHONE-16-OFF", False),
        (NON_IOS, "iPhone 18 Pro", "NON-IOS-PHONE", True),
    )

    def test_explicit_udid_is_used(self) -> None:
        result = run_selector(self.payload, "--udid", "IPHONE-17", "--format", "destination")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "platform=iOS Simulator,id=IPHONE-17")

    def test_missing_udid_fails_even_with_fallback_name(self) -> None:
        result = run_selector(
            self.payload,
            "--udid",
            "DOES-NOT-EXIST",
            "--format",
            "destination",
            "--fallback-name",
            "iPhone 16",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")
        self.assertIn("DOES-NOT-EXIST", result.stderr)

    def test_empty_udid_fails_closed(self) -> None:
        result = run_selector(self.payload, "--udid", "", "--format", "destination")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_unavailable_udid_fails(self) -> None:
        result = run_selector(self.payload, "--udid", "IPHONE-16-OFF")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_explicit_ipad_is_rejected_for_primary_profile(self) -> None:
        result = run_selector(
            self.payload, "--udid", "IPAD-1", "--format", "destination", "--fallback-name", "iPhone 16"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_explicit_ipad_is_allowed_for_ipad_profile(self) -> None:
        result = run_selector(
            self.payload, "--udid", "IPAD-1", "--format", "destination", "--profile", "ipad"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "platform=iOS Simulator,id=IPAD-1")

    def test_ipad_profile_is_read_from_environment(self) -> None:
        env = dict(os.environ, DEV_IOS_PROFILE="ipad")
        result = run_selector(self.payload, "--udid", "IPAD-1", "--format", "destination", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "platform=iOS Simulator,id=IPAD-1")

    def test_ipad_profile_rejects_iphone(self) -> None:
        result = run_selector(
            self.payload, "--udid", "IPHONE-17", "--format", "destination", "--profile", "ipad"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_primary_profile_allows_explicit_se(self) -> None:
        result = run_selector(self.payload, "--udid", "IPHONE-SE", "--format", "destination")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "platform=iOS Simulator,id=IPHONE-SE")

    def test_explicit_id_on_non_ios_runtime_is_rejected(self) -> None:
        result = run_selector(self.payload, "--udid", "NON-IOS-PHONE", "--format", "destination")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")


class OutputContractTests(unittest.TestCase):
    def test_default_format_prints_raw_udid(self) -> None:
        payload = make_payload((IOS_26, "iPhone 17 Pro", "IPHONE-17", True))
        result = run_selector(payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "IPHONE-17\n")

    def test_remote_ci_fallback_name_when_no_phone(self) -> None:
        payload = make_payload((IOS_26, "iPad Pro 13-inch (M4)", "IPAD-1", True))
        result = run_selector(payload, "--format", "destination", "--fallback-name", "iPhone 16")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "platform=iOS Simulator,name=iPhone 16\n")

    def test_no_phone_without_fallback_fails(self) -> None:
        payload = make_payload((IOS_26, "iPad Pro 13-inch (M4)", "IPAD-1", True))
        result = run_selector(payload, "--format", "destination")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_invalid_json_returns_usage_error(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            handle.write("not json")
            path = handle.name
        try:
            result = subprocess.run(
                [sys.executable, str(SELECTOR), "--input", path],
                capture_output=True,
                text=True,
            )
        finally:
            os.unlink(path)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
