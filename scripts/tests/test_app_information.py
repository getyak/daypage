"""Compile only the Foundation public-information client and its transport fixture.

No packages, Xcode project, Simulator, real endpoint or notebook are used.
Run on a macOS host with available build capacity (or hosted CI).
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppInformationTests(unittest.TestCase):
    def test_public_information_boundary(self):
        source = ROOT / "DayPageLocal/AppInformationService.swift"
        self.assertTrue(source.is_file(), "Public-information client is not implemented")
        if sys.platform != "darwin":
            self.skipTest("Foundation URLSession transport fixture requires macOS")
        with tempfile.TemporaryDirectory(prefix="daypage-app-information-") as temporary:
            work = Path(temporary)
            binary = work / "app-information-tests"
            result = subprocess.run([
                "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                "-j", "1", "-module-cache-path", str(work / "module-cache"),
                str(source), str(ROOT / "scripts/tests/fixtures/app_information.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([
                str(binary), str(ROOT / "DayPageLocal/Resources/app-info.json"),
            ], capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: public information boundaries", result.stdout)
            print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
