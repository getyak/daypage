"""Exercise the local draft commit/recovery boundary with actual production Swift.

Run: python3 scripts/tests/test_capture_draft_transactions.py

This macOS host test compiles DayPageCore, CaptureDraftStore, PendingNoteAsset,
and NotebookModel's unchanged method bodies. Only the app constructor is replaced
to inject a temporary Vault and an isolated, never-written preferences suite.
It does not launch iOS, use Keychain, open a real Vault, or prove device behavior.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "draft host tests require macOS SwiftUI")
class CaptureDraftTransactions(unittest.TestCase):
    def run_command(self, command, **kwargs):
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=120, **kwargs
        )
        self.assertEqual(
            result.returncode, 0,
            f"Command failed: {' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}",
        )
        return result

    def test_draft_transactions_and_recovery(self):
        if not shutil.which("xcrun"):
            self.skipTest("Xcode command-line tools are unavailable")
        if os.geteuid() == 0:
            self.skipTest("chmod regression requires an unprivileged account")
        with tempfile.TemporaryDirectory(prefix="daypage-draft-host-") as scratch:
            work = Path(scratch).resolve()
            modules = work / "Modules"
            modules.mkdir()
            fixtures = work / "fixtures"
            fixtures.mkdir()
            module_cache = work / "module-cache"
            swift = ["xcrun", "swiftc", "-module-cache-path", str(module_cache)]
            probe = subprocess.run(
                [*swift, "-typecheck", "-"], input="import SwiftUI\n",
                capture_output=True, text=True, timeout=60,
            )
            if probe.returncode and "no such module 'SwiftUI'" in probe.stderr:
                self.skipTest("SwiftUI is unavailable in this toolchain")
            self.assertEqual(probe.returncode, 0, probe.stderr)

            core_sources = sorted((ROOT / "DayPageCore/Sources/DayPageCore").glob("*.swift"))
            self.run_command([
                *swift, "-parse-as-library", "-emit-library", "-emit-module",
                "-module-name", "DayPageCore", "-emit-module-path",
                str(modules / "DayPageCore.swiftmodule"), "-o",
                str(work / "libDayPageCore.dylib"), *map(str, core_sources),
            ])

            model = (ROOT / "DayPageLocal/NotebookModel.swift").read_text()
            constructor_start = model.index("  init() {")
            constructor_end = model.index("\n  static var isQA:", constructor_start)
            isolated_constructor = '''  init(root: URL, fixtureAssets: [PendingNoteAsset] = []) {
    self.root = root
    guard let isolated = UserDefaults(suiteName: "com.daypage.host-draft." + UUID().uuidString) else {
      preconditionFailure("Cannot create synthetic preferences")
    }
    preferences = isolated
    store = NotebookStore(root: root)
    conversations = ConversationStore(root: root)
    captureDrafts = CaptureDraftStore(root: root)
    configuration = AIConfiguration()
    pendingAssets = fixtureAssets
  }
'''
            model_file = work / "NotebookModelHost.swift"
            model_file.write_text(
                model[:constructor_start] + isolated_constructor + model[constructor_end:]
            )
            media = (ROOT / "DayPageLocal/CaptureMedia.swift").read_text()
            asset_start = media.index("struct PendingNoteAsset:")
            asset_end = media.index("\nenum CaptureFileReader", asset_start)
            asset_file = work / "PendingNoteAsset.swift"
            asset_file.write_text("import Foundation\n" + media[asset_start:asset_end])

            binary = work / "draft-tests"
            self.run_command([
                *swift, "-parse-as-library", "-I", str(modules), "-L", str(work),
                "-lDayPageCore", "-Xlinker", "-rpath", "-Xlinker", str(work),
                str(model_file), str(asset_file),
                str(ROOT / "DayPageLocal/CaptureDraftStore.swift"),
                str(ROOT / "scripts/tests/fixtures/capture_draft_transactions.swift"),
                "-o", str(binary),
            ])
            environment = dict(os.environ, DAYPAGE_DRAFT_TEST_ROOT=str(fixtures))
            result = self.run_command([str(binary)], env=environment)
            self.assertIn("PASS: 13 draft transaction regression groups", result.stdout)
            print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
