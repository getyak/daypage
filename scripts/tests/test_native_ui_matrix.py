"""Host-only coverage/receipt checks. No native execution is simulated as acceptance."""
import importlib.util
import json
import copy
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/qa/native_ui_matrix.py"


class MatrixCLITests(unittest.TestCase):
    def test_full_plan_covers_all_compiled_cases_in_eight_disjoint_configuration_groups(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "plan.json"
            result = subprocess.run(["python3", str(SCRIPT), "plan", "--repo", str(ROOT),
                                     "--run-id", "12345", "--attempt", "2", "--profile", "intel15",
                                     "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(output.read_text())
            self.assertEqual({s["id"]: len(s["expectedIDs"]) for s in plan["shards"]}, {
                "calendar_card_share": 17, "card_tools": 7, "speech": 4, "chat": 5,
                "diary": 10, "launch": 18, "local_notebook": 17, "unsigned": 2})
            cells = [(s["signingMode"], item) for s in plan["shards"] for item in s["expectedIDs"]]
            self.assertEqual(len(cells), 80)
            self.assertEqual(len(set(cells)), 80)
            self.assertEqual(len(plan["compiledSources"]), 7)


class EvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("native_ui_matrix", SCRIPT)
        cls.matrix = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.matrix)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.plan = self.matrix.make_plan(ROOT, "a" * 40, "12345", "2", "arm64")

    def evidence(self, shard):
        root = self.directory / shard["id"]
        root.mkdir(exist_ok=True)
        negative = shard["signingMode"] == "unsigned"
        prefix = "negative" if negative else "signed"
        log = []
        for identifier in shard["expectedIDs"]:
            _, suite, method = identifier.split("/")
            name = f"-[DayPageLocalUITests.{suite} {method}]"
            log += [f"Test Case '{name}' started.", f"Test Case '{name}' passed (0.100 seconds)."]
        (root / (prefix + "-ui.log")).write_text("\n".join(log) + "\n")
        summary = {"result": "Passed", "totalTestCount": len(shard["expectedIDs"]),
                   "passedTests": len(shard["expectedIDs"]), "failedTests": 0, "skippedTests": 0}
        (root / (prefix + "-summary.log")).write_text(json.dumps(summary))
        (root / "provenance.json").write_text(json.dumps({
            "sourceSHA": self.plan["sourceSHA"], "runId": "12345", "runAttempt": "2", "xcode": "Xcode 26.3\nBuild version QA",
            "simulatorSDK": "26.3", "hostArchitecture": "arm64", "bundleId": "com.daypage.app.localqa",
            "runnerImage": "qa-only"}))
        (root / (prefix + "-attachments")).mkdir(exist_ok=True)
        (root / (prefix + "-attachments/manifest.json")).write_text(json.dumps([{
            "attachments": [{"suggestedHumanReadableName": name} for name in shard["requiredAttachments"]]}]))
        (root / "simulator-boot-receipt.json").write_text(json.dumps({"ready": True, "outcome": "success", "exitCode": 0}))
        (root / "fixture-health.log").write_text(json.dumps({"healthVerified": True}))
        (root / "fixture-listener-probes.log").write_text("accepted_attempt=1\n")
        (root / (prefix + "-executable.sha256")).write_text("b" * 64 + "  QA-executable\n")
        if negative:
            (root / "negative-receipt.json").write_text(json.dumps({"verified": True}))
        else:
            (root / "simulator-entitlements.json").write_text(json.dumps([{"target": "DayPage"}, {"target": "DayPageLocalShare"}]))
            for name in ("signature.log", "signature-verification.log"):
                (root / name).write_text("QA signature verified\n")
            (root / "macho.log").write_text("sectname __entitlements\n")
        return root

    def receipt(self, shard=None, mutation=None, exit_code=0):
        shard = shard or self.plan["shards"][0]
        root = self.evidence(shard)
        if mutation:
            mutation(root, "negative" if shard["signingMode"] == "unsigned" else "signed")
        return self.matrix.make_receipt(self.plan, shard["id"], root, exit_code)

    def test_actual_complete_log_and_summary_are_both_required(self):
        receipt = self.receipt()
        self.assertTrue(receipt["passed"], receipt["errors"])
        self.assertEqual(receipt["observed"]["started"], self.plan["shards"][0]["expectedIDs"])
        for mutation in (
            lambda r, p: (r / (p + "-ui.log")).write_text(""),
            lambda r, p: (r / (p + "-summary.log")).write_text("{}"),
            lambda r, p: (r / (p + "-attachments/manifest.json")).unlink(),
        ):
            with self.subTest(mutation=mutation):
                self.assertFalse(self.receipt(mutation=mutation)["passed"])

    def test_missing_duplicate_unfinished_extra_skip_and_assertion_fail_all_deny(self):
        mutations = {
            "missing": lambda s: "\n".join(s.splitlines()[2:]),
            "duplicate": lambda s: s + s.splitlines()[0] + "\n",
            "unfinished": lambda s: "\n".join(s.splitlines()[:-1]),
            "extra": lambda s: s + "Test Case '-[DayPageLocalUITests.UnknownUITests testUnselected]' started.\n",
            "skip": lambda s: s.replace("passed (0.100 seconds).", "skipped (0.100 seconds).", 1),
            "fail": lambda s: s.replace("passed (0.100 seconds).", "failed (0.100 seconds).", 1),
            "out_of_order": lambda s: "\n".join(reversed(s.splitlines())),
        }
        for name, change in mutations.items():
            with self.subTest(name=name):
                def mutate(root, prefix):
                    path = root / (prefix + "-ui.log")
                    path.write_text(change(path.read_text()))
                self.assertFalse(self.receipt(mutation=mutate)["passed"])

    def test_wrong_sha_run_attempt_mode_and_summary_count_deny(self):
        for key, value in (("sourceSHA", "c" * 40), ("runId", "999"), ("runAttempt", "3"), ("bundleId", "com.daypage.app")):
            def mutate(root, prefix):
                path = root / "provenance.json"
                data = json.loads(path.read_text()); data[key] = value
                path.write_text(json.dumps(data))
            with self.subTest(key=key):
                self.assertFalse(self.receipt(mutation=mutate)["passed"])
        def count(root, prefix):
            path = root / (prefix + "-summary.log")
            data = json.loads(path.read_text()); data["totalTestCount"] += 1
            path.write_text(json.dumps(data))
        self.assertFalse(self.receipt(mutation=count)["passed"])
        signed = self.plan["shards"][0]
        root = self.evidence(signed)
        wrong = copy.deepcopy(self.plan)
        wrong["shards"][0]["signingMode"] = "unsigned"
        with self.assertRaises(ValueError):
            self.matrix.make_receipt(wrong, signed["id"], root, 0)

    def test_unsigned_failure_and_nonzero_orchestration_exit_deny(self):
        shard = self.plan["shards"][-1]
        self.assertTrue(self.receipt(shard)["passed"])
        self.assertFalse(self.receipt(shard, exit_code=65)["passed"])
        self.assertFalse(self.receipt(shard, mutation=lambda r, p: (r / "negative-receipt.json").write_text('{"verified":false}'))["passed"])

    def test_each_branch_attachment_remains_required_in_its_owning_shard(self):
        for shard_id, missing in (("chat", "chat-saved-history"), ("diary", "diary-rediscovered-note"),
                                  ("unsigned", "speech-anonymous-no-keychain")):
            shard = next(s for s in self.plan["shards"] if s["id"] == shard_id)
            def mutate(root, prefix):
                path = root / (prefix + "-attachments/manifest.json")
                data = json.loads(path.read_text())
                data[0]["attachments"] = [a for a in data[0]["attachments"] if a["suggestedHumanReadableName"] != missing]
                path.write_text(json.dumps(data))
            with self.subTest(shard=shard_id):
                receipt = self.receipt(shard, mutation=mutate)
                self.assertFalse(receipt["passed"])
                self.assertIn("missing required branch attachment", receipt["errors"])

    def test_aggregate_requires_all_successful_same_run_receipts_and_exact_union(self):
        receipts = [self.receipt(shard) for shard in self.plan["shards"]]
        result = self.matrix.aggregate(self.plan, receipts, "success")
        self.assertTrue(result["passed"], result["errors"])
        self.assertEqual(result["configurationCells"], 80)
        variants = [receipts[:-1], receipts + [receipts[0]]]
        for key, value in (("sourceSHA", "c" * 40), ("runId", "9"), ("runAttempt", "3"),
                           ("signingMode", "unsigned"), ("passed", False)):
            changed = copy.deepcopy(receipts); changed[0][key] = value; variants.append(changed)
        changed = copy.deepcopy(receipts); changed[0]["observed"]["passed"].append("DayPageLocalUITests/Unknown/testOther"); variants.append(changed)
        for records in variants:
            self.assertFalse(self.matrix.aggregate(self.plan, records, "success")["passed"])
        for status in ("failure", "cancelled", "skipped", ""):
            self.assertFalse(self.matrix.aggregate(self.plan, receipts, status)["passed"])

    def test_compiled_membership_missing_new_and_unknown_test_fail_closed(self):
        repo = self.directory / "repo"
        shutil.copytree(ROOT / "DayPageLocalUITests", repo / "DayPageLocalUITests")
        project = Path("DayPageLocal/DayPageLocal.xcodeproj")
        shutil.copytree(ROOT / project, repo / project)
        # Supporting files are part of the exact source manifest as well.
        for relative in ("scripts/qa/native_ui_matrix.py", "scripts/qa/run_local_native_ci.sh"):
            target = repo / relative; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        # A stray Swift file is not a compiled target member and must not be
        # silently counted as execution coverage by a directory glob.
        (repo / "DayPageLocalUITests/NotCompiledUITests.swift").write_text(
            "import XCTest\nfinal class NotCompiledUITests: XCTestCase {\n func testNotCompiled() {}\n}\n")
        plan = self.matrix.make_plan(repo, "a" * 40, "12345", "2", "arm64")
        self.assertEqual(len(plan["compiledSources"]), 7)
        self.assertNotIn("DayPageLocalUITests/NotCompiledUITests.swift", plan["compiledSources"])
        source = repo / "DayPageLocalUITests/CalendarUITests.swift"
        source.write_text(source.read_text().replace("final class CalendarUITests", "final class UnknownUITests"))
        with self.assertRaises(ValueError):
            self.matrix.make_plan(repo, "a" * 40, "12345", "2", "arm64")
        shutil.copy2(ROOT / "DayPageLocalUITests/CalendarUITests.swift", source)
        source.write_text(source.read_text() + "\nfinal class InheritedUITests: CalendarUITests {}\n")
        with self.assertRaises(ValueError):
            self.matrix.make_plan(repo, "a" * 40, "12345", "2", "arm64")
        shutil.copy2(ROOT / "DayPageLocalUITests/CalendarUITests.swift", source)
        source.write_text(source.read_text() + "\n@Test func futureSwiftTesting() {}\n")
        with self.assertRaises(ValueError):
            self.matrix.make_plan(repo, "a" * 40, "12345", "2", "arm64")
        shutil.copy2(ROOT / "DayPageLocalUITests/CalendarUITests.swift", source)
        source.write_text(source.read_text().replace("private let app", "func testFutureUnmapped() {}\n    private let app", 1))
        with self.assertRaises(ValueError):
            self.matrix.make_plan(repo, "a" * 40, "12345", "2", "arm64")
        shutil.copy2(ROOT / "DayPageLocalUITests/CalendarUITests.swift", source)
        pbx = repo / project / "project.pbxproj"
        pbx.write_text(pbx.read_text().replace("9911C6781D7F333EBB42353F /* CalendarUITests.swift in Sources */,", "", 1))
        with self.assertRaises(ValueError):
            self.matrix.make_plan(repo, "a" * 40, "12345", "2", "arm64")

    def test_aggregate_cli_cannot_accept_a_complete_receipt_set_from_another_run(self):
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        self.plan = self.matrix.make_plan(ROOT, sha, "12345", "2", "arm64")
        plan_file = self.directory / "plan.json"
        plan_file.write_text(json.dumps(self.plan))
        for shard in self.plan["shards"]:
            root = self.directory / ("receipt-" + shard["id"])
            root.mkdir()
            (root / "shard-receipt.json").write_text(json.dumps(self.receipt(shard)))
        command = ["python3", str(SCRIPT), "aggregate", "--plan", str(plan_file),
                   "--receipts", str(self.directory), "--matrix-result", "success",
                   "--output", str(self.directory / "aggregate.json")]
        positive = subprocess.run(command, cwd=ROOT,
                                  env={**os.environ, "GITHUB_RUN_ID": "12345", "GITHUB_RUN_ATTEMPT": "2"},
                                  text=True, capture_output=True)
        self.assertEqual(positive.returncode, 0, positive.stderr)
        self.assertTrue(json.loads((self.directory / "aggregate.json").read_text())["passed"])
        result = subprocess.run(command, cwd=ROOT,
                                env={**os.environ, "GITHUB_RUN_ID": "999", "GITHUB_RUN_ATTEMPT": "2"},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aggregate is not this active source/run", result.stderr)


if __name__ == "__main__":
    unittest.main()
