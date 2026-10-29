"""Assert the shipping iOS target cannot link the archived cloud runtime."""
import json
import pathlib
import plistlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "plutil OpenStep conversion requires macOS")
class LocalIOSContract(unittest.TestCase):
    def test_ios_has_only_the_file_core_and_local_sources(self):
        result = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(ROOT / "DayPageLocal/DayPageLocal.xcodeproj/project.pbxproj")])
        objects = json.loads(result)["objects"]
        app = next(o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o.get("name") == "DayPage")
        products = [objects[key]["productName"] for key in app.get("packageProductDependencies", [])]
        self.assertEqual(products, ["DayPageCore"])
        self.assertEqual(app.get("dependencies", []), [])
        sources = next(objects[p] for p in app["buildPhases"] if objects[p]["isa"] == "PBXSourcesBuildPhase")
        filenames = [objects[objects[b]["fileRef"]]["path"] for b in sources["files"]]
        self.assertTrue(filenames)
        self.assertFalse(any("Auth" in name or "Sync" in name or "Secrets" in name for name in filenames))

    def test_local_info_has_no_login_callback_or_cloud_entitlement(self):
        with (ROOT / "DayPageLocal/Info.plist").open("rb") as f:
            info = plistlib.load(f)
        self.assertNotIn("CFBundleURLTypes", info)
        self.assertNotIn("UIBackgroundModes", info)
        with (ROOT / "DayPageLocal/DayPage.entitlements").open("rb") as f:
            self.assertEqual(plistlib.load(f), {})


if __name__ == "__main__":
    unittest.main()
