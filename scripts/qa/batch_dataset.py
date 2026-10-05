#!/usr/bin/env python3
"""Synthetic DayPage bulk QA dataset CLI (authorized testing tooling).

Generates deterministic SYNTHETIC vault data that matches the canonical DayPage
storage format frozen at the current base commit:

* Day files ``raw/YYYY-MM-DD.md`` hold YAML-front-matter + Markdown memo blocks
  exactly as ``Memo.toMarkdown()`` serializes them
  (``DayPageKit/Sources/DayPageModels/Memo.swift``).
* Multiple memo blocks in one day file are joined with the exact
  ``RawStorage.memoSeparator`` string
  ``"\\n\\n<!-- daypage-memo-separator -->\\n\\n"``
  (``DayPageKit/Sources/DayPageStorage/RawStorage.swift``).
* Memo bodies deliberately contain separator-LOOKING text (``---`` rules and an
  inline ``<!-- daypage-memo-separator -->`` token that is never flanked by the
  exact ``\\n\\n ... \\n\\n`` literal) to exercise parser robustness.

Commands:
  generate       build a new dataset in a nonexistent output directory
  validate       verify structure, hashes, counts, format, images, tokens
  import-vault   copy a validated dataset's raw/ tree into a FRESH vault dir
  upload-images  POST raw/assets JPEGs to an explicit HTTP endpoint

stdlib + Pillow only. No app code is touched. The upload target is whatever
HTTP endpoint the operator passes; this tool never talks to any "DayPage
cloud" by itself. See docs/engineering/batch-dataset.md.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

# MARK: Canonical format constants (mirror DayPageKit at the frozen base)

MEMO_SEPARATOR = "\n\n<!-- daypage-memo-separator -->\n\n"  # RawStorage.memoSeparator
LEGACY_MEMO_SEPARATOR = "\n\n---\n\n"  # RawStorage.legacyMemoSeparator
MANIFEST_NAME = "manifest.json"
SCHEMA_VERSION = 1
KIND = "synthetic-daypage-qa-dataset"
GENERATOR = "scripts/qa/batch_dataset.py"

# Deterministic UUID namespace: same seed + index -> same UUID on every run.
UUID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "daypage-qa/batch-dataset/v1")

ASSET_NAME_RE = re.compile(r"^IMG_\d{8}_\d{6}_[0-9a-f]{4}\.jpg$")
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
CREATED_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")

EXIT_OK = 0
EXIT_INVALID = 1   # dataset invalid / upload failed
EXIT_REFUSED = 2   # usage error or safety refusal


class QAToolError(Exception):
    """Fatal tool error (usage, safety refusal, environment)."""


# MARK: - YAML scalar quoting (mirror Memo.yamlQuote / YAMLParser.unquote)

def yaml_quote(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def yaml_unquote(s: str) -> str:
    if len(s) < 2 or not (s.startswith('"') and s.endswith('"')):
        return s
    inner = s[1:-1]
    out = []
    i = 0
    while i < len(inner):
        ch = inner[i]
        if ch == "\\" and i + 1 < len(inner):
            nxt = inner[i + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, ch + nxt))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def fmt_float(v: float) -> str:
    """Format like Swift's default Double interpolation (5.0 -> '5.0')."""
    return repr(float(v))


# MARK: - Memo block serialization (mirror Memo.toMarkdown key order exactly)

def memo_block_to_markdown(m: dict) -> str:
    lines = ["---"]
    lines.append("id: " + m["id"])
    lines.append("type: " + m["type"])
    lines.append("created: " + m["created"])
    if m.get("pinned_at"):
        lines.append("pinned_at: " + m["pinned_at"])
    loc = m.get("location")
    if loc:
        lines.append("location:")
        if loc.get("name") is not None:
            lines.append("  name: " + yaml_quote(loc["name"]))
        if loc.get("lat") is not None:
            lines.append("  lat: " + fmt_float(loc["lat"]))
        if loc.get("lng") is not None:
            lines.append("  lng: " + fmt_float(loc["lng"]))
    for key in ("weather", "device", "mood", "margin_note"):
        v = m.get(key)
        if v is not None:
            lines.append(key + ": " + yaml_quote(v))
    mentions = m.get("entity_mentions") or []
    if not mentions:
        lines.append("entity_mentions: []")
    else:
        lines.append("entity_mentions:")
        for e in mentions:
            lines.append("  - " + yaml_quote(e))
    atts = m.get("attachments") or []
    if not atts:
        lines.append("attachments: []")
    else:
        lines.append("attachments:")
        for a in atts:
            lines.append("  - file: " + yaml_quote(a["file"]))
            lines.append("    kind: " + a["kind"])
            if a.get("duration") is not None:
                lines.append("    duration: " + fmt_float(a["duration"]))
            if a.get("transcript") is not None:
                lines.append("    transcript: " + yaml_quote(a["transcript"]))
            if a.get("transcription_status") is not None:
                lines.append("    transcription_status: " + a["transcription_status"])
    lines.append("---")
    lines.append("")
    lines.append(m["body"])
    return "\n".join(lines)


# MARK: - Memo block parsing (minimal mirror of Memo.fromMarkdown + YAMLParser)

def parse_memo_block(block: str):
    """Parse a memo block; return (memo_dict, None) or (None, reason)."""
    # Mirror Swift: the block is trimmed of whitespace/newlines before parsing.
    text = block.strip()
    if not text.startswith("---"):
        return None, "block does not start with front-matter fence"
    lines = text.split("\n")
    closing = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            closing = i
            break
    if closing is None:
        return None, "no closing front-matter fence"
    fm_lines = lines[1:closing]
    raw_body = lines[closing + 1:]
    start = 0
    while start < len(raw_body) and not raw_body[start].strip():
        start += 1
    body = "\n".join(raw_body[start:])

    scalars: dict[str, str] = {}
    for line in fm_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("-") or line.startswith(" "):
            continue
        if ": " in stripped:
            k, v = stripped.split(": ", 1)
            scalars[k] = yaml_unquote(v)
        elif stripped.endswith(":"):
            scalars[stripped[:-1]] = ""
    for req in ("id", "type", "created"):
        if req not in scalars:
            return None, f"missing front-matter key '{req}'"
    if not UUID_RE.fullmatch(scalars["id"]):
        return None, "id is not a UUID"
    if not CREATED_RE.match(scalars["created"]):
        return None, "created is not an ISO8601 memo timestamp"

    m: dict = {
        "id": scalars["id"],
        "type": scalars["type"],
        "created": scalars["created"],
        "body": body,
        "entity_mentions": [],
        "attachments": [],
    }
    if "pinned_at" in scalars:
        m["pinned_at"] = scalars["pinned_at"]

    # location: (2-space indented mapping)
    for i, line in enumerate(fm_lines):
        if line.strip() == "location:":
            loc = {}
            for sub in fm_lines[i + 1:]:
                if sub.startswith("  ") and not sub.startswith("   "):
                    s = sub.strip()
                    if ": " in s:
                        k, v = s.split(": ", 1)
                        loc[k] = yaml_unquote(v)
                else:
                    break
            m["location"] = {
                "name": loc.get("name"),
                "lat": float(loc["lat"]) if "lat" in loc else None,
                "lng": float(loc["lng"]) if "lng" in loc else None,
            }
            break

    for key in ("weather", "device", "mood", "margin_note"):
        if key in scalars:
            m[key] = scalars[key]

    # entity_mentions: [] or 2-space "  - value" list
    for i, line in enumerate(fm_lines):
        if line.strip() == "entity_mentions: []":
            m["entity_mentions"] = []
            break
        if line.strip() == "entity_mentions:":
            items = []
            for sub in fm_lines[i + 1:]:
                if sub.startswith("  - "):
                    items.append(yaml_unquote(sub[4:].strip()))
                else:
                    break
            m["entity_mentions"] = items
            break

    # attachments: [] or "  - key: value" / "    key: value" mapping list
    for i, line in enumerate(fm_lines):
        if line.strip() == "attachments: []":
            m["attachments"] = []
            break
        if line.strip() == "attachments:":
            items: list[dict] = []
            current: dict = {}
            for sub in fm_lines[i + 1:]:
                if sub.startswith("  - "):
                    if current:
                        items.append(current)
                        current = {}
                    part = sub[4:].strip()
                    if ": " in part:
                        k, v = part.split(": ", 1)
                        current[k] = yaml_unquote(v.strip())
                elif sub.startswith("    "):
                    part = sub.strip()
                    if ": " in part:
                        k, v = part.split(": ", 1)
                        current[k] = yaml_unquote(v.strip())
                else:
                    break
            if current:
                items.append(current)
            m["attachments"] = items
            break

    return m, None


# MARK: - Deterministic content pools

CN_SENTENCES = [
    "今天把批量导入的边界条件重新梳理了一遍，确认了几个容易被忽略的空值分支。",
    "窗外下着小雨 ☕️，正好把长段落的排版检查完，中文断行看起来没有问题。",
    "团队讨论了「原始数据永远不重写」的原则，这条不变式写进了评审清单。",
    "下午的复盘里提到 URL 解析要兼容旧链接：https://example.org/qa/notes 仍然可达。",
    "把这段写得足够长，用来验证编辑器在超长中文段落下的滚动与换行表现 🌸。",
    "晚上散步时想到，分隔符鲁棒性测试必须包含用户手输 --- 的场景。",
    "实体提及：北京、上海、Café \"Le Monde\"，以及带反斜杠的路径 C:\\\\vault\\\\raw。",
    "这条记录混合了中英文，还带一个表情 🚀，方便检索测试覆盖多语言查询。",
    "结论是：任何迁移都必须先有隔离往返测试，再谈自动化。",
    "顺手把照片附件挂到这条 memo 上，方便布局测试跳转到封面图。",
]

EN_SENTENCES = [
    "Long paragraph for layout stress: the renderer must keep scrolling smoothly "
    "while this mixed CN/EN block keeps going with https://example.org/qa/long-paragraph anchors.",
    "The separator robustness case matters because users type rules like --- inside notes.",
    "Deterministic UUIDs let replayable QA runs diff byte-for-byte across machines.",
    "Emoji smoke test: 🌸🚀😀 and a quoted phrase \"keep raw bytes\" live in the same body.",
    "This sentence exists so query tokens can be asserted against a stable memo id.",
    "Navigation aid: related memo ids and the cover path are cited right in the body.",
    "Multiline heading sections below exercise heading navigation in the page layout.",
    "Attachment metadata round-trips through YAML quoting without leaking newlines.",
    "The synthetic dataset never touches a real vault; generate it outside the repository.",
    "Bulk QA needs thousands of paragraphs like this one without hand-writing fixtures.",
]


def _pick(pool: list[str], idx: int, offset: int) -> str:
    return pool[(idx * 7 + offset) % len(pool)]


# MARK: - Dataset construction (pure: returns bytes, no filesystem writes)

def derive_uuid(seed: int, index: int) -> str:
    return str(uuid.uuid5(UUID_NAMESPACE, f"seed={seed}/memo={index}")).upper()


def derive_hex4(seed: int, tag: str) -> str:
    return hashlib.sha256(f"daypage-qa/{seed}/{tag}".encode()).hexdigest()[:4]


def _iso(dt: datetime) -> str:
    ms = dt.microsecond // 1000
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms:03d}Z"


IMAGE_SPECS = {
    # kind: ((width, height), exif_orientation)
    "landscape": ((1280, 854), 1),
    "portrait": ((854, 1280), 1),
    "exif_orientation_3": ((1280, 854), 3),
    "exif_orientation_6": ((1280, 854), 6),
    "exif_orientation_8": ((854, 1280), 8),
    "large_4096": ((4096, 4096), 1),
}


def _make_jpeg(kind: str, seed: int, idx: int) -> bytes:
    from PIL import Image, ImageDraw  # Pillow only; lazy so non-image commands stay light

    try:
        size, orientation = IMAGE_SPECS[kind]
    except KeyError:
        raise QAToolError(f"unknown image kind {kind!r}")

    base = (37 + (seed + idx) * 53) % 256
    img = Image.new("RGB", size, (base, (base * 3) % 256, (base * 7) % 256))
    draw = ImageDraw.Draw(img)
    w, h = size
    band = max(8, h // 6)
    draw.rectangle([0, band, w, 2 * band], fill=((base + 90) % 256, (base * 5) % 256, 200))
    draw.rectangle([w // 4, h // 2, w // 2, h - band], fill=(240, 240, (base * 11) % 256))
    exif = Image.Exif()
    exif[0x0112] = orientation  # Orientation tag
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85, exif=exif)
    return buf.getvalue()


def _corrupt_fixture_bytes(seed: int) -> bytes:
    """Truncated JPEG: valid SOI/header bytes cut off mid-stream. Deterministic.

    Kept deliberately undecodable (Pillow fails to identify/verify it) and
    stored outside raw/assets so it can never be mistaken for a valid
    attachment.
    """
    good = _make_jpeg("landscape", seed, 9999)
    return good[:64]


IMAGE_KIND_CYCLE = [
    "landscape",
    "portrait",
    "exif_orientation_6",
    "exif_orientation_8",
    "large_4096",
    "landscape",
    "portrait",
    "exif_orientation_3",
]
MEMO_TYPE_CYCLE = ["text", "photo", "text", "mixed", "location", "text", "photo", "mixed"]


def _build_body(idx: int, memo_id: str, related_id: str, cover: str | None,
                token: str, day_token: str, sep_looking: bool) -> str:
    p1 = _pick(CN_SENTENCES, idx, 0) + _pick(CN_SENTENCES, idx, 3)
    p2 = _pick(EN_SENTENCES, idx, 1) + " " + _pick(EN_SENTENCES, idx, 4)
    p3 = _pick(CN_SENTENCES, idx, 6) + _pick(EN_SENTENCES, idx, 2)
    parts = [
        "# 主题 Heading " + str(idx),
        "",
        p1,
        "",
        "## 小节 Section A",
        "",
        p2,
        "",
        "- 列表项 one · " + _pick(EN_SENTENCES, idx, 5),
        "- 列表项二 " + _pick(CN_SENTENCES, idx, 8),
        "",
        p3,
    ]
    if sep_looking:
        parts += [
            "",
            "## 分隔线鲁棒性 Separator robustness",
            "",
            "上面一段 above the rule。",
            "",
            "---",
            "",
            "下面一段 below the rule，含伪注释 <!-- daypage-memo-separator --> 不是真分隔符。",
            "",
            "  <!-- daypage-memo-separator -->",
            "",
            "---",
        ]
    nav = f"导航 Navigation: 相关 memo `{related_id}`"
    if cover:
        nav += f" · 封面 cover `{cover}`"
    parts += ["", nav, "", f"查询标记 query token: {token} · {day_token}"]
    return "\n".join(parts)


def build_dataset(seed: int, count: int, days: int, end_date: date, images: int):
    """Build the full dataset in memory.

    Returns (files: {relpath: bytes}, manifest: dict). files includes the
    manifest itself; manifest hashes cover every other file.
    """
    if days < 1:
        raise QAToolError("--days must be >= 1")
    if count < days:
        raise QAToolError("--count must be >= --days so every day has at least one memo")
    if images < max(5, days):
        raise QAToolError(
            f"--images must be >= max(5, days) = {max(5, days)} to cover "
            "landscape/portrait/EXIF/4096 variants and one cover per day"
        )

    dates = [end_date - timedelta(days=k) for k in range(days - 1, -1, -1)]

    # 1. Memo metadata: deterministic ids/types/timestamps spread over the days.
    base = count // days
    remainder = count % days
    per_day = [base + (1 if i < remainder else 0) for i in range(days)]
    memos: list[dict] = []
    idx = 0
    for d_idx, d in enumerate(dates):
        for j in range(per_day[d_idx]):
            memo_type = MEMO_TYPE_CYCLE[idx % len(MEMO_TYPE_CYCLE)]
            # Timestamps 08:00-11:00 UTC so the calendar date matches the day
            # file for any device timezone in roughly UTC-8..UTC+11.
            second = 8 * 3600 + (idx * 1973 + seed * 31) % 10800
            created_dt = datetime(d.year, d.month, d.day, tzinfo=timezone.utc) + timedelta(seconds=second)
            m = {
                "id": derive_uuid(seed, idx),
                "type": memo_type,
                "created": _iso(created_dt),
                "day": d.isoformat(),
                "entity_mentions": [],
                "attachments": [],
                "body": "",
            }
            if idx % 7 == 3:
                m["pinned_at"] = _iso(created_dt + timedelta(seconds=60))
            if memo_type == "location" or idx % 11 == 5:
                m["location"] = {"name": "北京 Beijing · Café \"Le Monde\"", "lat": 39.9042, "lng": 116.4074}
            if idx % 3 == 0:
                m["weather"] = "Sunny \\n 24°C ☀️"
            if idx % 4 == 1:
                m["device"] = "iPhone \"QA\" \\n simulator"
            if idx % 5 == 2:
                m["mood"] = "平静 calm 🌸"
            if idx % 6 == 4:
                m["margin_note"] = "边缘批注 margin \"quoted\" \\n note"
            m["entity_mentions"] = ["北京", "DayPage", "Café \"Le Monde\" \\n Paris"][: 1 + (idx % 3)]
            memos.append(m)
            idx += 1

    # Guarantee at least one photo/mixed memo per day (attachment + cover holder).
    for d in dates:
        day_memos = [m for m in memos if m["day"] == d.isoformat()]
        if not any(m["type"] in ("photo", "mixed") for m in day_memos):
            day_memos[0]["type"] = "mixed"

    # 2. Images: deterministic names/stamps, one cover per day, every image used.
    image_entries: list[dict] = []
    asset_bytes: dict[str, bytes] = {}
    stamp_base = datetime(end_date.year, end_date.month, end_date.day, 9, 0, 0, tzinfo=timezone.utc)
    for i in range(images):
        kind = IMAGE_KIND_CYCLE[i % len(IMAGE_KIND_CYCLE)]
        if kind == "large_4096" and i != 4:
            kind = "landscape"
        stamp_dt = stamp_base + timedelta(seconds=i)
        stamp = stamp_dt.strftime("%Y%m%d_%H%M%S")
        name = f"IMG_{stamp}_{derive_hex4(seed, f'asset/{i}')}.jpg"
        rel = "raw/assets/" + name
        data = _make_jpeg(kind, seed, i)
        asset_bytes[rel] = data
        (w, h), orientation = IMAGE_SPECS[kind]
        image_entries.append({
            "file": rel,
            "kind": kind,
            "width": w,
            "height": h,
            "exif_orientation": orientation,
        })

    # Pass 1: one image per day (the day cover); pass 2: the rest round-robin.
    photo_memos = [m for m in memos if m["type"] in ("photo", "mixed")]
    covers_by_day: dict[str, str] = {}
    used = 0
    for d in dates:
        day_photo = [m for m in photo_memos if m["day"] == d.isoformat()]
        day_photo[0]["attachments"].append({"file": image_entries[used]["file"], "kind": "photo"})
        covers_by_day[d.isoformat()] = image_entries[used]["file"]
        used += 1
    for i in range(used, images):
        target_memo = photo_memos[(i - used) % len(photo_memos)]
        target_memo["attachments"].append({"file": image_entries[i]["file"], "kind": "photo"})
    # Every photo/mixed memo carries at least one photo attachment (its day cover).
    for m in photo_memos:
        if not m["attachments"]:
            m["attachments"].append({"file": covers_by_day[m["day"]], "kind": "photo"})

    # 3. Bodies (need ids + covers already known): citations, tokens, robustness.
    for i, m in enumerate(memos):
        related = memos[(i + 1) % len(memos)]["id"]
        is_first_of_day = not any(
            x["day"] == m["day"] for x in memos[:i]
        )
        m["body"] = _build_body(
            i,
            m["id"],
            related,
            covers_by_day[m["day"]] if is_first_of_day else None,
            f"qa-token-{i:04d}",
            f"qa-day-{m['day']}",
            sep_looking=(i % 5 == 2),
        )

    # 4. Serialize day files with the canonical separator.
    files: dict[str, bytes] = {}
    day_records: list[dict] = []
    for d in dates:
        day_memos = [m for m in memos if m["day"] == d.isoformat()]
        day_memos.sort(key=lambda m: m["created"])
        content = MEMO_SEPARATOR.join(memo_block_to_markdown(m) for m in day_memos)
        rel = f"raw/{d.isoformat()}.md"
        files[rel] = content.encode("utf-8")
        daily = (
            "---\ndate: " + d.isoformat() + "\nsummary: " +
            yaml_quote("Synthetic QA 图文批量数据 — " + d.isoformat()) +
            "\nentries_count: " + str(len(day_memos)) +
            "\ncover: " + covers_by_day[d.isoformat()] + "\n---\n\n## MORNING\n\n" +
            "\n\n".join("中英文长文本布局 QA / English layout. [^m:" + m["id"] + "]"
                        for m in day_memos[:5]) + "\n"
        )
        files[f"wiki/daily/{d.isoformat()}.md"] = daily.encode("utf-8")
        day_records.append({
            "date": d.isoformat(),
            "file": rel,
            "memo_ids": [m["id"] for m in day_memos],
            "cover": covers_by_day[d.isoformat()],
        })

    for rel, data in asset_bytes.items():
        files[rel] = data

    corrupt_rel = "fixtures/corrupt/truncated.jpg"
    files[corrupt_rel] = _corrupt_fixture_bytes(seed)

    # 5. Manifest.
    memos_sorted = sorted(memos, key=lambda m: (m["day"], m["created"]))
    token_records = [
        {"token": f"qa-token-{i:04d}", "memo_ids": [m["id"]]}
        for i, m in enumerate(memos)
    ]
    for d in dates:
        day_ids = [m["id"] for m in memos_sorted if m["day"] == d.isoformat()]
        token_records.append({"token": f"qa-day-{d.isoformat()}", "memo_ids": day_ids})

    type_counts: dict[str, int] = {}
    for m in memos_sorted:
        type_counts[m["type"]] = type_counts.get(m["type"], 0) + 1

    hashes = {rel: hashlib.sha256(data).hexdigest() for rel, data in sorted(files.items())}

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "kind": KIND,
        "generator": GENERATOR,
        "params": {"seed": seed, "count": count, "days": days, "end_date": end_date.isoformat(), "images": images},
        "counts": {
            "days": days,
            "memos": count,
            "images": images,
            "corrupt_fixtures": 1,
            "memos_by_day": {r["date"]: len(r["memo_ids"]) for r in day_records},
            "memos_by_type": dict(sorted(type_counts.items())),
        },
        "days": day_records,
        "memos": [
            {
                "id": m["id"],
                "type": m["type"],
                "day": m["day"],
                "created": m["created"],
                "attachments": [a["file"] for a in m["attachments"]],
            }
            for m in memos_sorted
        ],
        "images": image_entries,
        "corrupt_fixtures": [
            {
                "file": corrupt_rel,
                "kind": "truncated-jpeg",
                "note": "deliberately corrupt; kept out of raw/assets and out of vault imports",
            }
        ],
        "expected_query_tokens": token_records,
        "hashes": hashes,
    }
    files[MANIFEST_NAME] = (
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    return files, manifest


# MARK: - Path safety helpers

def check_rel_path(rel: str) -> bool:
    if not rel or rel.startswith("/") or "\\" in rel:
        return False
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return False
    return os.path.normpath(rel) == rel


def assert_no_symlinks(root: Path) -> None:
    for part in (root.absolute(), *root.absolute().parents):
        if part in (Path("/var"), Path("/tmp")) and part.resolve() == Path("/private") / part.name:
            continue  # macOS standard temp aliases, never a caller-chosen symlink
        if part.is_symlink():
            raise QAToolError(f"refusing symlinked path: {part}")
    if root.is_symlink():
        raise QAToolError(f"refusing symlinked dataset root: {root}")
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            p = Path(dirpath) / name
            if p.is_symlink():
                raise QAToolError(f"refusing symlink inside dataset: {p.relative_to(root)}")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# MARK: - validate

def validate_dataset(root: Path) -> list[str]:
    """Return a list of problems (empty list == valid)."""
    errors: list[str] = []
    try:
        assert_no_symlinks(root)
    except QAToolError as exc:
        return [str(exc)]
    root = root.resolve()
    if not root.is_dir():
        return [f"dataset directory not found: {root}"]

    manifest_path = root / MANIFEST_NAME
    if not manifest_path.is_file():
        return [f"missing {MANIFEST_NAME} in {root}"]
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{MANIFEST_NAME} is not valid JSON: {exc}"]

    if manifest.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version must be {SCHEMA_VERSION}")
    if manifest.get("kind") != KIND:
        errors.append(f"kind must be {KIND!r}")

    try:
        assert_no_symlinks(root)
    except QAToolError as exc:
        errors.append(str(exc))
        return errors

    hashes = manifest.get("hashes")
    if not isinstance(hashes, dict) or not hashes:
        errors.append("manifest.hashes must be a non-empty object")
        return errors

    # Every manifest path must be a safe relative path.
    listed_paths: list[str] = []
    for section in ("hashes",):
        for rel in manifest.get(section, {}):
            listed_paths.append(rel)
    for rec in manifest.get("days", []):
        listed_paths.append(rec.get("file", ""))
        if rec.get("cover"):
            listed_paths.append(rec["cover"])
    for rec in manifest.get("images", []):
        listed_paths.append(rec.get("file", ""))
    for rec in manifest.get("corrupt_fixtures", []):
        listed_paths.append(rec.get("file", ""))
    for rel in listed_paths:
        if not check_rel_path(rel):
            errors.append(f"unsafe path in manifest: {rel!r}")
    if errors:
        return errors

    # Hashes must cover exactly the on-disk files (minus the manifest itself).
    on_disk = {
        str(p.relative_to(root))
        for p in root.rglob("*")
        if p.is_file() and p.name != MANIFEST_NAME
    }
    for rel, digest in sorted(hashes.items()):
        p = root / rel
        if not p.is_file():
            errors.append(f"hashed file missing: {rel}")
            continue
        actual = sha256_of(p)
        if actual != digest:
            errors.append(f"hash mismatch (file changed): {rel}")
    extra = on_disk - set(hashes)
    for rel in sorted(extra):
        errors.append(f"file present but not in manifest.hashes: {rel}")

    # Counts.
    counts = manifest.get("counts", {})
    days = manifest.get("days", [])
    memos = manifest.get("memos", [])
    images = manifest.get("images", [])
    corrupt = manifest.get("corrupt_fixtures", [])
    params = manifest.get("params", {})
    if counts.get("days") != len(days):
        errors.append("counts.days != len(days)")
    if counts.get("memos") != len(memos):
        errors.append("counts.memos != len(memos)")
    if counts.get("images") != len(images):
        errors.append("counts.images != len(images)")
    if counts.get("corrupt_fixtures") != len(corrupt):
        errors.append("counts.corrupt_fixtures != len(corrupt_fixtures)")

    # Day date window: consecutive days ending at params.end_date.
    try:
        end = date.fromisoformat(params.get("end_date", ""))
        expected_dates = [(end - timedelta(days=k)).isoformat() for k in range(len(days) - 1, -1, -1)]
        actual_dates = [r.get("date") for r in days]
        if actual_dates != expected_dates:
            errors.append(f"days must be consecutive ending at {end}: got {actual_dates}")
    except ValueError:
        errors.append("params.end_date is not a YYYY-MM-DD date")

    memo_by_id = {m.get("id"): m for m in memos}
    if len(memo_by_id) != len(memos):
        errors.append("duplicate memo ids in manifest")
    seen_ids: set[str] = set()
    image_files = {r.get("file") for r in images}
    referenced_images: set[str] = set()
    valid_ids = {i.upper() for i in memo_by_id}
    token_index: dict[str, set[str]] = {}

    for rec in days:
        d = rec.get("date", "")
        if (not isinstance(d, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d)
                or rec.get("file") != f"raw/{d}.md"):
            return errors + ["invalid owning date/path in day record"]
        try:
            if date.fromisoformat(d).isoformat() != d:
                return errors + ["invalid owning date in day record"]
        except ValueError:
            return errors + ["invalid owning date in day record"]
        day_file = root / rec.get("file", "")
        if not day_file.is_file():
            errors.append(f"day file missing: {rec.get('file')}")
            continue
        content = day_file.read_text(encoding="utf-8")
        blocks = content.split(MEMO_SEPARATOR)
        ids = rec.get("memo_ids", [])
        if len(blocks) != len(ids):
            errors.append(
                f"{rec['file']}: splits into {len(blocks)} blocks on the canonical "
                f"separator, expected {len(ids)} (separator-looking body leak?)"
            )
            continue
        body_text_all = ""
        for i, block in enumerate(blocks):
            memo, reason = parse_memo_block(block)
            if memo is None:
                errors.append(f"{rec['file']} block {i}: {reason}")
                continue
            # Round-trip: canonical serialization must reproduce the bytes.
            if memo_block_to_markdown(memo) != block.strip():
                errors.append(f"{rec['file']} block {i}: not canonical Memo.toMarkdown bytes")
            if i < len(ids) and memo["id"] != ids[i]:
                errors.append(f"{rec['file']} block {i}: id {memo['id']} != manifest {ids[i]}")
            if memo["id"] in seen_ids:
                errors.append(f"memo id {memo['id']} appears twice in dataset")
            seen_ids.add(memo["id"])
            for token in set(re.findall(r"qa-token-\d+|qa-day-\d{4}-\d{2}-\d{2}", memo["body"])):
                token_index.setdefault(token, set()).add(memo["id"].upper())
            man = memo_by_id.get(memo["id"])
            if man is None:
                errors.append(f"memo {memo['id']} missing from manifest.memos")
            else:
                if man.get("type") != memo["type"]:
                    errors.append(f"memo {memo['id']}: type mismatch with manifest")
                if man.get("created") != memo["created"]:
                    errors.append(f"memo {memo['id']}: created mismatch with manifest")
                if man.get("day") != d:
                    errors.append(f"memo {memo['id']}: day mismatch with manifest")
                if sorted(man.get("attachments", [])) != sorted(a["file"] for a in memo["attachments"]):
                    errors.append(f"memo {memo['id']}: attachments mismatch with manifest")
            for att in memo["attachments"]:
                f = att.get("file", "")
                if not check_rel_path(f) or not f.startswith("raw/assets/"):
                    errors.append(f"memo {memo['id']}: unsafe attachment path {f!r}")
                    continue
                if f not in image_files:
                    errors.append(f"memo {memo['id']}: attachment {f} not in manifest.images")
                referenced_images.add(f)
                if att.get("kind") != "photo":
                    errors.append(f"memo {memo['id']}: attachment kind must be 'photo' for image fixtures")
            body_text_all += memo["body"] + "\n"
        # Body UUID citations must resolve to real memos in this dataset.
        for cited in UUID_RE.findall(body_text_all):
            if cited.upper() not in valid_ids:
                errors.append(f"{rec['file']}: body cites unknown memo id {cited}")
        cover = rec.get("cover")
        if cover and cover not in body_text_all:
            errors.append(f"{rec['file']}: cover {cover} not cited in day body text")
        if cover and cover not in image_files:
            errors.append(f"{rec['file']}: cover {cover} not in manifest.images")
        daily_file = root / "wiki" / "daily" / (d + ".md")
        if not daily_file.is_file():
            errors.append(f"Daily wiki missing for {d}")
        else:
            daily_text = daily_file.read_text(encoding="utf-8")
            cited = re.findall(r"\[\^m:(" + UUID_RE.pattern + r")\]", daily_text)
            if (f"date: {d}\n" not in daily_text or
                    f"entries_count: {len(ids)}\n" not in daily_text or
                    f"cover: {cover}\n" not in daily_text or
                    not cited or any(mid not in ids for mid in cited)):
                errors.append(f"Daily wiki count/cover/citations mismatch for {d}")

    missing_ids = set(memo_by_id) - seen_ids
    for mid in sorted(missing_ids):
        errors.append(f"manifest memo {mid} not found in any day file")

    for img in sorted(image_files - referenced_images):
        errors.append(f"image never referenced by any memo attachment: {img}")

    # Query tokens: exact memo sets.
    for rec in manifest.get("expected_query_tokens", []):
        token = rec.get("token", "")
        listed = {i.upper() for i in rec.get("memo_ids", [])}
        found = token_index.get(token, set())
        if found != listed:
            errors.append(
                f"query token {token!r}: appears in memos {sorted(found)} but manifest lists {sorted(listed)}"
            )

    # Image dimensions + EXIF orientation (Pillow), corrupt fixtures.
    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - environment guard
        errors.append(f"Pillow unavailable, cannot verify image dimensions: {exc}")
        return errors

    kinds_seen = {"landscape": 0, "portrait": 0, "exif": 0, "large_4096": 0}
    for rec in images:
        p = root / rec.get("file", "")
        if not p.is_file():
            continue
        try:
            with Image.open(p) as im:
                w, h = im.size
                orientation = im.getexif().get(0x0112, 1)
        except Exception as exc:
            errors.append(f"image {rec.get('file')} does not decode: {exc}")
            continue
        if (w, h) != (rec.get("width"), rec.get("height")):
            errors.append(f"image {rec.get('file')}: dimensions {(w, h)} != manifest {(rec.get('width'), rec.get('height'))}")
        if orientation != rec.get("exif_orientation"):
            errors.append(
                f"image {rec.get('file')}: exif orientation {orientation} != manifest {rec.get('exif_orientation')}"
            )
        if w > h:
            kinds_seen["landscape"] += 1
        if h > w:
            kinds_seen["portrait"] += 1
        if orientation != 1:
            kinds_seen["exif"] += 1
        if max(w, h) == 4096:
            kinds_seen["large_4096"] += 1
        elif rec.get("kind") == "large_4096":
            errors.append(f"image {rec.get('file')}: kind large_4096 but max dim {max(w, h)}")
    if kinds_seen["large_4096"] != 1:
        errors.append(f"dataset must contain exactly one 4096px image, found {kinds_seen['large_4096']}")
    for need in ("landscape", "portrait", "exif"):
        if kinds_seen[need] < 1:
            errors.append(f"dataset must contain at least one {need} image")

    for rec in corrupt:
        rel = rec.get("file", "")
        if not check_rel_path(rel) or rel.startswith("raw/"):
            errors.append(f"corrupt fixture {rel!r} must live outside raw/ (kept separate from valid attachments)")
            continue
        if rel in referenced_images:
            errors.append(f"corrupt fixture {rel!r} must not be referenced by any attachment")
        p = root / rel
        if p.is_file():
            try:
                with Image.open(p) as im:
                    im.verify()
                errors.append(f"corrupt fixture {rel!r} unexpectedly decodes as a valid image")
            except Exception:
                pass  # expected: fixture must be undecodable

    return errors


# MARK: - generate command

def cmd_generate(args) -> int:
    output = Path(args.output)
    assert_no_symlinks(output)
    if output.exists() or output.is_symlink():
        raise QAToolError(f"refusing to overwrite existing output path: {output}")
    try:
        end = date.fromisoformat(args.end_date)
    except ValueError:
        raise QAToolError(f"--end-date must be YYYY-MM-DD, got {args.end_date!r}")
    files, manifest = build_dataset(args.seed, args.count, args.days, end, args.images)
    output.mkdir(parents=True)
    for rel, data in files.items():
        dest = output / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
    print(f"generated synthetic QA dataset in {output}")
    print(
        f"  days={manifest['counts']['days']} memos={manifest['counts']['memos']} "
        f"images={manifest['counts']['images']} corrupt_fixtures={manifest['counts']['corrupt_fixtures']}"
    )
    print(f"  manifest: {output / MANIFEST_NAME}")
    return EXIT_OK


# MARK: - validate command

def cmd_validate(args) -> int:
    root = Path(args.dataset)
    errors = validate_dataset(root)
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        print(f"validate: {len(errors)} problem(s) in {root}", file=sys.stderr)
        return EXIT_INVALID
    print(f"validate: OK ({root})")
    return EXIT_OK


# MARK: - import-vault command

def cmd_import_vault(args) -> int:
    dataset = Path(args.dataset)
    assert_no_symlinks(dataset)
    dataset = dataset.resolve()
    target = Path(args.target)
    assert_no_symlinks(target)
    if not dataset.is_dir():
        raise QAToolError(f"dataset directory not found: {dataset}")
    if target.exists() or target.is_symlink():
        raise QAToolError(
            f"refusing to import: target already exists (never overwrite): {target}"
        )
    assert_no_symlinks(dataset)

    manifest = json.loads((dataset / MANIFEST_NAME).read_text(encoding="utf-8"))
    for section in ("hashes",):
        for rel in manifest.get(section, {}):
            if not check_rel_path(rel):
                raise QAToolError(f"refusing unsafe traversal path in manifest: {rel!r}")
    for rec in manifest.get("days", []) + manifest.get("images", []):
        for key in ("file", "cover"):
            rel = rec.get(key)
            if rel and not check_rel_path(rel):
                raise QAToolError(f"refusing unsafe traversal path in manifest: {rel!r}")

    errors = validate_dataset(dataset)
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        raise QAToolError(f"dataset failed validation ({len(errors)} problem(s)); nothing imported")

    # Import only the canonical vault tree: raw/ day files + raw/assets.
    copied = 0
    target.mkdir(parents=True)
    try:
        for rel in sorted(manifest["hashes"]):
            if not rel.startswith(("raw/", "wiki/daily/")):
                continue  # corrupt fixtures stay out of the vault
            src = dataset / rel
            dest = target / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
            copied += 1
        (target / "raw" / "assets").mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise QAToolError(f"import failed midway: {exc}")
    print(f"imported {copied} raw file(s) into fresh vault {target}")
    print("  (manifest and fixtures/corrupt/ are intentionally NOT copied into the vault)")
    return EXIT_OK


# MARK: - upload-images command

def _multipart_body(filename: str, data: bytes):
    boundary = uuid.uuid4().hex
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: image/jpeg\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    return boundary, head + data + tail


def _is_local_host(hostname: str | None) -> bool:
    return hostname in ("localhost", "127.0.0.1", "::1")


def cmd_upload_images(args) -> int:
    import urllib.error
    import urllib.parse
    import urllib.request

    dataset = Path(args.dataset)
    assert_no_symlinks(dataset)
    dataset = dataset.resolve()
    endpoint = args.endpoint
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise QAToolError(f"--endpoint must be an absolute http(s) URL, got {endpoint!r}")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise QAToolError("endpoint must not contain credentials, query strings or fragments")
    if args.report:
        report_path = Path(args.report)
        assert_no_symlinks(report_path)
        if report_path.exists():
            raise QAToolError("upload report already exists; refusing duplicate run")
    if not _is_local_host(parsed.hostname) and not args.allow_remote_host:
        raise QAToolError(
            f"refusing remote host {parsed.hostname!r}; pass --allow-remote-host "
            "to explicitly authorize real network uploads"
        )

    auth_env = args.cookie_env or args.token_env
    token = os.environ.get(auth_env, "")
    if not token:
        raise QAToolError(f"upload credential env var {auth_env!r} is unset or empty")
    if "\r" in token or "\n" in token:
        raise QAToolError("credential contains an invalid header newline")
    if not _is_local_host(parsed.hostname) and parsed.scheme != "https":
        raise QAToolError("remote credentials require HTTPS")
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *unused):
            return None
    opener = urllib.request.build_opener(NoRedirect())
    receipts = []

    errors = validate_dataset(dataset)
    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        raise QAToolError(f"dataset failed validation ({len(errors)} problem(s)); nothing uploaded")

    manifest = json.loads((dataset / MANIFEST_NAME).read_text(encoding="utf-8"))
    images = manifest.get("images", [])
    if not images:
        raise QAToolError("dataset contains no images to upload")

    print(f"uploading {len(images)} image(s) to {endpoint}")
    failures = 0
    for rec in images:
        rel = rec["file"]
        data = (dataset / rel).read_bytes()
        boundary, body = _multipart_body(Path(rel).name, data)
        req = urllib.request.Request(
            endpoint,
            data=body,
            method="POST",
            headers={
                **({"Cookie": token} if args.cookie_env else {"Authorization": f"Bearer {token}"}),
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
                "User-Agent": "daypage-qa-batch-dataset/1",
            },
        )
        status = None
        payload = b""
        failure = None
        try:
            with opener.open(req, timeout=args.timeout) as resp:
                status = resp.status
                payload = resp.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            payload = exc.read()
            failure = f"HTTP {status}"
        except Exception as exc:  # URLError, timeout, connection errors
            failure = f"request failed: {type(exc).__name__}"

        if failure is None:
            if not (200 <= status < 300):
                failure = f"HTTP {status}"
            else:
                try:
                    parsed_body = json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    failure = f"HTTP {status} but body is not valid JSON"
                else:
                    name = parsed_body.get("filename", "") if isinstance(parsed_body, dict) else ""
                    if not (status == 201 and isinstance(parsed_body, dict)
                            and re.fullmatch(r"[0-9a-fA-F-]{36}\.jpg", name)
                            and parsed_body.get("url") == "/uploads/" + name
                            and parsed_body.get("original_filename") == Path(rel).name
                            and parsed_body.get("size") == len(data)
                            and parsed_body.get("mime_type") == "image/jpeg"):
                        failure = f"HTTP {status} but response is not a success object for DayPage /api/upload"
                    else:
                        try:
                            with opener.open(urllib.parse.urljoin(endpoint, parsed_body["url"]),
                                             timeout=args.timeout) as download:
                                downloaded = download.read(len(data) + 1)
                            if downloaded != data:
                                failure = "downloaded bytes differ from uploaded image"
                            else:
                                receipts.append({"file": rel, "status": status,
                                                 "url": parsed_body["url"], "bytes": len(data),
                                                 "sha256": hashlib.sha256(data).hexdigest()})
                        except Exception as exc:
                            failure = "download verification failed: " + type(exc).__name__
        if failure:
            failures += 1
            print(f"  FAIL {rel}: {failure}")
        else:
            print(f"  ok   {rel} (HTTP {status})")

    if args.report:
        report = Path(args.report)
        assert_no_symlinks(report)
        with report.open("x", encoding="utf-8") as f:
            json.dump({"endpoint": endpoint, "attempted": len(images),
                       "verified": len(receipts), "failed": failures,
                       "receipts": receipts}, f, indent=2)
    if failures:
        print(f"upload: {len(images) - failures}/{len(images)} uploaded, {failures} FAILED", file=sys.stderr)
        return EXIT_INVALID
    print(f"upload: all {len(images)} image(s) uploaded and responses verified")
    return EXIT_OK


# MARK: - CLI

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="batch_dataset.py",
        description="Synthetic DayPage bulk QA dataset tooling (see docs/engineering/batch-dataset.md)",
    )
    sub = p.add_subparsers(dest="command", required=True)

    g = sub.add_parser("generate", help="generate a deterministic synthetic dataset")
    g.add_argument("--output", required=True, help="output directory (must NOT exist; keep outside the repo)")
    g.add_argument("--count", required=True, type=int, help="total memo count (>= --days)")
    g.add_argument("--days", required=True, type=int, help="number of consecutive day files")
    g.add_argument("--end-date", required=True, help="last generated day, YYYY-MM-DD (inclusive)")
    g.add_argument("--seed", required=True, type=int, help="deterministic seed")
    g.add_argument("--images", type=int, default=24, help="JPEG count (default 24, >= max(5, days))")
    g.set_defaults(func=cmd_generate)

    v = sub.add_parser("validate", help="validate a generated dataset")
    v.add_argument("dataset", help="dataset directory")
    v.set_defaults(func=cmd_validate)

    i = sub.add_parser("import-vault", help="copy raw/ into a fresh (nonexistent) vault directory")
    i.add_argument("dataset", help="dataset directory")
    i.add_argument("--target", required=True, help="vault directory (must NOT exist; never overwritten)")
    i.set_defaults(func=cmd_import_vault)

    u = sub.add_parser("upload-images", help="POST raw/assets JPEGs to an explicit HTTP endpoint")
    u.add_argument("dataset", help="dataset directory")
    u.add_argument("--endpoint", required=True, help="absolute http(s) upload endpoint")
    auth = u.add_mutually_exclusive_group(required=True)
    auth.add_argument("--token-env", help="bearer token environment variable (custom test endpoint)")
    auth.add_argument("--cookie-env", help="Supabase session Cookie environment variable (DayPage Web)")
    u.add_argument("--report", help="new JSON receipt path; no credentials")
    u.add_argument("--allow-remote-host", action="store_true",
                   help="explicitly allow a non-localhost endpoint")
    u.add_argument("--timeout", type=float, default=30.0, help="per-request timeout seconds")
    u.set_defaults(func=cmd_upload_images)
    return p


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except QAToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
