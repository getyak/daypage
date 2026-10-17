#!/usr/bin/env python3
"""Offline regressions for the exact release environment overlay boundary."""
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/apply_release_supabase_overlay.py"
URL = "https://abcdefghijklmnopqrst.supabase.co"
KEY = "sb_publishable_synthetic_public_key_for_tests"


class ReleaseOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / ".env"
        self.original = b"# keep\r\nSENTRY_DSN=private-sentinel\r\nUNKNOWN=\xffopaque\r\nSUPABASE_URL=old\r\nSUPABASE_ANON_KEY=old\r\nSUPABASE_URL=duplicate\r\nSUPABASE_PUBLISHABLE_KEY=stale\r\nLAST=keep"
        self.path.write_bytes(self.original)

    def run_overlay(self, **changes):
        env = {"PATH": os.environ.get("PATH", ""), "DAYPAGE_SUPABASE_URL": URL,
               "DAYPAGE_SUPABASE_PUBLISHABLE_KEY": KEY}
        env.update(changes)
        env = {k: v for k, v in env.items() if v is not None}
        return subprocess.run([sys.executable, str(SCRIPT), str(self.path)],
                              env=env, capture_output=True, timeout=10)

    def test_preserves_opaque_bytes_and_replaces_all_public_duplicates(self):
        result = self.run_overlay()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(),
            b"# keep\r\nSENTRY_DSN=private-sentinel\r\nUNKNOWN=\xffopaque\r\nLAST=keep\r\n"
            + f"SUPABASE_URL={URL}\r\nSUPABASE_PUBLISHABLE_KEY={KEY}\r\n".encode())
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertNotIn(KEY.encode(), result.stdout + result.stderr)
        self.assertNotIn(b"private-sentinel", result.stdout + result.stderr)

    def test_empty_file_and_lf_are_supported(self):
        for raw in [b"", b"SENTRY_DSN=preserve\n", b"LAST=preserve",
                    b"OPAQUE=keep\rSUPABASE_URL=inside-value\n"]:
            with self.subTest(raw=raw):
                self.path.write_bytes(raw)
                self.assertEqual(self.run_overlay().returncode, 0)
                expected = raw + (b"\n" if raw and not raw.endswith(b"\n") else b"")
                expected += f"SUPABASE_URL={URL}\nSUPABASE_PUBLISHABLE_KEY={KEY}\n".encode()
                self.assertEqual(self.path.read_bytes(), expected)

    def test_invalid_pair_refuses_without_mutation_or_leaking_values(self):
        cases = [
            {"DAYPAGE_SUPABASE_URL": None}, {"DAYPAGE_SUPABASE_PUBLISHABLE_KEY": None},
            {"DAYPAGE_SUPABASE_URL": ""}, {"DAYPAGE_SUPABASE_PUBLISHABLE_KEY": ""},
            {"DAYPAGE_SUPABASE_URL": "http://abcdefghijklmnopqrst.supabase.co"},
            {"DAYPAGE_SUPABASE_URL": URL + "/path"},
            {"DAYPAGE_SUPABASE_URL": URL + ":443"},
            {"DAYPAGE_SUPABASE_URL": URL + "\nINJECT=private-sentinel"},
            {"DAYPAGE_SUPABASE_PUBLISHABLE_KEY": "sb_secret_private-sentinel"},
            {"DAYPAGE_SUPABASE_PUBLISHABLE_KEY": "eyJprivate-sentinel"},
            {"DAYPAGE_SUPABASE_PUBLISHABLE_KEY": KEY + "\r\nINJECT=private-sentinel"},
        ]
        for changes in cases:
            with self.subTest(field=next(iter(changes))):
                result = self.run_overlay(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"[release-overlay]", result.stderr)
                self.assertNotIn(b"private-sentinel", result.stdout + result.stderr)
                self.assertNotIn(KEY.encode(), result.stdout + result.stderr)
                self.assertEqual(self.path.read_bytes(), self.original)

    def test_missing_symlink_directory_and_hardlink_refuse(self):
        self.path.unlink()
        self.assertNotEqual(self.run_overlay().returncode, 0)
        target = self.path.parent / "target"
        target.write_bytes(self.original)
        self.path.symlink_to(target)
        self.assertNotEqual(self.run_overlay().returncode, 0)
        self.assertEqual(target.read_bytes(), self.original)
        self.path.unlink()
        self.path.mkdir()
        self.assertNotEqual(self.run_overlay().returncode, 0)
        self.path.rmdir()
        os.link(target, self.path)
        self.assertNotEqual(self.run_overlay().returncode, 0)
        self.assertEqual(target.read_bytes(), self.original)

    def test_failed_atomic_replace_preserves_original_and_cleans_temp(self):
        spec = importlib.util.spec_from_file_location("release_overlay", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with mock.patch.object(module.os, "replace", side_effect=OSError("private-sentinel")):
            with self.assertRaises(module.OverlayError):
                module.apply_overlay(self.path, URL, KEY)
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), [".env"])

    def test_workflow_applies_required_pair_before_validation_and_signing(self):
        workflow = (ROOT / ".github/workflows/testflight.yml").read_text()
        overlay = workflow.index("python3 scripts/ci/apply_release_supabase_overlay.py .env")
        validator = workflow.index("bash scripts/ci/validate_release_supabase_config.sh .env")
        self.assertLess(overlay, validator)
        self.assertLess(validator, workflow.index("- name: Run Fastlane"))
        for name in ["DAYPAGE_SUPABASE_URL", "DAYPAGE_SUPABASE_PUBLISHABLE_KEY"]:
            self.assertIn("${{ secrets." + name + " }}", workflow)

    def test_ruby_is_discovered_and_executed_by_actual_runner(self):
        runner = ROOT / "scripts/ci/run_script_tests.sh"
        result = subprocess.run(["bash", str(runner), "--list"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"test_release_signing_profiles.rb", result.stdout)
        test = self.path.parent / "synthetic.rb"
        test.write_text('puts "RUBY_DISCOVERY_SENTINEL"\nexit 7\n')
        result = subprocess.run(["bash", str(runner), str(test)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"RUBY_DISCOVERY_SENTINEL", result.stdout)


if __name__ == "__main__":
    unittest.main()
