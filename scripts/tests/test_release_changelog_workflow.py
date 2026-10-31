"""Run actual release-note workflow steps with isolated Git and a no-network gh."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def workflow_step(path, name):
    step = path.read_text().split(f"      - name: {name}\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    body = step.split("        run: |\n", 1)[1]
    return "\n".join(line[10:] if line.startswith("          ") else "" for line in body.splitlines())


class ReleaseChangelogWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="daypage-changelog-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "gh-calls"
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                    "GITHUB_REPOSITORY": "fixture/daypage", "RUNNER_TEMP": str(self.root),
                    "GH_CALLS": str(self.calls), "GH_BODY": "Useful release notes.\n",
                    "GITHUB_OUTPUT": str(self.root / "outputs"), "RELEASE_TAG": "v0.5.2"}
        self.env["COMMIT_MSG"] = ""
        gh = self.bin / "gh"
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GH_CALLS"\nprintf "%s" "$GH_BODY"\n')
        gh.chmod(0o755)
        # Test strings need no sed rewriting. The real step uses macOS sed -i '';
        # bypass only that platform-specific formatter to run the shell fixture on Linux too.
        sed = self.bin / "sed"
        sed.write_text("#!/bin/sh\nexit 0\n")
        sed.chmod(0o755)
        for args in [["init"], ["config", "user.name", "Fixture"],
                     ["config", "user.email", "fixture@example.invalid"],
                     ["commit", "--allow-empty", "-m", "Merge pull request #951 from fixture/release"]]:
            self.git(*args)
        self.env["GITHUB_SHA"] = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env,
                              text=True, capture_output=True, check=True)

    def run_step(self, path, name, **env):
        return subprocess.run(["bash", "-c", workflow_step(ROOT / path, name)], cwd=self.root,
                              env={**self.env, **env}, text=True, capture_output=True)

    def notes(self):
        return (self.root / "changelog.txt").read_text()

    def test_manual_dispatch_resolves_pr_notes_from_exact_candidate(self):
        result = self.run_step(".github/workflows/testflight.yml", "Build release changelog")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.notes(), "Useful release notes.\n")
        self.assertIn("pr view 951 --repo fixture/daypage", self.calls.read_text())

    def test_manual_plain_commit_has_meaningful_notes_without_pr(self):
        self.git("commit", "--allow-empty", "-m", "Improve local notebook sharing")
        sha = self.git("rev-parse", "HEAD").stdout.strip()
        result = self.run_step(".github/workflows/testflight.yml", "Build release changelog", GITHUB_SHA=sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Improve local notebook sharing", self.notes())
        self.assertFalse(self.calls.exists())

    def test_unknown_manual_candidate_fails_without_empty_artifact(self):
        result = self.run_step(".github/workflows/testflight.yml", "Build release changelog", GITHUB_SHA="f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "changelog.txt").exists())

    def test_push_message_is_preserved_as_literal_data(self):
        marker = self.root / "must-not-exist"
        text = f"Improve capture $(touch {marker})"
        result = self.run_step(".github/workflows/testflight.yml", "Build release changelog", COMMIT_MSG=text)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.notes(), text)
        self.assertFalse(marker.exists())

    def test_empty_historical_artifact_uses_matching_release_notes(self):
        path = self.root / "changelog/changelog.txt"
        path.parent.mkdir()
        path.write_text("  \n")
        result = self.run_step(".github/workflows/update-changelog.yml", "Recover missing release notes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), "Useful release notes.\n")
        self.assertIn("release view v0.5.2 --repo fixture/daypage", self.calls.read_text())

    def test_existing_nonempty_artifact_is_not_replaced(self):
        path = self.root / "changelog/changelog.txt"
        path.parent.mkdir()
        path.write_text("Original exact build notes.\n")
        result = self.run_step(".github/workflows/update-changelog.yml", "Recover missing release notes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), "Original exact build notes.\n")
        self.assertFalse(self.calls.exists())

    def test_recovery_refuses_empty_release_body(self):
        path = self.root / "changelog/changelog.txt"
        path.parent.mkdir()
        path.write_text("")
        result = self.run_step(".github/workflows/update-changelog.yml", "Recover missing release notes", GH_BODY="\n ")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "")

    def test_recovery_does_not_execute_untrusted_tag(self):
        path = self.root / "changelog/changelog.txt"
        path.parent.mkdir()
        path.write_text("")
        marker = self.root / "must-not-exist"
        result = self.run_step(".github/workflows/update-changelog.yml", "Recover missing release notes", RELEASE_TAG=f"v0.5.2; touch {marker}")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
