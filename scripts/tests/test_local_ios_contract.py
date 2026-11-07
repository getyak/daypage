"""Assert the shipping iOS target cannot link the archived cloud runtime."""
import json
import pathlib
import plistlib
import re
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
        self.assertEqual(set(products), {"DayPageCore", "SwiftStreamingMarkdown"})
        dependencies = [objects[objects[key]["target"]]["name"] for key in app.get("dependencies", [])]
        self.assertEqual(set(dependencies), {"DayPageWatch", "DayPageLocalShare"})
        share = next(o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o.get("name") == "DayPageLocalShare")
        self.assertEqual([objects[key]["productName"] for key in share.get("packageProductDependencies", [])], ["DayPageCapture"])
        self.assertEqual(share.get("dependencies", []), [])
        watch = next(o for o in objects.values() if o.get("isa") == "PBXNativeTarget" and o.get("name") == "DayPageWatch")
        watch_products = [objects[key]["productName"] for key in watch.get("packageProductDependencies", [])]
        self.assertEqual(watch_products, ["DayPageCapture"])
        sources = next(objects[p] for p in app["buildPhases"] if objects[p]["isa"] == "PBXSourcesBuildPhase")
        filenames = [objects[objects[b]["fileRef"]]["path"] for b in sources["files"]]
        self.assertTrue(filenames)
        self.assertFalse(any("Auth" in name or "Sync" in name or "Secrets" in name for name in filenames))

    def test_local_info_has_no_login_and_only_personal_cloud_documents(self):
        with (ROOT / "DayPageLocal/Info.plist").open("rb") as f:
            info = plistlib.load(f)
        self.assertNotIn("CFBundleURLTypes", info)
        self.assertNotIn("UIBackgroundModes", info)
        with (ROOT / "DayPageLocal/DayPage.entitlements").open("rb") as f:
            self.assertEqual(plistlib.load(f), {
                "com.apple.security.application-groups": ["group.com.daypage.app$(DAYPAGE_QA_BUNDLE_SUFFIX).capture"],
                "com.apple.developer.icloud-container-identifiers": ["iCloud.com.daypage.app"],
                "com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.daypage.app"],
                "com.apple.developer.icloud-services": ["CloudDocuments"],
            })
        with (ROOT / "DayPageLocalWatch/Info.plist").open("rb") as f:
            watch_info = plistlib.load(f)
        self.assertEqual(watch_info["WKCompanionAppBundleIdentifier"], "com.daypage.app$(DAYPAGE_QA_BUNDLE_SUFFIX)")
        self.assertTrue(watch_info["WKApplication"])
        with (ROOT / "DayPageLocalShare/Info.plist").open("rb") as f:
            share_info = plistlib.load(f)
        self.assertEqual(share_info["NSExtension"]["NSExtensionPointIdentifier"], "com.apple.share-services")
        self.assertEqual(share_info["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"], {"NSExtensionActivationSupportsImageWithMaxCount": 1})
        with (ROOT / "DayPageLocalShare/DayPageShare.entitlements").open("rb") as f:
            self.assertEqual(plistlib.load(f), {"com.apple.security.application-groups": ["group.com.daypage.app$(DAYPAGE_QA_BUNDLE_SUFFIX).capture"]})
        self.assertEqual(share_info["DayPageCaptureAppGroup"], info["DayPageCaptureAppGroup"])
        self.assertNotIn("CFBundleURLTypes", share_info)
        self.assertIn("NSSpeechRecognitionUsageDescription", info)
        capture_sources = list((ROOT / "DayPageCore/Sources/DayPageCapture").glob("*.swift"))
        self.assertTrue(capture_sources)
        for source in capture_sources:
            content = source.read_text()
            self.assertNotIn("import DayPageCore", content)
            self.assertNotIn("URLSession", content)


class LocalPrivacyContract(unittest.TestCase):
    def test_file_metadata_reasons_cover_vault_and_selected_files(self):
        with (ROOT / "DayPageLocal/PrivacyInfo.xcprivacy").open("rb") as file:
            manifest = plistlib.load(file)
        categories = {
            item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
            for item in manifest["NSPrivacyAccessedAPITypes"]
        }
        category = "NSPrivacyAccessedAPICategoryFileTimestamp"
        self.assertIn(category, categories, "Vault path guards read file metadata")
        self.assertTrue({"C617.1", "3B52.1"}.issubset(categories[category]))
        self.assertIn("CA92.1", categories["NSPrivacyAccessedAPICategoryUserDefaults"])
        self.assertFalse(manifest["NSPrivacyTracking"])
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])
        for data_type in manifest["NSPrivacyCollectedDataTypes"]:
            self.assertFalse(data_type["NSPrivacyCollectedDataTypeTracking"])


class LocalAppIntentMetadataContract(unittest.TestCase):
    def test_shipping_intent_descriptions_avoid_rejected_siri_branding(self):
        # ASC 90626 rejects descriptions containing "apple", including localized metadata.
        descriptions = []
        for target in ("DayPageLocal", "DayPageLocalWatch"):
            for source in (ROOT / target).glob("*.swift"):
                literals = re.findall(r'IntentDescription\(\s*("(?:[^"\\]|\\.)*")', source.read_text())
                for literal in literals:
                    descriptions.append(literal)
                    self.assertNotRegex(json.loads(literal), r"(?i)apple", str(source))
                    for strings in (ROOT / target / "Resources").glob("*.lproj/Localizable.strings"):
                        translations = re.findall(
                            r"^" + re.escape(literal) + r'\s*=\s*("(?:[^"\\]|\\.)*")\s*;',
                            strings.read_text(), re.MULTILINE)
                        for translation in translations:
                            self.assertNotRegex(json.loads(translation), r"(?i)apple", str(strings))
        self.assertTrue(descriptions, "Shipping Watch App Intent metadata must be checked")


if __name__ == "__main__":
    unittest.main()
