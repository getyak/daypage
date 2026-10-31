"""Exercise the ASC updater against synthetic API responses, never real credentials."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/update_testflight_changelog.py"
TOKEN = "synthetic-jwt-do-not-serialize"
KEY = "synthetic-private-key-do-not-serialize"
APP_ID = "6762390618"
BUILD_ID = "build-2037"
NOTES = "DayPage 0.5.2: local notebook improvements."


class TestFlightChangelogTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("testflight_changelog", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        # The old script imports PyJWT at module load. This clean stub allows
        # RED tests without installing any dependency or minting a token.
        with mock.patch.dict(sys.modules, {"jwt": types.ModuleType("jwt")}):
            spec.loader.exec_module(self.module)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.receipt = root / "receipt.json"
        self.notes = root / "notes.txt"
        self.notes.write_text(NOTES)
        self.environment = {
            "APP_STORE_CONNECT_API_KEY_ID": "synthetic-key-id",
            "APP_STORE_CONNECT_ISSUER_ID": "synthetic-issuer-id",
            "APP_STORE_CONNECT_API_KEY_CONTENT": KEY,
            "ASC_APP_ID": APP_ID,
            "BUILD_NUMBER": "2037",
            "MARKETING_VERSION": "0.5.2",
            "CHANGELOG_FILE": str(self.notes),
            "MAX_WAIT_SECONDS": "0",
            "POLL_INTERVAL_SECONDS": "1",
            "RELEASE_RECEIPT_FILE": str(self.receipt),
            "RELEASE_SOURCE_SHA": "e90d0fc3e5fffbb268ec76dc543c08acddc17ea4",
            "RELEASE_TAG": "v0.5.2",
        }
        self.app = {"type": "apps", "id": APP_ID,
                    "attributes": {"bundleId": "com.daypage.app", "sku": KEY}}
        self.build = {
            "type": "builds", "id": BUILD_ID,
            "attributes": {"version": "2037", "processingState": "VALID",
                           "expired": False, "expirationDate": "2099-02-01T00:00:00Z"},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}},
                "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "version-052"}},
            },
        }
        self.version = {"type": "preReleaseVersions", "id": "version-052",
                        "attributes": {"version": "0.5.2", "platform": "IOS"}}
        self.detail = {"type": "buildBetaDetails", "id": "detail-2037",
                       "attributes": {"internalBuildState": "IN_BETA_TESTING",
                                      "externalBuildState": "READY_FOR_BETA_SUBMISSION"}}
        self.groups = [{"type": "betaGroups", "id": "team-1",
                        "attributes": {"name": "DayPage Team", "isInternalGroup": True,
                                       "testerEmails": ["private@example.invalid"], "token": TOKEN}}]
        self.calls = []
        self.failures = {}
        self.extra_groups = None
        self.notes_saved = False
        self.bad_notes_readback = False
        self.localization_exists = True
        self.group_next_url = None
        self.readback_build_override = None
        self.readback_version_override = None
        self.group_build_ids = {"team-1": [BUILD_ID]}
        self.extra_build_ids = {}
        self.build_links_next_url = None

    def request(self, method, path, token, *, body=None, query=None):
        self.calls.append((method, path, body, query))
        if (method, path) in self.failures:
            return self.failures[method, path], {"raw": TOKEN + KEY}
        if method == "GET" and path == f"/v1/apps/{APP_ID}":
            return 200, {"data": copy.deepcopy(self.app)}
        if method == "GET" and path == "/v1/builds":
            return 200, {"data": [copy.deepcopy(self.build)],
                         "included": [copy.deepcopy(self.version), copy.deepcopy(self.app)]}
        if method == "GET" and path == f"/v1/builds/{BUILD_ID}":
            return 200, {"data": copy.deepcopy(self.readback_build_override or self.build),
                         "included": [copy.deepcopy(self.readback_version_override or self.version),
                                      copy.deepcopy(self.app)]}
        if method == "GET" and path == f"/v1/builds/{BUILD_ID}/buildBetaDetail":
            return 200, {"data": copy.deepcopy(self.detail)}
        if method == "GET" and path == "/v1/betaGroups":
            if query and "filter[builds]" in query:
                return 400, {"errors": [{"code": "PARAMETER_ERROR.INVALID",
                                          "source": {"parameter": "filters"}}]}
            raise AssertionError("Group readback must stay scoped to the verified app route")
        if method == "GET" and path == f"/v1/apps/{APP_ID}/betaGroups":
            if query and query.get("cursor") == "next":
                return 200, {"data": copy.deepcopy(self.extra_groups)}
            result = {"data": copy.deepcopy(self.groups)}
            if self.extra_groups is not None:
                result["links"] = {"next": self.module.ASC_BASE + path + "?cursor=next"}
            if self.group_next_url is not None:
                result["links"] = {"next": self.group_next_url}
            return 200, result
        if method == "GET" and path.startswith("/v1/betaGroups/") and path.endswith("/relationships/builds"):
            group_id = path.split("/")[3]
            ids = self.group_build_ids.get(group_id, [])
            if query and query.get("cursor") == "next":
                ids = self.extra_build_ids[group_id]
            result = {"data": [{"type": "builds", "id": build_id} for build_id in ids]}
            if group_id in self.extra_build_ids and not (query and query.get("cursor") == "next"):
                result["links"] = {"next": self.module.ASC_BASE + path + "?cursor=next"}
            if self.build_links_next_url:
                result["links"] = {"next": self.build_links_next_url}
            return 200, result
        if method == "GET" and path == f"/v1/builds/{BUILD_ID}/betaBuildLocalizations":
            if not self.localization_exists:
                return 200, {"data": []}
            whats_new = NOTES if self.notes_saved and not self.bad_notes_readback else "Old notes"
            return 200, {"data": [{"type": "betaBuildLocalizations", "id": "notes-2037",
                                   "attributes": {"locale": "en-US", "whatsNew": whats_new}}]}
        if method == "PATCH" and path == "/v1/betaBuildLocalizations/notes-2037":
            self.notes_saved = True
            return 200, {"data": body["data"]}
        if method == "POST" and path == "/v1/betaBuildLocalizations":
            self.localization_exists = self.notes_saved = True
            return 201, {"data": {**body["data"], "id": "notes-2037"}}
        raise AssertionError(f"Unexpected ASC operation: {method} {path}")

    def run_updater(self):
        with mock.patch.dict(os.environ, self.environment, clear=True), \
             mock.patch.object(self.module, "make_jwt", return_value=TOKEN), \
             mock.patch.object(self.module, "asc_request", side_effect=self.request), \
             contextlib.redirect_stdout(io.StringIO()), \
             contextlib.redirect_stderr(io.StringIO()):
            return self.module.main()

    def assert_no_write(self):
        self.assertFalse(any(method in {"PATCH", "POST", "DELETE"} for method, *_ in self.calls))
        self.assertFalse(self.receipt.exists())

    def test_wrong_bundle_refuses_before_any_metadata_write(self):
        self.app["attributes"]["bundleId"] = "com.other.app"
        with self.assertRaisesRegex(RuntimeError, "bundle|Bundle"):
            self.run_updater()
        self.assert_no_write()
        self.assertEqual(self.calls[0][1], f"/v1/apps/{APP_ID}")

    def test_wrong_app_response_identity_refuses_write(self):
        self.app["id"] = "999999"
        with self.assertRaises(RuntimeError):
            self.run_updater()
        self.assert_no_write()

    def test_exact_build_app_and_prerelease_identity_are_required(self):
        for change in ("number", "app", "version", "id"):
            with self.subTest(change=change):
                original_build, original_version = copy.deepcopy(self.build), copy.deepcopy(self.version)
                if change == "number": self.build["attributes"]["version"] = "2036"
                if change == "app": self.build["relationships"]["app"]["data"]["id"] = "999999"
                if change == "version": self.version["attributes"]["version"] = "0.5.1"
                if change == "id": self.build["id"] = ""
                with self.assertRaises(RuntimeError): self.run_updater()
                self.assert_no_write()
                self.build, self.version = original_build, original_version

    def test_failed_processing_is_not_a_metadata_success(self):
        self.build["attributes"]["processingState"] = "FAILED"
        with self.assertRaises(RuntimeError): self.run_updater()
        self.assert_no_write()

    def test_wrong_platform_refuses_before_any_metadata_write(self):
        self.version["attributes"]["platform"] = "MAC_OS"
        with self.assertRaisesRegex(RuntimeError, "identity|platform"):
            self.run_updater()
        self.assert_no_write()

    def test_receipt_records_exact_identity_provenance_and_safe_existing_groups(self):
        self.assertEqual(self.run_updater(), 0)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual({key: receipt[key] for key in (
            "appId", "bundleId", "marketingVersion", "buildNumber", "buildId", "sourceSha", "releaseTag")},
            {"appId": APP_ID, "bundleId": "com.daypage.app", "marketingVersion": "0.5.2",
             "buildNumber": "2037", "buildId": BUILD_ID, "sourceSha": self.environment["RELEASE_SOURCE_SHA"],
             "releaseTag": "v0.5.2"})
        self.assertEqual(receipt["processingState"], "VALID")
        self.assertEqual(receipt["internalBuildState"], "IN_BETA_TESTING")
        self.assertEqual(receipt["externalBuildState"], "READY_FOR_BETA_SUBMISSION")
        self.assertEqual(receipt["betaGroups"], [{"id": "team-1", "name": "DayPage Team", "isInternalGroup": True}])
        self.assertIs(receipt["ready"], True)
        self.assertIs(receipt["notesVerified"], True)
        for private in (TOKEN, KEY, "private@example.invalid", "Authorization", "testerEmails"):
            self.assertNotIn(private, self.receipt.read_text())
        self.assertTrue(self.notes_saved)
        self.assertEqual([method for method, *_ in self.calls if method != "GET"], ["PATCH"])
        self.assertTrue(any(path == f"/v1/apps/{APP_ID}/betaGroups" for _, path, _, _ in self.calls))

    def test_ready_for_beta_testing_does_not_mean_in_beta_testing(self):
        self.detail["attributes"]["internalBuildState"] = "READY_FOR_BETA_TESTING"
        self.assertEqual(self.run_updater(), 0)
        self.assertIs(json.loads(self.receipt.read_text())["ready"], False)

    def test_expired_or_missing_expiry_evidence_is_never_ready(self):
        for attributes in ({"expired": True}, {"expirationDate": "2000-01-01T00:00:00Z"},
                           {"expirationDate": None}, {"expired": None}):
            with self.subTest(attributes=attributes):
                original = copy.deepcopy(self.build["attributes"])
                self.build["attributes"].update(attributes)
                self.assertEqual(self.run_updater(), 0)
                self.assertIs(json.loads(self.receipt.read_text())["ready"], False)
                self.build["attributes"] = original

    def test_group_pages_are_read_without_private_tester_data_or_distribution_writes(self):
        self.extra_groups = [{"type": "betaGroups", "id": "external-1",
                              "attributes": {"name": "Existing external group", "isInternalGroup": False}}]
        self.group_build_ids["external-1"] = [BUILD_ID]
        self.assertEqual(self.run_updater(), 0)
        groups = json.loads(self.receipt.read_text())["betaGroups"]
        self.assertEqual([group["id"] for group in groups], ["team-1", "external-1"])
        self.assertFalse(groups[1]["isInternalGroup"])
        self.assertEqual([method for method, *_ in self.calls if method != "GET"], ["PATCH"])

    def test_app_build_and_readback_auth_errors_remain_failures_without_payload_leak(self):
        for status in (401, 403):
            for path in (f"/v1/apps/{APP_ID}", "/v1/builds", f"/v1/builds/{BUILD_ID}/buildBetaDetail",
                         f"/v1/builds/{BUILD_ID}", f"/v1/apps/{APP_ID}/betaGroups",
                         "/v1/betaGroups/team-1/relationships/builds"):
                with self.subTest(status=status, path=path):
                    self.failures = {("GET", path): status}
                    with self.assertRaisesRegex(RuntimeError, f"HTTP {status}") as error:
                        self.run_updater()
                    self.assertNotIn(TOKEN, str(error.exception))
                    self.assertNotIn(KEY, str(error.exception))
                    self.assertFalse(self.receipt.exists())

    def test_note_write_auth_error_does_not_emit_success_receipt(self):
        self.failures = {("PATCH", "/v1/betaBuildLocalizations/notes-2037"): 403}
        with self.assertRaisesRegex(RuntimeError, "HTTP 403") as error: self.run_updater()
        self.assertNotIn(TOKEN, str(error.exception))
        self.assertFalse(self.receipt.exists())

    def test_note_readback_mismatch_does_not_emit_success_receipt(self):
        self.bad_notes_readback = True
        with self.assertRaises(RuntimeError): self.run_updater()
        self.assertFalse(self.receipt.exists())

    def test_create_only_writes_the_requested_build_localization(self):
        self.localization_exists = False
        self.assertEqual(self.run_updater(), 0)
        writes = [(method, path, body) for method, path, body, _ in self.calls if method != "GET"]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][:2], ("POST", "/v1/betaBuildLocalizations"))
        self.assertEqual(writes[0][2]["data"]["relationships"]["build"]["data"],
                         {"type": "builds", "id": BUILD_ID})
        self.assertIs(json.loads(self.receipt.read_text())["notesVerified"], True)

    def test_failed_retry_removes_a_stale_success_receipt(self):
        self.receipt.write_text('{"ready": true}')
        self.app["attributes"]["bundleId"] = "com.other.app"
        with self.assertRaises(RuntimeError): self.run_updater()
        self.assert_no_write()

    def test_post_write_identity_change_does_not_emit_success_receipt(self):
        self.readback_build_override = copy.deepcopy(self.build)
        self.readback_build_override["attributes"]["version"] = "2036"
        with self.assertRaises(RuntimeError): self.run_updater()
        self.assertTrue(self.notes_saved)
        self.assertFalse(self.receipt.exists())

    def test_post_write_platform_change_does_not_emit_success_receipt(self):
        self.readback_version_override = copy.deepcopy(self.version)
        self.readback_version_override["attributes"]["platform"] = "MAC_OS"
        with self.assertRaisesRegex(RuntimeError, "identity|platform"):
            self.run_updater()
        self.assertTrue(self.notes_saved)
        self.assertFalse(self.receipt.exists())

    def test_foreign_or_different_app_group_pagination_never_receives_credentials(self):
        for next_url in (f"https://outside.invalid/v1/apps/{APP_ID}/betaGroups?cursor=next",
                         self.module.ASC_BASE + "/v1/apps/999999/betaGroups?cursor=next"):
            with self.subTest(next_url=next_url):
                self.group_next_url = next_url
                before = len(self.calls)
                with self.assertRaises(RuntimeError): self.run_updater()
                new_calls = self.calls[before:]
                self.assertEqual(sum(path == f"/v1/apps/{APP_ID}/betaGroups" for _, path, _, _ in new_calls), 1)
                self.assertFalse(self.receipt.exists())

    def test_live_unsupported_build_filter_is_replaced_by_exact_group_linkage(self):
        self.groups.append({"type": "betaGroups", "id": "unrelated-1",
                            "attributes": {"name": "Other build group", "isInternalGroup": True}})
        self.group_build_ids["unrelated-1"] = [BUILD_ID + "-other"]
        self.assertEqual(self.run_updater(), 0)
        self.assertEqual([group["id"] for group in json.loads(self.receipt.read_text())["betaGroups"]], ["team-1"])
        self.assertFalse(any(path == "/v1/betaGroups" for _, path, _, _ in self.calls))
        self.assertEqual([method for method, *_ in self.calls if method != "GET"], ["PATCH"])

    def test_target_build_on_second_linkage_page_is_not_missed(self):
        self.group_build_ids["team-1"] = ["older-build"]
        self.extra_build_ids["team-1"] = [BUILD_ID]
        self.assertEqual(self.run_updater(), 0)
        self.assertEqual([group["id"] for group in json.loads(self.receipt.read_text())["betaGroups"]], ["team-1"])
        linkage_calls = [query for _, path, _, query in self.calls if path.endswith("/relationships/builds")]
        self.assertEqual(len(linkage_calls), 2)

    def test_invalid_build_linkage_never_produces_a_receipt(self):
        for identifier in (None, "", 2037):
            with self.subTest(identifier=identifier):
                self.group_build_ids["team-1"] = [identifier]
                with self.assertRaisesRegex(RuntimeError, "invalid group build identity"):
                    self.run_updater()
                self.assertFalse(self.receipt.exists())

    def test_full_group_resources_still_require_attributes(self):
        del self.groups[0]["attributes"]
        with self.assertRaisesRegex(RuntimeError, "invalid betaGroups resource"):
            self.run_updater()
        self.assertFalse(self.receipt.exists())

    def test_foreign_or_different_group_linkage_page_does_not_emit_receipt(self):
        for next_url in ("https://outside.invalid/v1/betaGroups/team-1/relationships/builds?cursor=next",
                         self.module.ASC_BASE + "/v1/betaGroups/unrelated-1/relationships/builds?cursor=next"):
            with self.subTest(next_url=next_url):
                self.build_links_next_url = next_url
                before = len(self.calls)
                with self.assertRaises(RuntimeError): self.run_updater()
                new_calls = self.calls[before:]
                self.assertEqual(sum(path.endswith("/relationships/builds") for _, path, _, _ in new_calls), 1)
                self.assertFalse(self.receipt.exists())

    def test_receipt_and_provenance_remain_optional_for_existing_callers(self):
        for name in ("RELEASE_RECEIPT_FILE", "RELEASE_SOURCE_SHA", "RELEASE_TAG"):
            self.environment.pop(name)
        self.assertEqual(self.run_updater(), 0)
        self.assertTrue(self.notes_saved)
        self.assertFalse(self.receipt.exists())

    def test_empty_changelog_never_contacts_apple(self):
        self.notes.write_text(" \n")
        self.assertEqual(self.run_updater(), 2)
        self.assertEqual(self.calls, [])
        self.assertFalse(self.receipt.exists())


if __name__ == "__main__":
    unittest.main()
