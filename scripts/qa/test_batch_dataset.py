#!/usr/bin/env python3
"""Focused tests for scripts/qa/batch_dataset.py (synthetic QA dataset CLI).

Run: python3 -m unittest discover -s scripts/qa -p test_batch_dataset.py

Covers: canonical format/counts, determinism, separator-robustness bodies,
image variants (landscape/portrait/EXIF/4096), corrupt fixture isolation,
validation of changed bytes, import-vault fresh-target/overwrite/symlink/
traversal refusals, and upload-images against a localhost-only HTTP server
including malformed responses and token handling.
"""

from __future__ import annotations

import hashlib
import http.server
import importlib.util
import json
import re
import uuid
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPT = SCRIPT_DIR / "batch_dataset.py"

_spec = importlib.util.spec_from_file_location("batch_dataset", SCRIPT)
batch_dataset = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(batch_dataset)

MEMO_SEPARATOR = batch_dataset.MEMO_SEPARATOR

# Same interpreter that runs the tests (Pillow-carrying runtime).
PY = sys.executable


def run_cli(*args, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [PY, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=600,
    )
    return proc


def tree_snapshot(root: Path) -> dict[str, str]:
    return {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.rglob("*"))
        if p.is_file()
    }


def generate_into(out: Path, count: int, days: int, end_date: str, seed: int, images: int):
    proc = run_cli(
        "generate", "--output", str(out),
        "--count", str(count), "--days", str(days),
        "--end-date", end_date, "--seed", str(seed), "--images", str(images),
    )
    assert proc.returncode == 0, f"generate failed: {proc.stdout} {proc.stderr}"
    return proc


class _UploadServer:
    """Localhost-only HTTP server exercising response validation paths."""

    def __init__(self, mode: str = "ok"):
        self.mode = mode
        self.requests: list[dict] = []
        outer = self
        outer.files = {}
        outer.download_requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                outer.requests.append(
                    {
                        "path": self.path,
                        "authorization": self.headers.get("Authorization"),
                        "cookie": self.headers.get("Cookie"),
                        "content_type": self.headers.get("Content-Type", ""),
                        "body": body,
                    }
                )
                if outer.mode in ("ok", "bad-download", "cookie-required"):
                    image = body.split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n--", 1)[0]
                    original = re.search(br'filename="([^"]+)"', body).group(1).decode()
                    filename = str(uuid.UUID(int=len(outer.requests))) + ".jpg"
                    outer.files[filename] = image
                    payload, code = json.dumps({
                        "url": "/uploads/" + filename, "filename": filename,
                        "original_filename": original, "size": len(image),
                        "mime_type": "image/jpeg"
                    }).encode(), 201
                elif outer.mode == "not-json":
                    payload, code = b"<html>oops</html>", 200
                elif outer.mode == "missing-ok":
                    payload, code = b'{"id": "img-1"}', 200
                elif outer.mode == "server-error":
                    payload, code = b'{"error": "boom"}', 500
                else:  # pragma: no cover
                    raise AssertionError(f"unknown mode {outer.mode}")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                outer.download_requests.append({
                    "cookie": self.headers.get("Cookie"),
                    "authorization": self.headers.get("Authorization"),
                })
                if outer.mode == "cookie-required" and self.headers.get("Cookie") != "session=synthetic":
                    self.send_response(401)
                    self.end_headers()
                    return
                data = outer.files.get(self.path.removeprefix("/uploads/"))
                if outer.mode == "bad-download":
                    data = b"damaged image"
                self.send_response(200 if data is not None else 404)
                self.end_headers()
                self.wfile.write(data or b"")

            def log_message(self, *a):  # keep test output clean
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def endpoint(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_address[1]}/upload"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


class BatchDatasetTestBase(unittest.TestCase):
    """Shared synthetic dataset generated once per test class."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()  # outside the repo
        cls.tmp = Path(cls._tmp.name)
        cls.ds = cls.tmp / "ds"
        generate_into(cls.ds, count=10, days=4, end_date="2026-03-15", seed=7, images=8)
        cls.manifest = json.loads((cls.ds / "manifest.json").read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()


class CanonicalDatasetTests(BatchDatasetTestBase):
    """Canonical layout, counts, format and content of generate output."""

    def test_manifest_counts_match_actual_files_and_blocks(self):
        man = self.manifest
        self.assertEqual(man["counts"]["days"], 4)
        self.assertEqual(man["counts"]["memos"], 10)
        self.assertEqual(man["counts"]["images"], 8)
        self.assertEqual(man["counts"]["corrupt_fixtures"], 1)

        day_files = sorted((self.ds / "raw").glob("*.md"))
        self.assertEqual(len(day_files), 4)
        images = sorted((self.ds / "raw" / "assets").glob("*.jpg"))
        self.assertEqual(len(images), 8)

        total_blocks = 0
        for rec in man["days"]:
            content = (self.ds / rec["file"]).read_text(encoding="utf-8")
            blocks = content.split(MEMO_SEPARATOR)
            self.assertEqual(len(blocks), len(rec["memo_ids"]),
                             f"{rec['file']}: block count != manifest memo_ids")
            self.assertEqual(
                content, MEMO_SEPARATOR.join(blocks),
                "day file must be exactly the canonical separator join",
            )
            total_blocks += len(blocks)
        self.assertEqual(total_blocks, man["counts"]["memos"])
        self.assertEqual(sum(man["counts"]["memos_by_day"].values()), 10)
        self.assertEqual(sum(man["counts"]["memos_by_type"].values()), 10)

    def test_5000_validation_parses_each_memo_once_and_has_one_large_image(self):
        files, manifest = batch_dataset.build_dataset(99, 5000, 20, batch_dataset.date(2026, 10, 5), 24)
        root = self.tmp / "large-dataset"
        root.mkdir()
        for rel, data in files.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        with mock.patch.object(batch_dataset, "parse_memo_block",
                               wraps=batch_dataset.parse_memo_block) as parse:
            self.assertEqual(batch_dataset.validate_dataset(root), [])
            self.assertEqual(parse.call_count, 5000)
        self.assertEqual(sum(i["kind"] == "large_4096" for i in manifest["images"]), 1)

    def test_daily_wiki_citations_match_owning_day(self):
        for day in self.manifest["days"]:
            daily = (self.ds / "wiki/daily" / (day["date"] + ".md")).read_text()
            self.assertIn("entries_count: " + str(len(day["memo_ids"])), daily)
            cited = re.findall(r"\[\^m:([0-9A-F-]+)\]", daily)
            self.assertTrue(cited)
            self.assertTrue(set(cited) <= set(day["memo_ids"]))

    def test_symlink_dataset_root_is_refused_before_resolve(self):
        alias = self.tmp / "alias-root"
        alias.symlink_to(self.ds, target_is_directory=True)
        self.assertIn("symlink", " ".join(batch_dataset.validate_dataset(alias)))

    def test_malicious_day_date_never_reads_outside_dataset(self):
        bad = self.tmp / "malicious-date"
        shutil.copytree(self.ds, bad)
        manifest = json.loads((bad / "manifest.json").read_text())
        manifest["days"][0]["date"] = "../../../outside"
        (bad / "manifest.json").write_text(json.dumps(manifest))
        reads = []
        original = Path.read_text
        def checked(path, *args, **kwargs):
            self.assertTrue(path.resolve().is_relative_to(bad.resolve()), str(path))
            reads.append(path)
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, "read_text", checked):
            self.assertTrue(batch_dataset.validate_dataset(bad))
        self.assertTrue(reads)

    def test_recent_days_end_at_specified_end_date(self):
        dates = [r["date"] for r in self.manifest["days"]]
        self.assertEqual(
            dates,
            ["2026-03-12", "2026-03-13", "2026-03-14", "2026-03-15"],
            "days must be the most recent N days INCLUDING the specified end date",
        )
        for rec in self.manifest["days"]:
            self.assertEqual(rec["file"], f"raw/{rec['date']}.md")

    def test_blocks_match_canonical_memo_tomarkdown_bytes(self):
        """Every block parses and re-serializes to identical canonical bytes."""
        for rec in self.manifest["days"]:
            content = (self.ds / rec["file"]).read_text(encoding="utf-8")
            for i, block in enumerate(content.split(MEMO_SEPARATOR)):
                memo, reason = batch_dataset.parse_memo_block(block)
                self.assertIsNotNone(memo, f"block {i} of {rec['file']}: {reason}")
                self.assertEqual(
                    batch_dataset.memo_block_to_markdown(memo), block,
                    f"block {i} of {rec['file']} is not canonical toMarkdown bytes",
                )
                self.assertTrue(memo["id"].isupper(), "UUIDs are stored uppercase")
                self.assertRegex(memo["created"], batch_dataset.CREATED_RE)

    def test_first_block_front_matter_matches_memo_tomarkdown_shape(self):
        rec = self.manifest["days"][0]
        block = (self.ds / rec["file"]).read_text(encoding="utf-8").split(MEMO_SEPARATOR)[0]
        first = block.split("\n")
        self.assertEqual(first[0], "---")
        self.assertEqual(first[1], f"id: {rec['memo_ids'][0]}")
        self.assertRegex(first[2], r"^type: (text|photo|mixed|location)$")
        self.assertRegex(first[3], r"^created: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
        self.assertIn("---\n\n", block)

    def test_daily_files_cite_actual_memo_ids_and_cover_paths(self):
        all_ids = {m["id"] for m in self.manifest["memos"]}
        for rec in self.manifest["days"]:
            content = (self.ds / rec["file"]).read_text(encoding="utf-8")
            import re
            cited = re.findall(batch_dataset.UUID_RE, content)
            self.assertTrue(cited, f"{rec['file']} must cite memo ids")
            for c in cited:
                self.assertIn(c, all_ids, f"{rec['file']} cites unknown id {c}")
            self.assertIn(rec["cover"], content,
                          f"{rec['file']} must cite its cover path {rec['cover']}")
            self.assertTrue(
                (self.ds / rec["cover"]).is_file(),
                f"cover {rec['cover']} must exist in raw/assets",
            )

    def test_bodies_contain_mixed_cn_en_emoji_urls_headings_and_separator_looking_lines(self):
        bodies = []
        for rec in self.manifest["days"]:
            content = (self.ds / rec["file"]).read_text(encoding="utf-8")
            for block in content.split(MEMO_SEPARATOR):
                memo, _ = batch_dataset.parse_memo_block(block)
                bodies.append(memo["body"])
        joined = "\n".join(bodies)
        self.assertIn("# 主题 Heading", joined)            # headings
        self.assertIn("## 小节 Section", joined)
        self.assertIn("https://example.org/", joined)       # URLs
        self.assertTrue(any("一" <= ch <= "鿿" for ch in joined))  # CN
        self.assertIn("Deterministic", joined)              # EN
        self.assertIn("🚀", joined)                          # emoji
        # Separator-looking body lines must exist...
        self.assertIn("## 分隔线鲁棒性", joined)
        self.assertIn("\n---\n", joined)
        self.assertIn("<!-- daypage-memo-separator -->", joined)
        # ...but never as the exact separator literal inside a single block.
        for rec in self.manifest["days"]:
            content = (self.ds / rec["file"]).read_text(encoding="utf-8")
            self.assertEqual(
                content.count(MEMO_SEPARATOR),
                len(rec["memo_ids"]) - 1,
                "separator-looking body text leaked the exact separator literal",
            )

    def test_single_memo_day_files_survive_separator_looking_bodies(self):
        """Single-memo day files (no join separator) still validate round-trip."""
        ds2 = self.tmp / "ds-single"
        generate_into(ds2, count=5, days=5, end_date="2026-03-15", seed=3, images=5)
        proc = run_cli("validate", str(ds2))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # At least one single-memo day file contains the robustness block.
        found = False
        for f in sorted((ds2 / "raw").glob("*.md")):
            content = f.read_text(encoding="utf-8")
            self.assertNotIn(MEMO_SEPARATOR, content)
            if "分隔线鲁棒性" in content:
                found = True
                self.assertIn("\n---\n", content)
        self.assertTrue(found, "expected a separator-robustness body in this dataset")

    def test_deterministic_uuids_and_query_tokens(self):
        # UUIDs are pure functions of (seed, index): same seed -> same ids.
        self.assertEqual(batch_dataset.derive_uuid(7, 0), batch_dataset.derive_uuid(7, 0))
        self.assertNotEqual(batch_dataset.derive_uuid(7, 0), batch_dataset.derive_uuid(8, 0))
        for i, m in enumerate(self.manifest["memos"][:1]):
            self.assertRegex(m["id"], batch_dataset.UUID_RE)
        # expected_query_tokens are the exact memo sets that contain each token.
        id_by_token = {r["token"]: {x.upper() for x in r["memo_ids"]}
                       for r in self.manifest["expected_query_tokens"]}
        self.assertIn("qa-day-2026-03-15", id_by_token)
        for rec in self.manifest["days"]:
            content = (self.ds / rec["file"]).read_text(encoding="utf-8")
            for block in content.split(MEMO_SEPARATOR):
                memo, _ = batch_dataset.parse_memo_block(block)
                token = f"qa-token-{int(memo['body'].split('qa-token-')[1][:4]):04d}"
                self.assertIn(memo["id"].upper(), id_by_token[token])
                self.assertIn(memo["id"].upper(), id_by_token[f"qa-day-{memo['body'].split('qa-day-')[1][:10]}"])

    def test_image_variants_dimensions_and_exif_orientation(self):
        from PIL import Image

        images = self.manifest["images"]
        kinds = {r["kind"] for r in images}
        self.assertTrue({"landscape", "portrait", "large_4096"} <= kinds, kinds)
        self.assertTrue(any(k.startswith("exif_orientation_") for k in kinds), kinds)
        sizes = []
        for rec in images:
            p = self.ds / rec["file"]
            self.assertRegex(p.name, batch_dataset.ASSET_NAME_RE)
            with Image.open(p) as im:
                self.assertEqual(im.size, (rec["width"], rec["height"]))
                self.assertEqual(im.getexif().get(0x0112, 1), rec["exif_orientation"])
                im.verify()  # valid decodable JPEG
                sizes.append(im.size)
        self.assertEqual(sum(1 for w, h in sizes if max(w, h) == 4096), 1, "exactly one 4096px image")
        self.assertTrue(any(w > h for w, h in sizes), "need a landscape image")
        self.assertTrue(any(h > w for w, h in sizes), "need a portrait image")
        self.assertTrue(any(r["exif_orientation"] != 1 for r in images), "need EXIF orientation images")

    def test_photo_and_mixed_memos_carry_attachments(self):
        by_type = self.manifest["counts"]["memos_by_type"]
        self.assertGreater(by_type.get("photo", 0), 0)
        self.assertGreater(by_type.get("mixed", 0), 0)
        referenced = set()
        for m in self.manifest["memos"]:
            if m["type"] in ("photo", "mixed"):
                self.assertTrue(m["attachments"], f"{m['id']} must have photo attachments")
            for f in m["attachments"]:
                self.assertTrue(f.startswith("raw/assets/"))
                referenced.add(f)
        self.assertEqual(referenced, {r["file"] for r in self.manifest["images"]},
                         "every image is referenced by a photo/mixed memo attachment")

    def test_corrupt_fixture_is_separate_from_valid_attachments(self):
        fixtures = self.manifest["corrupt_fixtures"]
        self.assertEqual(len(fixtures), 1)
        rel = fixtures[0]["file"]
        self.assertTrue(rel.startswith("fixtures/corrupt/"), rel)
        self.assertTrue((self.ds / rel).is_file())
        # Not under raw/assets and not referenced by any memo.
        for m in self.manifest["memos"]:
            self.assertNotIn(rel, m["attachments"])
        self.assertFalse(str((self.ds / rel).resolve()).startswith(str((self.ds / "raw" / "assets").resolve())))
        from PIL import Image
        with self.assertRaises(Exception):
            with Image.open(self.ds / rel) as im:
                im.verify()


class GenerateCommandTests(BatchDatasetTestBase):
    def test_same_seed_is_byte_identical(self):
        a, b = self.tmp / "det-a", self.tmp / "det-b"
        generate_into(a, count=9, days=3, end_date="2026-03-15", seed=7, images=6)
        generate_into(b, count=9, days=3, end_date="2026-03-15", seed=7, images=6)
        self.assertEqual(tree_snapshot(a), tree_snapshot(b),
                         "same seed + args must produce byte-identical datasets")

    def test_different_seed_changes_ids_and_bytes(self):
        a, c = self.tmp / "seed-a", self.tmp / "seed-c"
        generate_into(a, count=9, days=3, end_date="2026-03-15", seed=7, images=5)
        generate_into(c, count=9, days=3, end_date="2026-03-15", seed=8, images=5)
        man_a = json.loads((a / "manifest.json").read_text(encoding="utf-8"))
        man_c = json.loads((c / "manifest.json").read_text(encoding="utf-8"))
        self.assertNotEqual([m["id"] for m in man_a["memos"]], [m["id"] for m in man_c["memos"]])

    def test_generate_refuses_existing_output(self):
        target = self.tmp / "existing"
        target.mkdir()
        (target / "keep.txt").write_text("untouched")
        proc = run_cli("generate", "--output", str(target),
                       "--count", "5", "--days", "1", "--end-date", "2026-03-15",
                       "--seed", "1", "--images", "5")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("refusing to overwrite", proc.stderr)
        self.assertEqual((target / "keep.txt").read_text(), "untouched")
        self.assertEqual(sorted(p.name for p in target.iterdir()), ["keep.txt"])

    def test_generate_refuses_invalid_params(self):
        out = self.tmp / "bad"
        for extra in (["--count", "2", "--days", "5", "--images", "24"],   # count < days
                      ["--count", "5", "--days", "5", "--images", "4"],    # images < max(5, days)
                      ["--count", "5", "--days", "0", "--images", "24"]):  # days < 1
            proc = run_cli("generate", "--output", str(out), "--end-date", "2026-03-15",
                           "--seed", "1", *extra)
            self.assertEqual(proc.returncode, 2, f"{extra}: {proc.stderr}")
            self.assertFalse(out.exists())
        proc = run_cli("generate", "--output", str(out), "--count", "5", "--days", "1",
                       "--end-date", "not-a-date", "--seed", "1", "--images", "24")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("end-date", proc.stderr)


class ValidateCommandTests(BatchDatasetTestBase):
    def _copy(self, name: str) -> Path:
        dst = self.tmp / name
        shutil.copytree(self.ds, dst)
        return dst

    def test_validate_ok_on_generated_dataset(self):
        proc = run_cli("validate", str(self.ds))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("OK", proc.stdout)

    def test_validate_detects_changed_byte(self):
        ds = self._copy("tampered")
        day = sorted((ds / "raw").glob("*.md"))[0]
        data = bytearray(day.read_bytes())
        data[data.index(b"Heading")] ^= 0x01  # flip exactly one byte
        day.write_bytes(bytes(data))
        proc = run_cli("validate", str(ds))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("hash mismatch", proc.stderr)
        self.assertIn(day.name, proc.stderr)

    def test_validate_detects_missing_asset_and_unlisted_file(self):
        ds = self._copy("tampered2")
        asset = sorted((ds / "raw" / "assets").glob("*.jpg"))[0]
        asset.unlink()
        (ds / "raw" / "extra.md").write_text("smuggled")
        proc = run_cli("validate", str(ds))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("missing", proc.stderr)
        self.assertIn("not in manifest.hashes", proc.stderr)

    def test_validate_detects_tampered_query_token_expectation(self):
        ds = self._copy("tampered3")
        man = json.loads((ds / "manifest.json").read_text(encoding="utf-8"))
        man["expected_query_tokens"][0]["memo_ids"] = ["00000000-0000-0000-0000-000000000000"]
        (ds / "manifest.json").write_text(json.dumps(man), encoding="utf-8")
        proc = run_cli("validate", str(ds))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("query token", proc.stderr)


class ImportVaultTests(BatchDatasetTestBase):
    def test_import_creates_fresh_target_with_raw_and_daily_wiki(self):
        target = self.tmp / "vault-fresh"
        proc = run_cli("import-vault", str(self.ds), "--target", str(target))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # raw tree byte-identical to the dataset's raw tree
        self.assertEqual(tree_snapshot(target / "raw"), tree_snapshot(self.ds / "raw"))
        self.assertEqual(sorted(p.name for p in target.iterdir()), ["raw", "wiki"])
        self.assertEqual(tree_snapshot(target / "wiki"), tree_snapshot(self.ds / "wiki"))
        self.assertTrue((target / "raw" / "assets").is_dir())
        # corrupt fixtures and manifest stay OUT of the vault
        self.assertFalse((target / "manifest.json").exists())
        self.assertFalse((target / "fixtures").exists())

    def test_import_never_overwrites_existing_target(self):
        target = self.tmp / "vault-existing"
        target.mkdir()
        keep = target / "user-data.md"
        keep.write_text("real user content")
        proc = run_cli("import-vault", str(self.ds), "--target", str(target))
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("never overwrite", proc.stderr)
        self.assertEqual(keep.read_text(), "real user content")
        self.assertEqual(sorted(p.name for p in target.iterdir()), ["user-data.md"])

    def test_import_refuses_symlink_inside_dataset(self):
        ds = self.tmp / "ds-symlink"
        shutil.copytree(self.ds, ds)
        asset = sorted((ds / "raw" / "assets").glob("*.jpg"))[0]
        outside = self.tmp / "outside.jpg"
        outside.write_bytes(b"\xff\xd8not-a-real-vault-file")
        asset.unlink()
        asset.symlink_to(outside)
        target = self.tmp / "vault-symlink"
        proc = run_cli("import-vault", str(ds), "--target", str(target))
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("symlink", proc.stderr.lower())
        self.assertFalse(target.exists(), "nothing may be imported from a symlinked dataset")

    def test_import_refuses_unsafe_traversal_manifest_paths(self):
        ds = self.tmp / "ds-traversal"
        shutil.copytree(self.ds, ds)
        man = json.loads((ds / "manifest.json").read_text(encoding="utf-8"))
        man["hashes"]["raw/../../escaped.md"] = "0" * 64
        (ds / "manifest.json").write_text(json.dumps(man), encoding="utf-8")
        target = self.tmp / "vault-traversal"
        proc = run_cli("import-vault", str(ds), "--target", str(target))
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("unsafe", proc.stderr)
        self.assertFalse(target.exists())
        self.assertFalse((self.tmp / "escaped.md").exists())
        self.assertFalse((ds.parent / "escaped.md").exists())


class UploadImagesTests(BatchDatasetTestBase):
    TOKEN = "test-token-abc123"

    def _upload(self, server_mode: str, *, endpoint=None, env_token=TOKEN, extra_args=()):
        with _UploadServer(server_mode) as server:
            env = {}
            if env_token is not None:
                env["QA_UPLOAD_TOKEN"] = env_token
            else:
                env["QA_UPLOAD_TOKEN"] = ""
            proc = run_cli(
                "upload-images", str(self.ds),
                "--endpoint", endpoint or server.endpoint,
                "--token-env", "QA_UPLOAD_TOKEN",
                *extra_args,
                env_extra=env,
            )
            return proc, server

    def test_upload_success_posts_real_requests_and_hides_token(self):
        proc, server = self._upload("ok")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        images = self.manifest["images"]
        self.assertEqual(len(server.requests), len(images), "one real request per image")
        for i, req in enumerate(server.requests):
            self.assertEqual(req["authorization"], f"Bearer {self.TOKEN}")
            self.assertIn("multipart/form-data; boundary=", req["content_type"])
            self.assertIn(b"\xff\xd8", req["body"], "JPEG bytes must be posted")
            self.assertEqual(req["path"], "/upload")
        self.assertIn(f"all {len(images)} image(s) uploaded", proc.stdout)
        combined = proc.stdout + proc.stderr
        self.assertNotIn(self.TOKEN, combined, "token must never be printed")

    def test_cookie_auth_and_download_hash_receipt(self):
        report = self.tmp / "cookie-receipt.json"
        with _UploadServer("cookie-required") as server:
            proc = run_cli("upload-images", str(self.ds), "--endpoint", server.endpoint,
                           "--cookie-env", "QA_COOKIE", "--report", str(report),
                           env_extra={"QA_COOKIE": "session=synthetic"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(all(r["cookie"] == "session=synthetic" for r in server.requests))
        self.assertEqual(len(server.download_requests), len(self.manifest["images"]))
        self.assertTrue(all(r["cookie"] == "session=synthetic" for r in server.download_requests))
        receipt = json.loads(report.read_text())
        self.assertEqual(receipt["verified"], len(self.manifest["images"]))
        for row in receipt["receipts"]:
            self.assertEqual(row["sha256"], self.manifest["hashes"][row["file"]])
        self.assertNotIn("session=synthetic", report.read_text() + proc.stdout + proc.stderr)

    def test_uploaded_success_with_different_downloaded_bytes_fails(self):
        proc, server = self._upload("bad-download")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("downloaded bytes differ", proc.stdout)

    def test_upload_fails_on_non_json_response(self):
        proc, server = self._upload("not-json")
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("FAIL", proc.stdout)
        self.assertIn("not valid JSON", proc.stdout)
        self.assertNotIn("all ", proc.stdout)

    def test_upload_fails_on_response_missing_ok(self):
        proc, server = self._upload("missing-ok")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not a success object", proc.stdout)

    def test_upload_fails_on_http_error_status(self):
        proc, server = self._upload("server-error")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("HTTP 500", proc.stdout)
        self.assertIn("FAILED", proc.stderr)

    def test_upload_requires_token_env(self):
        proc, server = self._upload("ok", env_token=None)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("QA_UPLOAD_TOKEN", proc.stderr)
        self.assertEqual(server.requests, [], "no request may be sent without a token")

    def test_upload_refuses_remote_host_without_explicit_flag(self):
        proc, server = self._upload("ok", endpoint="http://example.invalid/upload")
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("--allow-remote-host", proc.stderr)
        self.assertEqual(server.requests, [], "no request may be sent to a refused host")

    def test_upload_validates_dataset_first(self):
        ds = self.tmp / "ds-broken-upload"
        shutil.copytree(self.ds, ds)
        day = sorted((ds / "raw").glob("*.md"))[0]
        day.write_bytes(day.read_bytes() + b"\nsmuggled")
        with _UploadServer("ok") as server:
            proc = run_cli(
                "upload-images", str(ds),
                "--endpoint", server.endpoint,
                "--token-env", "QA_UPLOAD_TOKEN",
                env_extra={"QA_UPLOAD_TOKEN": self.TOKEN},
            )
            self.assertEqual(proc.returncode, 2, proc.stderr)
            self.assertEqual(server.requests, [], "invalid datasets must not be uploaded")


if __name__ == "__main__":
    unittest.main()
