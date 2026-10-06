"""Exercise the shipped workflow's tag step against isolated Git remotes."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/testflight.yml"


def workflow_step(name):
    source = WORKFLOW.read_text()
    step = source.split(f"      - name: {name}\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    body = step.split("        run: |\n", 1)[1]
    return "\n".join(line[10:] if line.startswith("          ") else ""
                     for line in body.splitlines())


class ReleaseTagTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="daypage-release-tags-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote.git"
        self.repo = self.root / "candidate"
        self.env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0"}
        self.git("init", "--bare", str(self.remote), cwd=self.root)
        self.git("init", str(self.repo), cwd=self.root)
        self.git("config", "user.name", "Release fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / "fixture.txt").write_text("Synthetic release fixture\n")
        self.git("add", "fixture.txt")
        self.git("commit", "-m", "Fixture")
        self.sha = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "HEAD:refs/heads/main")

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, env=self.env,
                              text=True, capture_output=True, check=True)

    def run_tag(self, **overrides):
        env = {**self.env, "TAG": "v0.4.96", "RELEASE_VERSION": "0.4.96",
               "GITHUB_SHA": self.sha, **overrides}
        return subprocess.run(["bash", "-c", workflow_step("Tag release and push")], cwd=self.repo, env=env,
                              text=True, capture_output=True)

    def remote_tags(self):
        return self.git("--git-dir", str(self.remote), "tag", "--list").stdout.splitlines()

    def test_success_tags_exact_built_version_and_candidate(self):
        result = self.run_tag()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_tags(), ["v0.4.96"])
        actual = self.git("--git-dir", str(self.remote), "rev-parse", "v0.4.96^{}").stdout.strip()
        self.assertEqual(actual, self.sha)

    def test_remote_collision_fails_without_renaming_built_version(self):
        self.git("tag", "v0.4.96")
        self.git("push", "origin", "refs/tags/v0.4.96")
        original = self.git("--git-dir", str(self.remote), "rev-parse", "v0.4.96").stdout
        self.git("tag", "-d", "v0.4.96")
        result = self.run_tag()
        self.assertNotEqual(result.returncode, 0, "A collision must not publish another version")
        self.assertEqual(self.remote_tags(), ["v0.4.96"])
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse", "v0.4.96").stdout, original)

    def test_local_collision_fails_without_publishing_any_tag(self):
        self.git("tag", "v0.4.96")
        result = self.run_tag()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.remote_tags(), [])

    def test_rejected_push_does_not_publish_an_alternate_version(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        result = self.run_tag()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.remote_tags(), [])

    def test_unreachable_remote_fails_before_creating_tag(self):
        self.git("remote", "set-url", "origin", str(self.root / "missing.git"))
        result = self.run_tag()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_version_mismatch_fails_before_creating_tag(self):
        result = self.run_tag(RELEASE_VERSION="0.4.97")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_wrong_commit_fails_before_creating_tag(self):
        result = self.run_tag(GITHUB_SHA="0" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_invalid_version_fails_before_creating_tag(self):
        result = self.run_tag(TAG="v0.4.96-preview", RELEASE_VERSION="0.4.96-preview")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_release_runs_share_non_cancelling_concurrency_group(self):
        source = WORKFLOW.read_text()
        self.assertRegex(source, r"(?m)^concurrency:\n  group: daypage-release-\$\{\{ github.repository \}\}\n  cancel-in-progress: false$")
        self.assertIn("          RELEASE_VERSION: ${{ steps.version.outputs.release_version }}", source)

    def test_override_is_literal_data_and_rejects_shell_code(self):
        output = self.root / "outputs"
        marker = self.root / "must-not-exist"
        env = {**self.env, "VERSION_OVERRIDE": f"$(touch {marker})",
               "GITHUB_OUTPUT": str(output)}
        result = subprocess.run(["bash", "-c", workflow_step("Compute next version")],
                                cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version_override must be", result.stdout)
        self.assertFalse(marker.exists())
        self.assertFalse(output.exists())

    def test_valid_override_is_shared_by_build_and_tag_outputs(self):
        output = self.root / "outputs"
        env = {**self.env, "VERSION_OVERRIDE": "0.4.96", "GITHUB_OUTPUT": str(output)}
        result = subprocess.run(["bash", "-c", workflow_step("Compute next version")],
                                cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text().splitlines(),
                         ["release_version=0.4.96", "release_tag=v0.4.96"])

    def test_lane_rejects_shell_code_before_invoking_fastlane(self):
        marker = self.root / "must-not-exist"
        env = {**self.env, "FASTLANE_LANE": f"beta$(touch {marker})", "RELEASE_VERSION": "0.4.96"}
        result = subprocess.run(["bash", "-c", workflow_step("Run Fastlane")],
                                cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported release lane", result.stdout)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
