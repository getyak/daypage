#!/usr/bin/env python3
"""Tests for scripts/import_flomo.py — one-time flomo export → DayPage vault import.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p 'test_import_flomo.py' -v

All fixtures are tiny synthetic ZIPs generated in-test; no personal export data is
ever read. The fixture shape recreates the known observed export: a root folder,
one UTF-8 HTML file, ``.memo`` divs with ``.time``/``.content``/``.files``, media
referenced by relative paths (png/jpeg, mov via ``img``, m4a/aac via ``audio``).
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS_DIR.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import import_flomo  # noqa: E402


# --------------------------------------------------------------------------
# Synthetic fixture helpers
# --------------------------------------------------------------------------

PNG = b"\x89PNG\r\n\x1a\n" + b"synthetic-png-bytes"
JPEG = b"\xff\xd8\xff\xe0" + b"synthetic-jpeg-bytes"
MOV = b"\x00\x00\x00\x18ftypmp42" + b"synthetic-mov-bytes"
M4A = b"\x00\x00\x00\x18ftypM4A " + b"synthetic-m4a-bytes"
AAC = b"\xff\xf1" + b"synthetic-aac-bytes"


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def memo_div(time: str, content: str = "", files: str = "", extra: str = "") -> str:
    parts = [f'<div class="time">{time}</div>']
    if content:
        parts.append(f'<div class="content">{content}</div>')
    if files:
        parts.append(f'<div class="files">{files}</div>')
    if extra:
        parts.append(extra)
    return '<div class="memo">' + "".join(parts) + "</div>"


def export_html(memos: list[str], extra_body: str = "") -> str:
    return (
        '<!DOCTYPE html><html><head><title>flomo export</title>'
        '<style>.time { color: #999; }</style></head><body>'
        + extra_body
        + "".join(memos)
        + "</body></html>"
    )


def make_zip(path: Path, *, root: str = "flomo-export", html_name: str = "flomo-export.html",
             html: str | None = None, media: dict[str, bytes] | None = None) -> Path:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        if html is not None:
            zf.writestr(f"{root}/{html_name}", html.encode("utf-8"))
        for name, data in (media or {}).items():
            zf.writestr(f"{root}/{name}", data)
    return path


def write_raw_zip(path: Path, entries: list[tuple[str, bytes, int | None]]) -> Path:
    """Write a ZIP with explicit names and optional unix mode (for symlink tests)."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name)
            info.external_attr = ((mode if mode is not None else 0o644) << 16)
            zf.writestr(info, data)
    return path


class ImportFlomoTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def dest(self) -> Path:
        return self.tmp / "staging"

    def write_day(self, export, destination=None):
        summary = import_flomo.write_vault(export, destination or self.dest())
        return summary


# --------------------------------------------------------------------------
# Content fidelity
# --------------------------------------------------------------------------

class ContentFidelityTests(ImportFlomoTestBase):
    def test_native_edge_whitespace_adapted_and_interior_preserved(self):
        source = make_zip(self.tmp / 'edge.zip', html=export_html([
            memo_div('2023-05-01 12:34:56', '<p>\u200binside\u200btext\u200b</p>')]))
        export = import_flomo.parse_export(source)
        self.assertEqual(export.memos[0].body, 'inside\u200btext')
        self.assertEqual(export.adaptations['native_edge_whitespace'], 2)

    def test_zero_width_only_body_uses_media_only_type(self):
        for extension, element, data, expected in [('m4a', 'audio', M4A, 'voice'),
                                                    ('png', 'img', PNG, 'photo')]:
            with self.subTest(kind=expected):
                source = make_zip(self.tmp / 'media-edge.zip', html=export_html([
                    memo_div('2023-05-01 12:34:56', '<p>\u200b</p>',
                             files=f'<{element} src="files/a.{extension}"></{element}>')]),
                    media={f'files/a.{extension}': data})
                export = import_flomo.parse_export(source)
                self.assertEqual(export.memos[0].type, expected)
                self.assertIn('attachment:', export.memos[0].body)

    def test_paragraph_cjk_emoji_fidelity(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>你好，世界！🎉 第二段前。</p><p>second &amp; last ✅</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].body, "你好，世界！🎉 第二段前。\n\nsecond & last ✅")

    def test_bold_underline_highlight_no_raw_html(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p><strong>粗体</strong>和<u>下划线</u>还有<mark>高亮</mark></p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        # Native MemoMarkdown has no underline/highlight markers; their text is
        # retained as supported strong emphasis (adaptations recorded), never
        # leaked as literal __x__ / ==x== marker syntax.
        self.assertEqual(body, "**粗体**和**下划线**还有**高亮**")
        self.assertNotIn("__", body)
        self.assertNotIn("==", body)
        for fragment in ("<strong>", "</strong>", "<u>", "<mark>", "<script"):
            self.assertNotIn(fragment, body)

    def test_softbreak_preserved_and_whitespace_collapsed(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>line one\nline two</p><p>hello   world</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "line one\nline two\n\nhello world")

    def test_br_becomes_newline(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>hard<br>break<br>again</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "hard\nbreak\nagain")

    def test_ordered_list_start_seven(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<ol start="7"><li>seven</li><li>eight</li><li>nine</li></ol>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "7. seven\n8. eight\n9. nine")

    def test_ordered_list_data_digits_padding(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<ol start="5" data-digits="2"><li>a</li><li>b</li></ol>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "05. a\n06. b")

    def test_nested_lists_preserved(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<ul><li>alpha<ol start="3"><li>one</li><li>two<ul><li>deep</li></ul></li></ol></li>'
            "<li>beta</li></ul>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(
            body,
            "- alpha\n    3. one\n    4. two\n        - deep\n- beta",
        )

    def test_softbreak_inside_list_item(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<ol start="1"><li>first line\nsecond line</li><li>next</li></ol>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "1. first line\n   second line\n2. next")


# --------------------------------------------------------------------------
# Tags
# --------------------------------------------------------------------------

class TagTests(ImportFlomoTestBase):
    def build(self) -> Path:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>morning #parent/child #C++ #标签 #emoji🎉 ok</p>",
        )])
        return make_zip(self.tmp / "e.zip", html=html)

    def test_tags_kept_verbatim_in_body_and_indexed(self) -> None:
        zp = self.build()
        export = import_flomo.parse_export(zp)
        body = export.memos[0].body
        for tag in ("#parent/child", "#C++", "#标签", "#emoji🎉"):
            self.assertIn(tag, body)
        self.assertEqual(
            set(export.memos[0].tags),
            {"#C++", "#parent/child", "#标签", "#emoji🎉"},
        )
        summary = self.write_day(export)
        manifest = json.loads((self.dest() / "flomo-import-manifest.json").read_text())
        self.assertEqual(
            manifest["tag_index"],
            {"#parent/child": 1, "#C++": 1, "#标签": 1, "#emoji🎉": 1},
        )
        self.assertEqual(summary.unique_tag_count, 4)

    def test_tag_index_counts_duplicates(self) -> None:
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>#a #a #b</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        summary = self.write_day(export)
        manifest = json.loads((self.dest() / "flomo-import-manifest.json").read_text())
        self.assertEqual(manifest["tag_index"], {"#a": 2, "#b": 1})
        self.assertEqual(summary.unique_tag_count, 2)

    def test_non_tag_tokens_not_indexed(self) -> None:
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>plain words no tag</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].tags, ())


# --------------------------------------------------------------------------
# Timezone / local calendar day
# --------------------------------------------------------------------------

class TimezoneTests(ImportFlomoTestBase):
    def test_local_day_filename_not_utc_day(self) -> None:
        html = export_html([memo_div("2023-05-01 00:30:00", "<p>late note</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)  # default Asia/Shanghai
        memo = export.memos[0]
        self.assertEqual(memo.created.isoformat(timespec="milliseconds"),
                         "2023-05-01T00:30:00.000+08:00")
        # The UTC instant falls on the previous calendar day; the file must not.
        self.assertEqual(memo.created.utctimetuple()[:3], (2023, 4, 30))
        self.write_day(export)
        self.assertTrue((self.dest() / "vault/raw/2023-05-01.md").is_file())
        self.assertFalse((self.dest() / "vault/raw/2023-04-30.md").exists())

    def test_end_of_day_stays_on_local_day(self) -> None:
        html = export_html([memo_div("2023-04-30 23:59:59", "<p>end</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.write_day(export)
        self.assertTrue((self.dest() / "vault/raw/2023-04-30.md").is_file())
        self.assertEqual(export.memos[0].created.isoformat(timespec="milliseconds"),
                         "2023-04-30T23:59:59.000+08:00")

    def test_utc_timezone_option(self) -> None:
        html = export_html([memo_div("2023-05-01 00:30:00", "<p>utc note</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp, timezone="UTC")
        self.assertEqual(export.memos[0].created.isoformat(timespec="milliseconds"),
                         "2023-05-01T00:30:00.000+00:00")
        self.write_day(export)
        self.assertTrue((self.dest() / "vault/raw/2023-05-01.md").is_file())

    def test_invalid_timezone_fails_closed(self) -> None:
        html = export_html([memo_div("2023-05-01 00:30:00", "<p>x</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp, timezone="Mars/Phobos")

    def test_two_days_two_day_files(self) -> None:
        html = export_html([
            memo_div("2023-05-01 08:00:00", "<p>day one</p>"),
            memo_div("2023-05-02 09:00:00", "<p>day two</p>"),
        ])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        summary = self.write_day(export)
        self.assertEqual(summary.day_count, 2)
        self.assertTrue((self.dest() / "vault/raw/2023-05-01.md").is_file())
        self.assertTrue((self.dest() / "vault/raw/2023-05-02.md").is_file())


# --------------------------------------------------------------------------
# Media
# --------------------------------------------------------------------------

class MediaTests(ImportFlomoTestBase):
    def test_media_bytes_copied_with_sha256_name_and_manifest(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>with photo</p>",
            files='<img src="files/photo1.png">',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/photo1.png": PNG})
        export = import_flomo.parse_export(zp)
        summary = self.write_day(export)
        digest = sha256_hex(PNG)
        asset = self.dest() / f"vault/raw/assets/flomo/{digest}.png"
        self.assertEqual(asset.read_bytes(), PNG)
        self.assertEqual(summary.attachment_counts, {"photo": 1, "audio": 0, "file": 0})
        manifest = json.loads((self.dest() / "flomo-import-manifest.json").read_text())
        self.assertEqual(manifest["attachments"], [{
            "file": f"raw/assets/flomo/{digest}.png",
            "kind": "photo",
            "original_filename": "photo1.png",
            "sha256": digest,
            "size": len(PNG),
            "unsupported_cloud_media": False,
        }])

    def test_jpeg_photo_kind(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "",
            files='<img src="files/pic.jpg">',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/pic.jpg": JPEG})
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].attachments[0].kind, "photo")
        self.assertEqual(export.memos[0].attachments[0].original_filename, "pic.jpg")

    def test_img_pointing_to_mov_is_file_attachment_never_image(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "",
            files='<img src="files/clip.mov">',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/clip.mov": MOV})
        export = import_flomo.parse_export(zp)
        att = export.memos[0].attachments[0]
        self.assertEqual(att.kind, "file")  # never "photo"
        summary = self.write_day(export)
        manifest = json.loads((self.dest() / "flomo-import-manifest.json").read_text())
        # Reported as unsupported-cloud-media, not silently dropped or converted.
        self.assertEqual(manifest["unsupported_cloud_media"], {"mov": 1})
        self.assertEqual(summary.unsupported_cloud_media_counts, {"mov": 1})
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        self.assertNotIn("![", day)  # no image embed for mov
        self.assertIn(f'[File attachment: clip.mov]({att.file})', day)

    def test_aac_audio_stays_audio_and_is_reported(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "",
            files='<audio src="files/voice.aac"></audio>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/voice.aac": AAC})
        export = import_flomo.parse_export(zp)
        att = export.memos[0].attachments[0]
        self.assertEqual(att.kind, "audio")
        self.assertIsNone(att.transcription_status)  # never fake an ASR queue job
        summary = self.write_day(export)
        self.assertEqual(summary.unsupported_cloud_media_counts, {"aac": 1})
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        self.assertIn("kind: audio", day)
        self.assertNotIn("transcription_status", day)  # omitted when no transcript
        self.assertNotIn("pending", day)

    def test_m4a_audio_not_flagged_unsupported(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "",
            files='<audio src="files/voice.m4a"></audio>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/voice.m4a": M4A})
        export = import_flomo.parse_export(zp)
        summary = self.write_day(export)
        self.assertEqual(summary.unsupported_cloud_media_counts, {})

    def test_media_only_note_gets_descriptive_links(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "",
            files='<img src="files/photo1.png"><audio src="files/voice.m4a"></audio>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html,
                      media={"files/photo1.png": PNG, "files/voice.m4a": M4A})
        export = import_flomo.parse_export(zp)
        memo = export.memos[0]
        self.assertEqual(memo.type, "mixed")
        photo_sha = sha256_hex(PNG)
        audio_sha = sha256_hex(M4A)
        self.assertEqual(memo.body, (
            f"[Photo attachment: photo1.png](raw/assets/flomo/{photo_sha}.png)\n"
            f"[Audio attachment: voice.m4a](raw/assets/flomo/{audio_sha}.m4a)"
        ))
        self.write_day(export)
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        self.assertIn("Photo attachment: photo1.png", day)

    def test_type_classification(self) -> None:
        html = export_html([
            memo_div("2023-05-01 08:00:00", "<p>text only</p>"),
            memo_div("2023-05-01 08:01:00", "", files='<audio src="files/a.m4a"></audio>'),
            memo_div("2023-05-01 08:02:00", "", files='<img src="files/p.png">'),
            memo_div("2023-05-01 08:03:00", "<p>with media</p>",
                     files='<img src="files/p.png">'),
        ])
        zp = make_zip(self.tmp / "e.zip", html=html,
                      media={"files/a.m4a": M4A, "files/p.png": PNG})
        export = import_flomo.parse_export(zp)
        self.assertEqual([m.type for m in export.memos],
                         ["text", "voice", "photo", "mixed"])
        summary = self.write_day(export)
        self.assertEqual(summary.type_counts,
                         {"text": 1, "voice": 1, "photo": 1, "mixed": 1})


# --------------------------------------------------------------------------
# Frontmatter / vault format contract
# --------------------------------------------------------------------------

class VaultFormatTests(ImportFlomoTestBase):
    def test_frontmatter_contract(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>body here</p>",
            files='<img src="files/photo1.png"><audio src="files/voice.m4a"></audio>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html,
                      media={"files/photo1.png": PNG, "files/voice.m4a": M4A})
        export = import_flomo.parse_export(zp)
        memo = export.memos[0]
        self.write_day(export)
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        front = day.split("---\n", 2)[1]
        self.assertIn(f"id: {memo.id}\n", front)
        self.assertIn("type: mixed\n", front)
        self.assertRegex(front, r"created: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}\n")
        self.assertIn('device: "flomo import"\n', front)
        self.assertIn("entity_mentions: []\n", front)
        self.assertNotIn("entity_mentions:\n  -", front)  # hashtags are not AI entities
        photo_sha = sha256_hex(PNG)
        m4a_sha = sha256_hex(M4A)
        self.assertIn(f'- file: "raw/assets/flomo/{photo_sha}.png"\n', front)
        self.assertIn("    kind: photo\n", front)
        self.assertIn(f'- file: "raw/assets/flomo/{m4a_sha}.m4a"\n', front)
        self.assertIn("    kind: audio\n", front)
        self.assertNotIn("transcription_status", front)  # nil without a transcript
        self.assertTrue(day.endswith("---\n\nbody here\n"))

    def test_memo_separator_between_memos(self) -> None:
        html = export_html([
            memo_div("2023-05-01 08:00:00", "<p>first</p>"),
            memo_div("2023-05-01 09:00:00", "<p>second</p>"),
        ])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.write_day(export)
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        self.assertEqual(
            day.count("\n\n<!-- daypage-memo-separator -->\n\n"), 1)
        self.assertLess(day.index("first"), day.index("second"))
        self.assertIn("id: ", day.split("<!-- daypage-memo-separator -->")[1])

    def test_id_is_uuid_and_stable(self) -> None:
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>stable</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        first = import_flomo.parse_export(zp).memos[0].id
        second = import_flomo.parse_export(zp).memos[0].id
        self.assertEqual(first, second)
        self.assertEqual(str(uuid.UUID(first)), first)  # valid canonical UUID


# --------------------------------------------------------------------------
# Duplicates and idempotent retry
# --------------------------------------------------------------------------

class DuplicateTests(ImportFlomoTestBase):
    def dup_html(self) -> str:
        return export_html([
            memo_div("2023-05-01 12:34:56", "<p>same</p>", files='<img src="files/p.png">'),
            memo_div("2023-05-01 12:34:56", "<p>same</p>", files='<img src="files/p.png">'),
        ])

    def test_identical_duplicates_all_preserved_with_distinct_ids(self) -> None:
        zp = make_zip(self.tmp / "e.zip", html=self.dup_html(),
                      media={"files/p.png": PNG})
        export = import_flomo.parse_export(zp)
        self.assertEqual(len(export.memos), 2)
        self.assertNotEqual(export.memos[0].id, export.memos[1].id)
        summary = self.write_day(export)
        self.assertEqual(summary.memo_count, 2)
        self.assertEqual(summary.duplicate_memo_count, 1)
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        self.assertEqual(day.count("\n\n<!-- daypage-memo-separator -->\n\n"), 1)
        self.assertEqual(day.count("id: "), 2)

    def test_ids_independent_of_root_folder_and_nonduplicate_order(self) -> None:
        a_html = export_html([
            memo_div("2023-05-01 12:34:56", "<p>same</p>"),
            memo_div("2023-05-01 12:34:56", "<p>same</p>"),
            memo_div("2023-05-01 10:00:00", "<p>other</p>"),
        ])
        b_html = export_html([
            memo_div("2023-05-01 10:00:00", "<p>other</p>"),
            memo_div("2023-05-01 12:34:56", "<p>same</p>"),
            memo_div("2023-05-01 12:34:56", "<p>same</p>"),
        ])
        zp_a = make_zip(self.tmp / "a.zip", root="flomo-export", html=a_html)
        zp_b = make_zip(self.tmp / "b.zip", root="zz-other-root", html=b_html)
        ids_a = sorted(m.id for m in import_flomo.parse_export(zp_a).memos)
        ids_b = sorted(m.id for m in import_flomo.parse_export(zp_b).memos)
        self.assertEqual(ids_a, ids_b)

    def test_retry_is_idempotent_no_duplication(self) -> None:
        zp = make_zip(self.tmp / "e.zip", html=self.dup_html(),
                      media={"files/p.png": PNG})
        summary1 = self.write_day(import_flomo.parse_export(zp))
        day_path = self.dest() / "vault/raw/2023-05-01.md"
        first_bytes = day_path.read_bytes()
        manifest_bytes = (self.dest() / "flomo-import-manifest.json").read_bytes()
        summary2 = self.write_day(import_flomo.parse_export(zp))
        self.assertEqual(summary2.memo_count, summary1.memo_count)
        self.assertEqual(summary2.files_written, 0)
        self.assertEqual(summary2.files_unchanged, summary1.files_written)
        self.assertEqual(day_path.read_bytes(), first_bytes)
        self.assertEqual(first_bytes.count(b"daypage-memo-separator"), 1)
        self.assertEqual(
            (self.dest() / "flomo-import-manifest.json").read_bytes(), manifest_bytes)

    def test_retry_recovers_missing_file_without_touching_unchanged(self) -> None:
        zp = make_zip(self.tmp / "e.zip", html=self.dup_html(),
                      media={"files/p.png": PNG})
        self.write_day(import_flomo.parse_export(zp))
        asset = self.dest() / f"vault/raw/assets/flomo/{sha256_hex(PNG)}.png"
        asset.unlink()
        summary = self.write_day(import_flomo.parse_export(zp))
        self.assertEqual(summary.files_written, 1)
        self.assertEqual(asset.read_bytes(), PNG)

    def test_retry_with_tampered_file_fails_closed(self) -> None:
        zp = make_zip(self.tmp / "e.zip", html=self.dup_html(),
                      media={"files/p.png": PNG})
        self.write_day(import_flomo.parse_export(zp))
        day_path = self.dest() / "vault/raw/2023-05-01.md"
        tampered = b"---\nid: hacked\n---\n\noverwritten\n"
        day_path.write_bytes(tampered)
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(zp))
        self.assertEqual(day_path.read_bytes(), tampered)  # not overwritten


# --------------------------------------------------------------------------
# Destination ownership / conflicts
# --------------------------------------------------------------------------

class DestinationTests(ImportFlomoTestBase):
    def simple_zip(self) -> Path:
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>mine</p>")])
        return make_zip(self.tmp / "e.zip", html=html)

    def test_refuses_arbitrary_existing_vault(self) -> None:
        dest = self.dest()
        (dest / "vault/raw").mkdir(parents=True)
        existing = dest / "vault/raw/2020-01-01.md"
        existing.write_text("---\nid: user\n---\n\npersonal\n")
        zp = self.simple_zip()
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(zp), dest)
        self.assertEqual(existing.read_text(), "---\nid: user\n---\n\npersonal\n")
        self.assertFalse((dest / "flomo-import-manifest.json").exists())

    def test_refuses_nonempty_unowned_directory(self) -> None:
        dest = self.dest()
        dest.mkdir()
        (dest / "unrelated.txt").write_text("data")
        zp = self.simple_zip()
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(zp), dest)
        self.assertEqual((dest / "unrelated.txt").read_text(), "data")

    def test_empty_existing_directory_is_acceptable_staging(self) -> None:
        dest = self.dest()
        dest.mkdir()
        summary = self.write_day(import_flomo.parse_export(self.simple_zip()), dest)
        self.assertEqual(summary.memo_count, 1)

    def test_refuses_destination_that_is_a_file(self) -> None:
        dest = self.dest()
        dest.write_text("not a directory")
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(self.simple_zip()), dest)

    def test_conflicting_import_manifest_fails_closed(self) -> None:
        zp1 = self.simple_zip()
        self.write_day(import_flomo.parse_export(zp1))
        day_path = self.dest() / "vault/raw/2023-05-01.md"
        first_bytes = day_path.read_bytes()
        html2 = export_html([memo_div("2023-05-01 12:34:56", "<p>different</p>")])
        zp2 = make_zip(self.tmp / "other.zip", html=html2)
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(zp2))
        self.assertEqual(day_path.read_bytes(), first_bytes)

    def test_dry_run_writes_nothing(self) -> None:
        dest = self.dest()
        zp = make_zip(self.tmp / "e.zip", html=export_html([memo_div(
            "2023-05-01 12:34:56", "<p>x</p>", files='<img src="files/p.png">')]),
            media={"files/p.png": PNG})
        summary = import_flomo.write_vault(import_flomo.parse_export(zp), dest,
                                           dry_run=True)
        self.assertTrue(summary.dry_run)
        self.assertEqual(summary.files_written, 0)
        self.assertEqual(summary.memo_count, 1)
        self.assertFalse(dest.exists())

    def test_dry_run_validates_destination_conflicts(self) -> None:
        dest = self.dest()
        dest.mkdir()
        (dest / "unrelated.txt").write_text("data")
        zp = self.simple_zip()
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.write_vault(import_flomo.parse_export(zp), dest, dry_run=True)
        self.assertEqual((dest / "unrelated.txt").read_text(), "data")


# --------------------------------------------------------------------------
# Security: malicious ZIPs and HTML
# --------------------------------------------------------------------------

class ZipSecurityTests(ImportFlomoTestBase):
    GOOD_HTML = export_html([memo_div("2023-05-01 12:34:56", "<p>ok</p>")])

    def test_zip_slip_and_bad_names_rejected(self) -> None:
        bad_names = [
            "../evil.txt",
            "flomo/../../evil.txt",
            "/etc/passwd",
            "flomo/%2e%2e/evil.png",
            "%2e%2e/evil",
            "flomo/files/..%2f..%2fevil",
            "C:\\evil.png",
            "flomo\\..\\evil.png",
        ]
        for bad in bad_names:
            with self.subTest(name=bad):
                zp = write_raw_zip(self.tmp / "bad.zip", [
                    ("flomo/flomo-export.html", self.GOOD_HTML.encode("utf-8"), None),
                    (bad, b"evil", None),
                ])
                with self.assertRaises(import_flomo.FlomoImportError):
                    import_flomo.parse_export(zp)

    def test_absolute_percent_encoded_traversal_in_media_ref_rejected(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "",
            files='<img src="files/%2e%2e/%2e%2e/evil.png">')])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_symlink_entry_rejected(self) -> None:
        zp = write_raw_zip(self.tmp / "bad.zip", [
            ("flomo/flomo-export.html", self.GOOD_HTML.encode("utf-8"), None),
            ("flomo/files/link.png", b"/etc/passwd", 0o120777),
        ])
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_conflicting_normalized_paths_rejected(self) -> None:
        zp = write_raw_zip(self.tmp / "bad.zip", [
            ("flomo/flomo-export.html", self.GOOD_HTML.encode("utf-8"), None),
            ("flomo/files/a.png", PNG, None),
            ("flomo/files/./a.png", b"other-bytes", None),
        ])
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_zip_expansion_bounded(self) -> None:
        zp = make_zip(self.tmp / "e.zip", html=export_html([
            memo_div("2023-05-01 12:34:56", "<p>a</p>"),
        ]), media={"files/a.png": PNG, "files/b.png": PNG, "files/c.png": PNG})
        with mock.patch.object(import_flomo, "MAX_ZIP_ENTRIES", 2):
            with self.assertRaises(import_flomo.FlomoImportError):
                import_flomo.parse_export(zp)
        with mock.patch.object(import_flomo, "MAX_TOTAL_BYTES", 10):
            with self.assertRaises(import_flomo.FlomoImportError):
                import_flomo.parse_export(zp)


class HtmlSecurityTests(ImportFlomoTestBase):
    def test_external_and_unsafe_media_refs_rejected(self) -> None:
        unsafe_refs = [
            "https://evil.example/x.png",
            "http://evil.example/x.png",
            "//evil.example/x.png",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:image/png;base64,AAAA",
            "../outside.png",
            "/abs/path.png",
        ]
        for ref in unsafe_refs:
            with self.subTest(ref=ref):
                html = export_html([memo_div(
                    "2023-05-01 12:34:56", "", files=f'<img src="{ref}">')])
                zp = make_zip(self.tmp / "e.zip", html=html)
                with self.assertRaises(import_flomo.FlomoImportError):
                    import_flomo.parse_export(zp)

    def test_missing_media_file_rejected(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "", files='<img src="files/missing.png">')])
        zp = make_zip(self.tmp / "e.zip", html=html)  # no media entries
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_unknown_media_extension_rejected(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "", files='<img src="files/x.webm">')])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/x.webm": b"data"})
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_export_chrome_ignored_and_never_in_output(self) -> None:
        extra = (
            "<script>alert('pwned')</script>"
            "<style>.x { content: 'styled'; }</style>"
            "<button>chrome-button</button>"
            "<svg><use href=\"#glyph\"></use></svg>"
        )
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>real note</p>", extra=extra)])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].body, "real note")
        self.write_day(export)
        for path in [self.dest() / "vault/raw/2023-05-01.md",
                     self.dest() / "flomo-import-manifest.json"]:
            text = path.read_text()
            for fragment in ("alert", "pwned", "styled", "chrome-button", "glyph"):
                self.assertNotIn(fragment, text)

    def test_media_outside_files_div_rejected(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<p>x<img src="files/p.png"></p>')])
        zp = make_zip(self.tmp / "e.zip", html=html, media={"files/p.png": PNG})
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)


class UnsupportedInputTests(ImportFlomoTestBase):
    def test_no_html_entry_fails_closed(self) -> None:
        zp = make_zip(self.tmp / "e.zip", media={"files/a.png": PNG})
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_two_html_entries_fail_closed(self) -> None:
        zp = self.tmp / "e.zip"
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>x</p>")])
        with zipfile.ZipFile(zp, "w") as zf:
            zf.writestr("flomo/a.html", html)
            zf.writestr("flomo/b.html", html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_no_memos_fails_closed(self) -> None:
        zp = make_zip(self.tmp / "e.zip",
                      html="<!DOCTYPE html><html><body></body></html>")
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_non_utf8_html_fails_closed(self) -> None:
        zp = write_raw_zip(self.tmp / "e.zip", [
            ("flomo/flomo-export.html", b"\xff\xfe<html></html>", None)])
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_bad_time_format_fails_closed(self) -> None:
        html = export_html([memo_div("May 1 2023", "<p>x</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_missing_time_div_fails_closed(self) -> None:
        html = export_html(['<div class="memo"><div class="content"><p>x</p></div></div>'])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_non_zip_input_fails_closed(self) -> None:
        zp = self.tmp / "e.zip"
        zp.write_bytes(b"this is not a zip")
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

class CliTests(ImportFlomoTestBase):
    def build_zip(self) -> Path:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>机密秘密TEXT #秘密标签</p>",
            files='<img src="files/photo1.png"><img src="files/clip.mov">'
                  '<audio src="files/voice.aac"></audio>',
        )])
        return make_zip(self.tmp / "e.zip", html=html, media={
            "files/photo1.png": PNG, "files/clip.mov": MOV, "files/voice.aac": AAC})

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / "import_flomo.py"), *args],
            capture_output=True, text=True, cwd=str(REPO_ROOT))

    def test_cli_prints_aggregate_counts_only(self) -> None:
        zp = self.build_zip()
        dest = self.dest()
        result = self.run_cli("--input", str(zp), "--output", str(dest))
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("memos: 1", out)
        self.assertIn("days: 1", out)
        self.assertIn("types: text=0 voice=0 photo=0 mixed=1", out)
        self.assertIn("attachments: photo=1 audio=1 file=1", out)
        self.assertIn("unsupported_cloud_media: mov=1 aac=1", out)
        self.assertIn("unique_tags: 1", out)
        # Privacy: no note text, tag labels, or media paths in printed output.
        for forbidden in ("机密", "秘密", "#", "photo1.png", "clip.mov",
                          "voice.aac", "files/", "raw/assets"):
            self.assertNotIn(forbidden, out)
        self.assertTrue((dest / "vault/raw/2023-05-01.md").is_file())

    def test_cli_dry_run_flag_writes_nothing(self) -> None:
        zp = self.build_zip()
        dest = self.dest()
        result = self.run_cli("--input", str(zp), "--output", str(dest),
                              "--timezone", "Asia/Shanghai", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry_run: yes", result.stdout)
        self.assertIn("files_written: 0", result.stdout)
        self.assertFalse(dest.exists())

    def test_cli_invalid_input_exits_nonzero(self) -> None:
        result = self.run_cli("--input", str(self.tmp / "nope.zip"),
                              "--output", str(self.dest()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error:", result.stderr)

    def test_module_main_matches_cli(self) -> None:
        zp = self.build_zip()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = import_flomo.main([
                "--input", str(zp), "--output", str(self.dest()), "--dry-run"])
        self.assertEqual(code, 0)
        self.assertIn("memos: 1", out.getvalue())


# --------------------------------------------------------------------------
# Reserved delimiters: separator injection / legacy "---" delimiter
# --------------------------------------------------------------------------

class ReservedDelimiterTests(ImportFlomoTestBase):
    def test_reserved_separator_in_body_fails_closed_with_zero_output(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>before</p><p>&lt;!-- daypage-memo-separator --&gt;</p><p>after</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError) as ctx:
            import_flomo.parse_export(zp)
        # Content-free error: no note text leaks into diagnostics.
        self.assertNotIn("before", str(ctx.exception))
        self.assertNotIn("after", str(ctx.exception))
        self.assertFalse(self.dest().exists())

    def test_reserved_separator_rejected_anywhere_in_source_body(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>inline &lt;!-- daypage-memo-separator --&gt; marker</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_normal_markdown_divider_in_one_memo_day_preserved(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>before</p><p>---</p><p>after</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].body, 'before\n\n---\n\nafter')

    def test_legacy_separator_styled_like_memo_block_fails_closed(self) -> None:
        body = ("<p>before</p><p>---</p><p>---<br>id: 550e8400-e29b-41d4-a716-"
                "446655440000<br>---<br><br>after</p>")
        html = export_html([memo_div("2023-05-01 12:34:56", body)])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_plain_body_with_dashes_but_no_legacy_separator_ok(self) -> None:
        # single dashes inline are fine; only the exact legacy delimiter is reserved
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>a -- b</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        self.assertEqual(import_flomo.parse_export(zp).memos[0].body, "a -- b")

    def test_legacy_embedded_yaml_prefix_and_indented_id_rejected(self):
        for prefix, identifier in [('---yaml', 'id: 550e8400-e29b-41d4-a716-446655440000'),
                                   ('---', '  id: "550e8400-e29b-41d4-a716-446655440000"')]:
            with self.subTest(prefix=prefix, indented=identifier.startswith(' ')):
                body = f'<p>before</p><p>---</p><p>{prefix}<br>{identifier}<br>---<br><br>after</p>'
                source = make_zip(self.tmp / 'legacy.zip', html=export_html([
                    memo_div('2023-05-01 12:34:56', body)]))
                with self.assertRaises(import_flomo.ParseError):
                    import_flomo.parse_export(source)


# --------------------------------------------------------------------------
# Anchors, code/pre, unsupported structures (P1: no silent content loss)
# --------------------------------------------------------------------------

class AnchorAndCodeTests(ImportFlomoTestBase):
    def test_anchor_becomes_markdown_link_preserving_destination(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<p><a href="https://example.com/a(b)">docs</a></p>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "[docs](https://example.com/a%28b%29)")

    def test_mailto_anchor_supported(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<p><a href="mailto:me@example.com">mail me</a></p>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "[mail me](mailto:me@example.com)")

    def test_unsafe_anchor_schemes_fail_closed(self) -> None:
        for href in ("javascript:alert(1)", "data:text/html,x", "file:///etc/passwd",
                     "files/x.png", "//evil.example/x", "#fragment"):
            with self.subTest(href=href):
                html = export_html([memo_div(
                    "2023-05-01 12:34:56", f'<p><a href="{href}">x</a></p>')])
                zp = make_zip(self.tmp / "e.zip", html=html)
                with self.assertRaises(import_flomo.FlomoImportError):
                    import_flomo.parse_export(zp)

    def test_pre_becomes_fenced_code_block_exact_whitespace(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<pre>def f():\n    return 1\n</pre>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "```\ndef f():\n    return 1\n```")
        self.assertIn("    return 1", body)  # indentation retained exactly

    def test_pre_source_newline_after_tag_stripped(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<pre>\ncode\n</pre>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        self.assertEqual(import_flomo.parse_export(zp).memos[0].body,
                         "```\ncode\n```")

    def test_pre_fence_collision_fails_closed(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<pre>```\nbad\n```</pre>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_inline_code_span(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>use <code>print()</code> now</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        self.assertEqual(import_flomo.parse_export(zp).memos[0].body,
                         "use `print()` now")

    def test_inline_code_with_backtick_falls_back_to_plain_text(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p><code>a`b</code></p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "a`b")  # text kept, no marker leak

    def test_unsupported_content_structures_fail_closed(self) -> None:
        for fragment in ("<table><tr><td>x</td></tr></table>",
                         "<form><input value='x'></form>",
                         "<iframe src='x'></iframe>",
                         "<select><option value='#t'>t</option></select>"):
            with self.subTest(fragment=fragment):
                html = export_html([memo_div("2023-05-01 12:34:56",
                                             f"<p>a</p>{fragment}")])
                zp = make_zip(self.tmp / "e.zip", html=html)
                with self.assertRaises(import_flomo.FlomoImportError):
                    import_flomo.parse_export(zp)

    def test_hr_becomes_native_safe_divider(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>a</p><hr><p>b</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "a\n\n----\n\nb")  # >=3 dashes divider, not "---"


# --------------------------------------------------------------------------
# List markup: optional closing tags, nesting (P1)
# --------------------------------------------------------------------------

class ListMarkupTests(ImportFlomoTestBase):
    def test_optional_closing_li_separates_items(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<ul><li>first<li>second</ul>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "- first\n- second")

    def test_nested_li_with_paragraphs_and_list(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<ul><li><p>alpha</p><p>beta<ol start="2"><li>x</li></ol>'
            "</li><li>gamma</li></ul>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "- alpha\n  beta\n    2. x\n- gamma")

    def test_optional_closing_nested_items(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<ol start="1"><li>one<ul><li>deep<li>deeper</ul><li>two</ol>',
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        body = import_flomo.parse_export(zp).memos[0].body
        self.assertEqual(body, "1. one\n    - deep\n    - deeper\n2. two")


# --------------------------------------------------------------------------
# Tags: source-stream extraction, punctuation, taxonomy (P2)
# --------------------------------------------------------------------------

class TagExtractionTests(ImportFlomoTestBase):
    def test_real_export_unprefixed_catalog_excludes_date_select(self):
        controls = ('<select name="date" id="date"><option value="2026-10">October</option></select>'
                    '<select name="tag" id="tag"><option value="">all</option>'
                    '<option value="parent">#parent</option>'
                    '<option value="parent/child">#parent/child</option>'
                    '<option value="unused">#unused</option></select>')
        export = import_flomo.parse_export(make_zip(self.tmp / 'e.zip', html=export_html(
            [memo_div('2023-05-01 12:34:56', '<p>#parent/child</p>')], controls)))
        self.assertEqual(export.tag_catalog, ('#parent', '#parent/child', '#unused'))

    def test_paragraph_boundaries_keep_formatted_tags_separate(self):
        export = import_flomo.parse_export(make_zip(self.tmp / 'e.zip', html=export_html([
            memo_div('2023-05-01 12:34:56',
                     '<p>中文正文</p><p><strong>#parent/child</strong></p><p>下一段中文</p>')])) )
        self.assertEqual(export.memos[0].tags, ('#parent/child',))

    def test_known_punctuation_tag_uses_complete_catalog_label(self):
        controls = ('<select name="tag"><option value="team,notes">#team,notes</option>'
                    '<option value="parent/child">#parent/child</option></select>')
        export = import_flomo.parse_export(make_zip(self.tmp / 'e.zip', html=export_html([
            memo_div('2023-05-01 12:34:56', '<p>#team,notes #parent/child。</p>')], controls)))
        self.assertEqual(export.memos[0].tags, ('#team,notes', '#parent/child'))

    def test_bold_wrapped_hashtag_extracted(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p><strong>#work</strong> sprint</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].tags, ("#work",))
        self.assertIn("**#work**", export.memos[0].body)

    def test_sentence_punctuation_stripped_from_tags(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>看 #plain。 和 #parent/child，还有 #end.</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].tags,
                         ("#plain", "#parent/child", "#end"))
        # body keeps the exact original spelling/punctuation untouched
        self.assertIn("#plain。 和 #parent/child，还有 #end.", export.memos[0].body)

    def test_urls_and_code_not_treated_as_tags(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p>see https://x.com/#frag and <code>#nope</code> plus #yes</p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        self.assertEqual(import_flomo.parse_export(zp).memos[0].tags, ("#yes",))

    def _tag_select(self, labels) -> str:
        opts = "".join(f'<option value="{v}">{v}</option>' for v in labels)
        return f'<select class="tag-filter">{opts}</select>'

    def test_same_prefix_tags_not_truncated_without_taxonomy(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>#work #workout</p>")])
        zp = make_zip(self.tmp / "e.zip", html=html)
        self.assertEqual(import_flomo.parse_export(zp).memos[0].tags,
                         ("#work", "#workout"))

    def test_taxonomy_same_prefix_prefers_longest_exact_label(self) -> None:
        select = self._tag_select(["#work", "#workout"])
        html = export_html(
            [memo_div("2023-05-01 12:34:56", "<p>#workout and #work</p>")],
            extra_body=select)
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].tags, ("#workout", "#work"))
        # unknown same-prefix label is never truncated to a known short one
        html2 = export_html(
            [memo_div("2023-05-01 12:34:56", "<p>#workout</p>")],
            extra_body=self._tag_select(["#work"]))
        zp2 = make_zip(self.tmp / "e2.zip", html=html2)
        self.assertEqual(import_flomo.parse_export(zp2).memos[0].tags, ("#workout",))

    def test_taxonomy_longest_path_matching(self) -> None:
        select = self._tag_select(["#parent", "#parent/child"])
        html = export_html(
            [memo_div("2023-05-01 12:34:56",
                      "<p>#parent/child， #parent #parent/child/unknown</p>")],
            extra_body=select)
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        self.assertEqual(export.memos[0].tags,
                         ("#parent/child", "#parent", "#parent/child/unknown"))

    def test_tag_catalog_retained_in_manifest_including_unused(self) -> None:
        select = self._tag_select(["#parent", "#parent/child", "#unused/label"])
        html = export_html(
            [memo_div("2023-05-01 12:34:56", "<p>only #parent here</p>")],
            extra_body=select)
        zp = make_zip(self.tmp / "e.zip", html=html)
        summary = self.write_day(import_flomo.parse_export(zp))
        manifest = json.loads((self.dest() / "flomo-import-manifest.json").read_text())
        self.assertEqual(manifest["tag_catalog"],
                         ["#parent", "#parent/child", "#unused/label"])
        self.assertEqual(manifest["tag_index"], {"#parent": 1})
        self.assertEqual(summary.unique_tag_count, 1)

    def test_taxonomy_select_chrome_never_leaks_into_output(self) -> None:
        select = self._tag_select(["#机密标签"])
        html = export_html(
            [memo_div("2023-05-01 12:34:56", "<p>note</p>")], extra_body=select)
        zp = make_zip(self.tmp / "e.zip", html=html)
        summary = self.write_day(import_flomo.parse_export(zp))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            import_flomo.main(["--input", str(zp), "--output", str(self.dest()),
                               "--dry-run"])
        self.assertNotIn("机密标签", out.getvalue())
        day = (self.dest() / "vault/raw/2023-05-01.md").read_text()
        self.assertNotIn("机密标签", day)


# --------------------------------------------------------------------------
# Render compatibility: formatting adaptations recorded (P2)
# --------------------------------------------------------------------------

class RenderCompatTests(ImportFlomoTestBase):
    def test_formatting_adaptations_recorded_in_manifest_and_summary(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            "<p><u>u</u> and <mark>m</mark> and <strong>b</strong> "
            "and <code>c</code></p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        summary = self.write_day(import_flomo.parse_export(zp))
        expected = {
            "underline_to_strong": 1,
            "highlight_to_strong": 1,
            "code_blocks": 0,
            "code_spans": 1,
            "code_spans_to_plain": 0,
            "anchor_links": 0,
            "native_edge_whitespace": 0,
        }
        manifest = json.loads((self.dest() / "flomo-import-manifest.json").read_text())
        self.assertEqual(manifest["formatting_adaptations"], expected)
        self.assertEqual(summary.formatting_adaptations, expected)

    def test_anchor_and_code_adaptations_counted(self) -> None:
        html = export_html([memo_div(
            "2023-05-01 12:34:56",
            '<p><a href="https://x.example/y">l</a></p><pre>t\n</pre>'
            "<p><code>a`b</code></p>",
        )])
        zp = make_zip(self.tmp / "e.zip", html=html)
        export = import_flomo.parse_export(zp)
        ad = export.adaptations
        self.assertEqual(ad["anchor_links"], 1)
        self.assertEqual(ad["code_blocks"], 1)
        self.assertEqual(ad["code_spans_to_plain"], 1)


# --------------------------------------------------------------------------
# Destination symlink escapes (P2)
# --------------------------------------------------------------------------

class SymlinkDestinationTests(ImportFlomoTestBase):
    def simple_zip(self) -> Path:
        html = export_html([memo_div("2023-05-01 12:34:56", "<p>mine</p>")])
        return make_zip(self.tmp / "e.zip", html=html)

    def test_symlinked_destination_rejected_no_outside_write(self) -> None:
        outside = self.tmp / "outside"
        outside.mkdir()
        dest = self.tmp / "staging"
        dest.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(self.simple_zip()), dest)
        self.assertEqual(list(outside.iterdir()), [])

    def test_symlinked_intermediate_dir_rejected_no_outside_write(self) -> None:
        zp = self.simple_zip()
        dest = self.dest()
        self.write_day(import_flomo.parse_export(zp))  # owned staging
        outside = self.tmp / "outside"
        outside.mkdir()
        real_raw = dest / "vault/raw"
        for child in real_raw.iterdir():
            child.unlink()
        real_raw.rmdir()
        real_raw.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(zp), dest)
        self.assertEqual(list(outside.iterdir()), [])  # no outside write

    def test_symlinked_target_file_rejected(self) -> None:
        zp = self.simple_zip()
        dest = self.dest()
        self.write_day(import_flomo.parse_export(zp))
        outside_file = self.tmp / "outside.md"
        outside_file.write_text("outside data")
        target = dest / "vault/raw/2023-05-01.md"
        target.unlink()
        target.symlink_to(outside_file)
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(import_flomo.parse_export(zp), dest)
        self.assertEqual(outside_file.read_text(), "outside data")  # untouched


# --------------------------------------------------------------------------
# Interrupted writes: same-dir temp + atomic install + owned-temp recovery (P2)
# --------------------------------------------------------------------------

class AtomicWriteTests(ImportFlomoTestBase):
    def test_preplaced_temporary_symlink_never_overwrites_outside(self):
        export = import_flomo.parse_export(self.media_zip())
        self.write_day(export)
        target = self.dest() / 'vault/raw/2023-05-01.md'
        target.unlink()
        outside = self.tmp / 'outside.txt'
        outside.write_text('must survive')
        target.with_name('.' + target.name + '.flomo-import-tmp').symlink_to(outside)
        with self.assertRaises(import_flomo.FlomoImportError):
            self.write_day(export)
        self.assertEqual(outside.read_text(), 'must survive')
        self.assertFalse(target.exists())

    def test_first_manifest_orphan_can_be_validated_and_recovered(self):
        export = import_flomo.parse_export(self.media_zip())
        self.write_day(export)
        manifest = (self.dest() / 'flomo-import-manifest.json').read_bytes()
        fresh = self.tmp / 'interrupted-first-write'
        fresh.mkdir()
        orphan = fresh / '.flomo-import-manifest.json.abc12345.flomo-import-tmp'
        orphan.write_bytes(manifest)
        summary = self.write_day(export, fresh)
        self.assertEqual(summary.files_written, 2)
        self.assertFalse(orphan.exists())

    def test_atomic_install_never_clobbers_new_conflicting_file(self):
        target = self.tmp / 'target.txt'
        real_link = __import__('os').link
        def concurrent_writer(source, destination, **kwargs):
            Path(destination).write_bytes(b'other writer')
            return real_link(source, destination, **kwargs)
        with mock.patch('os.link', side_effect=concurrent_writer):
            with self.assertRaises(import_flomo.ConflictError):
                import_flomo._atomic_write(target, b'import content')
        self.assertEqual(target.read_bytes(), b'other writer')

    def media_zip(self) -> Path:
        html = export_html([memo_div(
            "2023-05-01 12:34:56", "<p>note</p>",
            files='<img src="files/p.png">')])
        return make_zip(self.tmp / "e.zip", html=html, media={"files/p.png": PNG})

    def test_interrupted_write_leaves_no_partial_and_retry_completes(self) -> None:
        zp = self.media_zip()
        dest = self.dest()
        real_replace = __import__("os").link
        calls = {"n": 0}

        def flaky_replace(src, dst, *args, **kwargs):
            calls["n"] += 1
            if calls["n"] == 2:  # crash while installing the first content file
                raise RuntimeError("injected")
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch("os.link", side_effect=flaky_replace):
            with self.assertRaises(RuntimeError):
                import_flomo.write_vault(import_flomo.parse_export(zp), dest)
        # Manifest (first atomic install) landed; content files are all-or-nothing.
        self.assertTrue((dest / "flomo-import-manifest.json").is_file())
        self.assertFalse((dest / "vault/raw/2023-05-01.md").exists())
        self.assertFalse(any(dest.glob("vault/raw/assets/flomo/*.png")))
        # Retry recovers and finishes the interrupted import.
        summary = self.write_day(import_flomo.parse_export(zp), dest)
        self.assertEqual(summary.files_written, 2)
        day = (dest / "vault/raw/2023-05-01.md").read_text()
        self.assertTrue(day.endswith("note\n"))
        self.assertEqual(
            (dest / f"vault/raw/assets/flomo/{sha256_hex(PNG)}.png").read_bytes(), PNG)
        # No owned temp artifacts remain after success.
        self.assertEqual(list(dest.rglob("*.flomo-import-tmp")), [])

    def test_retry_recovers_leftover_owned_temp_artifacts(self) -> None:
        zp = self.media_zip()
        dest = self.dest()
        self.write_day(import_flomo.parse_export(zp))
        unrelated = dest / "unrelated.txt"
        unrelated.write_text("user data")
        asset = dest / f"vault/raw/assets/flomo/{sha256_hex(PNG)}.png"
        asset.unlink()  # simulate lost work
        stray = dest / "vault/raw/.stray.md.flomo-import-tmp"
        stray.write_bytes(b"crashed temp")
        summary = self.write_day(import_flomo.parse_export(zp), dest)
        self.assertEqual(summary.files_written, 1)
        self.assertEqual(asset.read_bytes(), PNG)
        self.assertTrue(stray.exists())  # unrelated temporary names are never reclaimed
        self.assertEqual(unrelated.read_text(), "user data")  # never overwritten
        self.assertEqual(list(dest.rglob("*.flomo-import-tmp")), [stray])

    def test_temp_files_written_in_same_directory(self) -> None:
        zp = self.media_zip()
        dest = self.dest()
        seen: list = []
        real_replace = __import__("os").link

        def spy(src, dst, *args, **kwargs):
            seen.append((str(src), str(dst)))
            return real_replace(src, dst, *args, **kwargs)

        with mock.patch("os.link", side_effect=spy):
            import_flomo.write_vault(import_flomo.parse_export(zp), dest)
        self.assertTrue(seen)
        for src, dst in seen:
            self.assertEqual(str(Path(src).parent), str(Path(dst).parent))
            self.assertTrue(str(src).endswith(".flomo-import-tmp"))


# --------------------------------------------------------------------------
# Malformed nesting / HTML resource bounds
# --------------------------------------------------------------------------

class HtmlBoundsTests(ImportFlomoTestBase):
    def test_deep_nesting_bounded(self) -> None:
        deep = "<div>" * 300 + "deep" + "</div>" * 300
        html = export_html([memo_div("2023-05-01 12:34:56", deep)])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with self.assertRaises(import_flomo.FlomoImportError):
            import_flomo.parse_export(zp)

    def test_node_count_bounded(self) -> None:
        many = "<p>x</p>" * 50
        html = export_html([memo_div("2023-05-01 12:34:56", many)])
        zp = make_zip(self.tmp / "e.zip", html=html)
        with mock.patch.object(import_flomo, "MAX_HTML_NODES", 10):
            with self.assertRaises(import_flomo.FlomoImportError):
                import_flomo.parse_export(zp)


if __name__ == "__main__":
    unittest.main()
