"""Keep the explicit Mac exchange consumer outside the legacy cloud runtime."""
import json
import pathlib
import re
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MacExchangeBoundary(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "OpenStep project parsing requires plutil")
    def test_only_mac_links_the_local_exchange_product(self):
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-", str(ROOT / "DayPage.xcodeproj/project.pbxproj")
        ]))["objects"]
        targets = [value for value in project.values() if value.get("isa") == "PBXNativeTarget"]
        for target in targets:
            names = [project[ref]["productName"] for ref in target.get("packageProductDependencies", [])]
            self.assertEqual("DayPageMacExchange" in names, target["name"] == "DayPageMac", target["name"])
        product = next(value for value in project.values() if value.get("productName") == "DayPageMacExchange")
        self.assertEqual(project[product["package"]]["relativePath"], "DayPageMacExchange")

    def test_adapter_has_only_local_core_and_system_framework_dependencies(self):
        package = (ROOT / "DayPageMacExchange/Package.swift").read_text()
        self.assertIn('.package(path: "../DayPageCore")', package)
        self.assertNotRegex(package, r"\.package\(\s*url:")
        allowed = {"Combine", "Foundation", "DayPageCore", "QuickLook", "SwiftUI", "UniformTypeIdentifiers"}
        for source in (ROOT / "DayPageMacExchange/Sources").rglob("*.swift"):
            imports = set(re.findall(r"^import (\w+)", source.read_text(), re.MULTILINE))
            self.assertTrue(imports.issubset(allowed), (source.name, imports - allowed))
        root = (ROOT / "DayPageMac/App/MacRootView.swift").read_text()
        self.assertIn("case notebookFiles", root)
        self.assertIn("MacNotebookExchangeView(legacyVault:", root)

    def test_hosted_mac_job_runs_the_actual_adapter_tests(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  macos-build:", 1)[1].split("\n  ui-tests:", 1)[0]
        self.assertIn("swift test --package-path DayPageMacExchange", job)
        self.assertIn("-target DayPageMac", job)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", job)

    def test_module_localizations_are_complete_and_have_no_duplicate_keys(self):
        resources = ROOT / "DayPageMacExchange/Sources/DayPageMacExchange/Resources"
        keys = []
        for locale in ("en", "zh-Hans"):
            content = (resources / f"{locale}.lproj/Localizable.strings").read_text()
            locale_keys = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', content, re.MULTILINE)
            self.assertEqual(len(locale_keys), len(set(locale_keys)), locale)
            keys.append(set(locale_keys))
        self.assertEqual(*keys)


if __name__ == "__main__":
    unittest.main()
