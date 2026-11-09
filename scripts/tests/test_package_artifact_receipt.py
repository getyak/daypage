#!/usr/bin/env python3
"""Exercise cache readback refusal using isolated inert package files."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('artifact_receipt', Path(__file__).resolve().parents[1] / 'ci/verify_package_artifacts.py')
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class PackageArtifactReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache, self.sources = self.root / 'cache', self.root / 'sources'
        artifacts = self.cache / 'artifacts'
        artifacts.mkdir(parents=True)
        self.archive = artifacts / 'https_github_com_getsentry_sentry_cocoa_1_2_3_Sentry_zip'
        self.archive.write_bytes(b'inert binary fixture')
        checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.checkout = self.sources / 'checkouts/sentry-cocoa'
        self.checkout.mkdir(parents=True)
        (self.checkout / 'Package.swift').write_text('.binaryTarget(name: "Sentry", url: "https://github.com/getsentry/sentry-cocoa/releases/download/1.2.3/Sentry.zip", checksum: "' + checksum + '")')
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.checkout), *args], stderr=subprocess.DEVNULL, text=True).strip()
        git('init', '-q')
        git('add', 'Package.swift')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'Fixture')
        self.resolved = self.root / 'Package.resolved'
        self.resolved.write_text(json.dumps({'pins': [{'identity': 'sentry-cocoa', 'state': {'revision': git('rev-parse', 'HEAD'), 'version': '1.2.3'}}]}))
        self.extracted = self.sources / 'artifacts/sentry-cocoa/Sentry.xcframework'
        self.extracted.mkdir(parents=True)
        self.write_state(self.extracted)

    def write_state(self, path):
        (self.sources / 'workspace-state.json').write_text(json.dumps({'object': {'artifacts': [{'packageRef': {'identity': 'sentry-cocoa'}, 'targetName': 'Sentry', 'path': str(path)}]}}))

    def inspect(self):
        return receipt.inspect_cache(self.cache, self.sources, self.resolved)

    def test_accepts_verified_cache_and_existing_extraction(self):
        result = self.inspect()
        self.assertEqual(result['archives'][0]['target'], 'Sentry')
        self.assertEqual(result['managedArtifacts'][0]['realPath'], str(self.extracted.resolve()))

    def test_empty_cache_cannot_be_success(self):
        self.archive.unlink()
        with self.assertRaisesRegex(ValueError, 'No verified'):
            self.inspect()

    def test_changed_archive_is_rejected(self):
        self.archive.write_bytes(b'changed fixture')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.inspect()

    def test_archive_symlink_cannot_escape_cache(self):
        outside = self.root / 'outside'
        self.archive.rename(outside)
        self.archive.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            self.inspect()

    def test_uncommitted_manifest_cannot_authorize_an_archive(self):
        with (self.checkout / 'Package.swift').open('a') as stream:
            stream.write('\n// changed')
        with self.assertRaisesRegex(ValueError, 'uncommitted'):
            self.inspect()

    def test_extracted_artifact_cannot_escape_sources(self):
        self.write_state(self.root)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            self.inspect()


if __name__ == '__main__':
    unittest.main()
