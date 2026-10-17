#!/usr/bin/env python3
"""One-time flomo export → DayPage vault converter (stdlib only).

This is an operational, user-directed one-time import helper — not a product
feature or a release artifact. It converts a flomo export ZIP (root folder,
one UTF-8 HTML file, ``.memo`` divs with ``.time``/``.content``/``.files``,
an optional tag-filter ``<select>`` taxonomy) into the canonical DayPage
vault format:

    destination/vault/raw/YYYY-MM-DD.md
    destination/vault/raw/assets/flomo/<sha256>.<ext>
    destination/flomo-import-manifest.json   (ownership marker + audit manifest)

Module API::

    export = parse_export(zip_path, timezone="Asia/Shanghai")
    summary = write_vault(export, destination)          # or dry_run=True

CLI::

    python3 scripts/import_flomo.py --input export.zip --output staging \\
        [--timezone Asia/Shanghai] [--dry-run]

The CLI prints aggregate counts only: never note text, tag labels, or media
paths. ``--dry-run`` validates the whole export and the destination contract
without writing user data.

Fidelity contract (matches DayPageKit MemoMarkdown / RawStorage read path):
  * Markdown subset only: paragraphs, soft breaks, strong (**x**), nested
    lists with numbering, ``[label](url)`` links, inline code `` `x` `` and
    fenced code blocks, ``----`` dividers. No raw HTML ever reaches the body.
  * ``<u>``/``<mark>`` have no native Markdown semantics — their text is kept
    as supported ``**strong**`` emphasis and the adaptation is recorded in the
    manifest/summary (never leaked as literal ``__x__``/``==x==``).
  * The canonical ``<!-- daypage-memo-separator -->`` marker and ambiguous
    embedded legacy memo frontmatter are rejected with content-free errors.
    Ordinary Markdown ``---`` dividers are retained: RawStorage's legacy
    fallback accepts a split only when every chunk is a complete memo.
  * Literal structures we cannot represent (tables, forms, iframes, code
    containing fence-colliding lines, …) fail closed instead of being lost.

Security posture (fail closed on every violation):
  * ZIP entries: reject absolute paths, ``..`` (including percent-encoded and
    backslash variants), drive letters, URL schemes, control chars, symlinks
    and non-regular entries, conflicting normalized paths; bound entry count,
    per-entry size, total expansion, HTML node count and nesting depth.
  * Media/anchor references: relative media must resolve to files inside the
    ZIP (no implicit fetching). Anchors accept only http(s)/mailto and are
    never fetched. Only png/jpeg (photo), mov (file attachment — never an
    image) and m4a/aac (audio) are accepted.
  * Export chrome (script/style/button/svg/use, document head) is dropped —
    the export's scripts are never executed and never become note content.
  * Destination must be a new (or previously-owned, manifest-verified) import
    staging directory; symlinks anywhere in the destination tree are rejected
    before any read/write. Conflicts fail closed; unrelated data is never
    overwritten. Writes use same-directory temp files + fsync + atomic
    install; retries recover only owned ``*.flomo-import-tmp`` artifacts.

Import semantics:
  * IDs are stable UUIDv5 values derived from the original wall-clock
    timestamp + canonical content/media identity + an ordinal for truly
    identical duplicate memos — independent of the ZIP root folder, export
    day and non-duplicate memo order. All identical duplicates are preserved;
    retries are idempotent.
  * Audio attachments get NO transcription_status (nil/omitted): importing
    never creates an ASR queue job. Transcription is an explicit later user
    action.
  * ``#tags`` (hierarchical paths, CJK, emoji, punctuation like ``#C++``) are
    kept verbatim in the body and indexed from source text nodes; an export
    tag-filter ``<select>`` taxonomy is authoritative (longest-path matching)
    and retained in the manifest. Hashtags are never mapped to entity_mentions.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import hashlib
import json
import os
import posixpath
import re
import stat
import sys
import tempfile
import uuid
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# --------------------------------------------------------------------------
# Contract constants
# --------------------------------------------------------------------------

MANIFEST_NAME = "flomo-import-manifest.json"
MANIFEST_FORMAT = "daypage-flomo-import"
MANIFEST_VERSION = 1
SEPARATOR = "\n\n<!-- daypage-memo-separator -->\n\n"
SEPARATOR_TOKEN = "<!-- daypage-memo-separator -->"
LEGACY_SEPARATOR = "\n\n---\n\n"
DEVICE = "flomo import"
ASSET_DIR = "raw/assets/flomo"  # vault-relative, must stay under raw/assets/
TEMP_SUFFIX = ".flomo-import-tmp"

# ZIP / HTML expansion bounds (module-level so tests can tighten them).
MAX_ZIP_ENTRIES = 100_000
MAX_ENTRY_BYTES = 200 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_HTML_NODES = 200_000
MAX_HTML_DEPTH = 200

# Known export media. mov is deliberately a *file* attachment (never photo).
_EXT_KIND = {
    "png": "photo",
    "jpg": "photo",
    "jpeg": "photo",
    "mov": "file",
    "m4a": "audio",
    "aac": "audio",
}
_ELEMENT_KINDS = {
    "img": {"photo", "file"},
    "audio": {"audio"},
    "source": {"audio"},
}
# "Unsupported cloud media": imported faithfully but reported for later
# account-level transport (thumbnail/transcode/transcription) by the parent.
UNSUPPORTED_CLOUD_EXTS = ("mov", "aac")

# Export chrome: dropped wholesale, never note content, never executed.
_CHROME_TAGS = {
    "script", "style", "button", "svg", "use", "head", "title", "meta", "link",
    "noscript", "template",
}
_VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
}
_BLOCK_TAGS = {
    "p", "div", "section", "article", "blockquote", "pre",
    "h1", "h2", "h3", "h4", "h5", "h6",
}
# Literal structures with no portable Markdown representation: fail closed
# instead of silently dropping them or leaking raw HTML.
_UNSUPPORTED_CONTENT_TAGS = {
    "table", "form", "input", "textarea", "select", "iframe", "object",
    "embed", "canvas", "video", "details", "summary",
}

_ID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "daypage.flomo.import.v1")

_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*:")
_DRIVE_RE = re.compile(r"^[A-Za-z]:")

# Tag extraction: '#' starts a tag at stream start / whitespace / after
# sentence punctuation; the body runs until the next terminator. This keeps
# #C++, #parent/child, CJK and emoji intact while discarding surrounding
# sentence punctuation (。 ， . , …) and never matching URL #fragments or
# code content (excluded from the stream).
# Foundation CharacterSet.whitespacesAndNewlines (Memo.fromMarkdown trims
# these at record edges); notably includes U+200B, unlike Python str.strip.
_NATIVE_EDGE_WHITESPACE = "".join(chr(code) for code in (
    9, 10, 11, 12, 13, 32, 133, 160, 5760,
    *range(8192, 8204), 8232, 8233, 8239, 8287, 12288,
))
_TAG_TERMINATORS = set(_NATIVE_EDGE_WHITESPACE) | set(
    " \t\n\r.,;:!?，。、；：！？…·—–~()（）【】[]{}｛｝<>《》〈〉「」『』“”‘’\"'«»#"
)

_ADAPTATION_KEYS = (
    "underline_to_strong",
    "highlight_to_strong",
    "code_blocks",
    "code_spans",
    "code_spans_to_plain",
    "anchor_links",
    "native_edge_whitespace",
)


# --------------------------------------------------------------------------
# Errors and data model
# --------------------------------------------------------------------------

class FlomoImportError(Exception):
    """Base class: any condition that must fail the import closed.

    Messages are deliberately content-free: they never embed note text, tag
    labels, media paths or URLs.
    """


class SecurityError(FlomoImportError):
    """Unsafe ZIP entry, media reference, or destination path."""


class ParseError(FlomoImportError):
    """Export shape or body content is not safely importable."""


class ConflictError(FlomoImportError):
    """Destination ownership or content conflict; nothing is overwritten."""


@dataclasses.dataclass(frozen=True)
class Attachment:
    file: str                     # vault-relative: raw/assets/flomo/<sha>.<ext>
    kind: str                     # photo | audio | file
    original_filename: str
    sha256: str
    size: int
    ext: str
    source_entry: str             # ZIP entry name (never printed)
    duration: float | None = None
    # Import never fabricates an ASR queue job; nil unless a real transcript
    # exists (it never does for a flomo export).
    transcription_status: str | None = None
    unsupported_cloud_media: bool = False


@dataclasses.dataclass(frozen=True)
class Memo:
    id: str
    type: str                     # text | voice | photo | mixed
    created: datetime.datetime    # timezone-aware
    created_raw: str              # original .time text (stability anchor)
    body: str                     # Markdown, never raw HTML
    tags: tuple
    attachments: tuple
    source_index: int             # document order inside the export

    @property
    def day(self) -> str:
        return self.created.strftime("%Y-%m-%d")


@dataclasses.dataclass(frozen=True)
class Export:
    zip_path: str
    timezone: str
    html_entry: str
    memos: tuple
    tag_catalog: tuple            # authoritative taxonomy (may be empty)
    adaptations: dict             # formatting adaptation counts


@dataclasses.dataclass
class ImportSummary:
    memo_count: int
    day_count: int
    type_counts: dict
    attachment_counts: dict
    duplicate_memo_count: int
    unique_tag_count: int
    unsupported_cloud_media_counts: dict
    formatting_adaptations: dict
    files_written: int
    files_unchanged: int
    dry_run: bool


# --------------------------------------------------------------------------
# Safe ZIP handling
# --------------------------------------------------------------------------

def _validate_name(name: str) -> None:
    """Reject absolute/.. /drive/scheme/encoded-traversal/control-char names."""
    if not name or "\x00" in name:
        raise SecurityError("unsafe zip entry name")
    if any(ord(ch) < 0x20 for ch in name):
        raise SecurityError("unsafe zip entry name")
    for candidate in (name, unquote(name), unquote(unquote(name))):
        cleaned = candidate.replace("\\", "/")
        if not cleaned or "\x00" in cleaned:
            raise SecurityError("unsafe zip entry name")
        if any(ord(ch) < 0x20 for ch in cleaned):
            raise SecurityError("unsafe zip entry name")
        if cleaned.startswith("/") or cleaned.startswith("//"):
            raise SecurityError("absolute zip entry path rejected")
        if _DRIVE_RE.match(cleaned):
            raise SecurityError("drive-letter zip entry path rejected")
        if _SCHEME_RE.match(cleaned):
            raise SecurityError("url-scheme zip entry path rejected")
        if any(seg == ".." for seg in cleaned.split("/")):
            raise SecurityError("traversal zip entry path rejected")


def _normalized(name: str) -> str:
    cleaned = name.replace("\\", "/")
    norm = posixpath.normpath(cleaned)
    if norm.startswith("..") or norm.startswith("/"):
        raise SecurityError("unsafe zip entry name")
    return norm


def _scan_zip(zf: zipfile.ZipFile) -> dict:
    infos = zf.infolist()
    if len(infos) > MAX_ZIP_ENTRIES:
        raise SecurityError("zip entry count exceeds bound")
    entries: dict = {}
    total = 0
    for info in infos:
        mode = (info.external_attr >> 16) & 0o170000
        if mode == 0o120000:
            raise SecurityError("symlink zip entry rejected")
        if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SecurityError("non-regular zip entry rejected")
        if info.file_size > MAX_ENTRY_BYTES:
            raise SecurityError("zip entry exceeds size bound")
        total += info.file_size
        if total > MAX_TOTAL_BYTES:
            raise SecurityError("zip total expansion exceeds bound")
        _validate_name(info.filename)
        if info.is_dir():
            continue
        norm = _normalized(info.filename)
        if norm in entries:
            raise SecurityError("conflicting normalized zip paths")
        entries[norm] = info
    return entries


# --------------------------------------------------------------------------
# HTML tree parsing (html.parser based; no regex HTML parsing)
# --------------------------------------------------------------------------

class _Node:
    __slots__ = ("tag", "attrs", "children")

    def __init__(self, tag: str, attrs: dict | None = None) -> None:
        self.tag = tag
        self.attrs = attrs or {}
        self.children: list = []

    def classes(self) -> set:
        return set((self.attrs.get("class") or "").split())

    def descendants(self):
        for child in self.children:
            if isinstance(child, _Node):
                yield child
                yield from child.descendants()


class _TreeParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = _Node("#document")
        self._stack = [self.root]
        self._nodes = 0

    def _in_chrome(self) -> bool:
        return any(node.tag in _CHROME_TAGS for node in self._stack)

    def _track(self) -> None:
        self._nodes += 1
        if self._nodes > MAX_HTML_NODES:
            raise SecurityError("html node count exceeds bound")
        if len(self._stack) > MAX_HTML_DEPTH:
            raise SecurityError("html nesting depth exceeds bound")

    def handle_starttag(self, tag, attrs):
        self._track()
        # HTML auto-close rules for common export markup: <li> closes the
        # previous sibling <li>; block starts close an open <p>. This keeps
        # optional closing tags from merging sibling items. Applied BEFORE
        # appending so the new node lands under the right parent.
        if tag == "li":
            while self._stack[-1].tag == "li":
                self._stack.pop()
        elif tag in _BLOCK_TAGS or tag in ("ol", "ul", "li"):
            while self._stack[-1].tag == "p":
                self._stack.pop()
        node = _Node(tag, dict(attrs))
        self._stack[-1].children.append(node)
        if tag not in _VOID_TAGS:
            self._stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self._track()
        self._stack[-1].children.append(_Node(tag, dict(attrs)))

    def handle_endtag(self, tag):
        for i in range(len(self._stack) - 1, 0, -1):
            if self._stack[i].tag == tag:
                del self._stack[i:]
                return

    def handle_data(self, data):
        if self._in_chrome():
            return
        self._stack[-1].children.append(data)


# --------------------------------------------------------------------------
# Markdown rendering (content is preserved; never raw HTML)
# --------------------------------------------------------------------------

def _normalize_inline(text: str) -> str:
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{2,}", "\n", text)
    return text.strip()


def _assert_no_fence_collision(text: str) -> None:
    """Native MemoMarkdown toggles a code fence on any line whose trimmed form
    starts with ```; such lines can never live safely beside our fences."""
    for line in text.split("\n"):
        if line.strip().startswith("```"):
            raise ParseError("body line collides with code fence syntax")


def _wrap(inner: str, marker: str) -> str:
    return f"{marker}{inner}{marker}" if inner.strip() else inner


def _pre_text(node: _Node) -> str:
    """Exact text content of a <pre> block (entities decoded, br → newline)."""
    parts: list = []

    def walk(n: _Node) -> None:
        for child in n.children:
            if isinstance(child, str):
                parts.append(child)
            elif child.tag == "br":
                parts.append("\n")
            elif child.tag not in _CHROME_TAGS:
                walk(child)

    walk(node)
    text = "".join(parts)
    if text.startswith("\n"):  # HTML: a newline right after <pre> is dropped
        text = text[1:]
    return text


def _render_pre(node: _Node, stats: dict) -> str:
    text = _pre_text(node)
    _assert_no_fence_collision(text)
    stats["code_blocks"] += 1
    tail = "" if text.endswith("\n") else "\n"
    return "```\n" + text + tail + "```"


def _render_code(node: _Node, stats: dict) -> str:
    text = _pre_text(node)
    if not text.strip():
        return text
    if "`" in text:
        # Native code spans are single-backtick pairs; multi-backtick spans do
        # not round-trip. Keep the text plainly instead of leaking markers.
        stats["code_spans_to_plain"] += 1
        return text
    stats["code_spans"] += 1
    return f"`{text}`"


def _render_anchor(node: _Node, stats: dict) -> str:
    href = (node.attrs.get("href") or "").strip()
    label = _render_inline(node, stats)
    if not href:
        return label
    lower = href.lower()
    if not (lower.startswith("https://") or lower.startswith("http://")
            or lower.startswith("mailto:")):
        raise SecurityError("unsafe or unsupported link destination rejected")
    url = href.replace("(", "%28").replace(")", "%29").replace(" ", "%20")
    if not label.strip():
        label = url
    label = label.replace("[", "\\[").replace("]", "\\]")
    stats["anchor_links"] += 1
    return f"[{label}]({url})"


def _render_inline_child(child, stats: dict) -> str:
    """Render one inline child (text or element) with tag dispatch."""
    if isinstance(child, str):
        return child
    if child.tag == "br":
        return "\n"
    if child.tag in ("strong", "b"):
        return _wrap(_render_inline(child, stats), "**")
    if child.tag == "u":
        inner = _render_inline(child, stats)
        if inner.strip():
            stats["underline_to_strong"] += 1
        return _wrap(inner, "**")
    if child.tag == "mark":
        inner = _render_inline(child, stats)
        if inner.strip():
            stats["highlight_to_strong"] += 1
        return _wrap(inner, "**")
    if child.tag == "code":
        return _render_code(child, stats)
    if child.tag == "a":
        return _render_anchor(child, stats)
    return _render_inline(child, stats)


def _render_inline(node: _Node, stats: dict) -> str:
    return "".join(_render_inline_child(child, stats) for child in node.children)


def _render_blocks(node: _Node, stats: dict) -> list:
    blocks: list = []
    buf: list = []

    def flush() -> None:
        text = _normalize_inline("".join(buf))
        if text:
            _assert_no_fence_collision(text)
            blocks.append(text)
        buf.clear()

    for child in node.children:
        if isinstance(child, str):
            buf.append(child)
        elif child.tag in _BLOCK_TAGS:
            flush()
            if child.tag == "pre":
                blocks.append(_render_pre(child, stats))
            else:
                blocks.extend(_render_blocks(child, stats))
        elif child.tag == "hr":
            flush()
            blocks.append("----")
        elif child.tag in ("ol", "ul"):
            flush()
            block = _render_list(child, stats, 0)
            _assert_no_fence_collision(block)
            blocks.append(block)
        else:
            buf.append(_render_inline_child(child, stats))
    flush()
    return blocks


def _render_list(node: _Node, stats: dict, depth: int) -> str:
    ordered = node.tag == "ol"
    try:
        start = int(node.attrs.get("start") or 1)
    except (TypeError, ValueError):
        start = 1
    try:
        digits = int(node.attrs.get("data-digits") or 0)
    except (TypeError, ValueError):
        digits = 0
    prefix = "    " * depth
    lines: list = []
    counter = start
    for child in node.children:
        if not (isinstance(child, _Node) and child.tag == "li"):
            continue
        if ordered:
            marker = f"{counter:0{digits}d}. " if digits > 0 else f"{counter}. "
            counter += 1
        else:
            marker = "- "
        nested = [c for c in child.children
                  if isinstance(c, _Node) and c.tag in ("ol", "ul")]
        content = _Node("#fragment")
        content.children = [c for c in child.children
                            if not (isinstance(c, _Node) and c.tag in ("ol", "ul"))]
        item_blocks = _render_blocks(content, stats)
        cont = prefix + " " * len(marker)
        if not item_blocks:
            lines.append((prefix + marker).rstrip())
        else:
            first = True
            for block in item_blocks:
                for line in block.split("\n"):
                    if first:
                        lines.append(prefix + marker + line)
                        first = False
                    else:
                        lines.append(cont + line)
        for nested_list in nested:
            lines.append(_render_list(nested_list, stats, depth + 1))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Tag extraction (source text nodes, before Markdown formatting)
# --------------------------------------------------------------------------

def _text_stream(node: _Node) -> str:
    """Raw inline text of the content node, in document order, excluding code
    and chrome. Formatting markers are not present yet, so hashtags wrapped in
    <strong>/<u>/<mark> are still extractable."""
    parts: list = []

    def walk(n: _Node) -> None:
        for child in n.children:
            if isinstance(child, str):
                parts.append(child)
            elif child.tag == "br":
                parts.append("\n")
            elif child.tag in ("pre", "code") or child.tag in _CHROME_TAGS:
                parts.append("\n")
                continue
            else:
                boundary = child.tag in _BLOCK_TAGS or child.tag in ("ul", "ol", "li")
                if boundary:
                    parts.append("\n")
                walk(child)
                if boundary:
                    parts.append("\n")

    walk(node)
    return "".join(parts)


def _scan_tags(stream: str, catalog: tuple = ()) -> list:
    out: list = []
    known = sorted(catalog, key=lambda label: (-len(label), label))
    i, n = 0, len(stream)
    while i < n:
        if stream[i] == "#":
            prev = stream[i - 1] if i > 0 else ""
            if prev == "" or prev.isspace() or prev in _TAG_TERMINATORS:
                match = next((label for label in known
                              if stream.startswith(label, i)
                              and (i + len(label) == n
                                   or stream[i + len(label)] in _TAG_TERMINATORS)), None)
                if match is not None:
                    out.append(match)
                    i += len(match)
                    continue
                j = i + 1
                while j < n and stream[j] not in _TAG_TERMINATORS:
                    j += 1
                if j > i + 1:
                    out.append(stream[i:j])
                    i = j
                    continue
        i += 1
    return out


def _collect_taxonomy(root: _Node) -> tuple:
    """Authoritative tag labels from an export tag-filter <select> taxonomy."""
    catalog: set = set()
    for node in root.descendants():
        if node.tag != "select":
            continue
        is_tag_filter = any("tag" in node.attrs.get(key, "").lower()
                            for key in ("id", "name", "class"))
        for opt in node.descendants():
            if opt.tag == "option":
                val = (opt.attrs.get("value") or "").strip()
                if val and (is_tag_filter or val.startswith("#")):
                    label = "#" + val.lstrip("#")
                    if len(label) > 1:
                        catalog.add(label)
    return tuple(sorted(catalog))


# --------------------------------------------------------------------------
# Memo parsing
# --------------------------------------------------------------------------

def _node_text(node: _Node) -> str:
    parts: list = []

    def walk(n: _Node) -> None:
        for child in n.children:
            if isinstance(child, str):
                parts.append(child)
            elif child.tag == "br":
                parts.append("\n")
            else:
                walk(child)

    walk(node)
    return re.sub(r"\s+", " ", "".join(parts)).strip()


def _first_with_class(node: _Node, tag: str, cls: str):
    for desc in node.descendants():
        if desc.tag == tag and cls in desc.classes():
            return desc
    return None


def _find_memos(root: _Node) -> list:
    return [n for n in root.descendants()
            if n.tag == "div" and "memo" in n.classes()]


def _validate_media_ref(ref: str) -> str:
    ref = (ref or "").strip()
    if not ref:
        raise SecurityError("empty media reference")
    for candidate in (ref, unquote(ref), unquote(unquote(ref))):
        cleaned = candidate.replace("\\", "/")
        if not cleaned or "\x00" in cleaned:
            raise SecurityError("unsafe media reference")
        if cleaned.startswith("//") or _SCHEME_RE.match(cleaned):
            raise SecurityError("external or unsafe media reference rejected")
        if cleaned.startswith("/"):
            raise SecurityError("absolute media reference rejected")
        if any(seg == ".." for seg in cleaned.split("/")):
            raise SecurityError("traversal media reference rejected")
    return ref


def _resolve_media_ref(ref: str, html_dir: str, entries: dict) -> str:
    ref = _validate_media_ref(ref)
    for candidate in (ref, unquote(ref)):
        joined = posixpath.join(html_dir, candidate.replace("\\", "/")) if html_dir \
            else candidate.replace("\\", "/")
        resolved = posixpath.normpath(joined)
        if resolved.startswith("..") or resolved.startswith("/"):
            raise SecurityError("traversal media reference rejected")
        if resolved in entries:
            return resolved
    raise ParseError("referenced media file is missing from the export")


def _collect_media(memo_node: _Node, files_node, html_dir: str,
                   entries: dict, zf: zipfile.ZipFile) -> tuple:
    refs: list = []  # (element_tag, resolved_entry, raw zip name)

    # Media inside .files
    if files_node is not None:
        for node in files_node.descendants():
            if node.tag in ("img", "audio", "source"):
                src = node.attrs.get("src")
                if src:
                    resolved = _resolve_media_ref(src, html_dir, entries)
                    refs.append((node.tag, resolved, entries[resolved].filename))
            elif node.tag in ("video",):
                raise ParseError("unsupported media element in export")
            elif node.tag not in _CHROME_TAGS and node.attrs.get("src"):
                raise ParseError("unsupported media element in export")

    # Media elsewhere in the memo is unsupported export chrome → fail closed.
    outside = _Node("#fragment")
    outside.children = [c for c in memo_node.children if c is not files_node]
    for node in outside.descendants():
        if node.tag in ("img", "audio", "video", "source") and node.attrs.get("src"):
            raise ParseError("media reference outside files div")

    attachments: list = []
    seen: set = set()
    for element_tag, entry_name, raw_name in refs:
        base = posixpath.basename(entry_name)
        if "." not in base:
            raise ParseError("media without file extension")
        ext = base.rsplit(".", 1)[1].lower()
        kind = _EXT_KIND.get(ext)
        if kind is None:
            raise ParseError("unsupported media extension")
        if kind not in _ELEMENT_KINDS.get(element_tag, set()):
            raise ParseError("media kind is not valid for its export element")
        if entry_name in seen:
            continue
        seen.add(entry_name)
        data = zf.read(entries[entry_name])
        digest = hashlib.sha256(data).hexdigest()
        attachments.append(Attachment(
            file=f"{ASSET_DIR}/{digest}.{ext}",
            kind=kind,
            original_filename=base,
            sha256=digest,
            size=len(data),
            ext=ext,
            source_entry=raw_name,
            transcription_status=None,
            unsupported_cloud_media=ext in UNSUPPORTED_CLOUD_EXTS,
        ))
    return tuple(attachments)


def _classify_type(body: str, attachments) -> str:
    cats: set = set()
    if body:
        cats.add("text")
    for att in attachments:
        cats.add({"photo": "photo", "audio": "voice", "file": "file"}[att.kind])
    if cats <= {"text"}:
        return "text"
    if cats == {"photo"}:
        return "photo"
    if cats == {"voice"}:
        return "voice"
    return "mixed"


_MEDIA_LABELS = {"photo": "Photo", "audio": "Audio", "file": "File"}


def _media_link_body(attachments) -> str:
    return "\n".join(
        f"[{_MEDIA_LABELS[a.kind]} attachment: {a.original_filename}]({a.file})"
        for a in attachments
    )


def _assert_body_safe(body: str) -> None:
    """Reject reserved delimiters before anything can be written: RawStorage
    splits memo blocks on the canonical separator unconditionally and may
    split a one-memo day on the legacy delimiter."""
    if SEPARATOR_TOKEN in body:
        raise ParseError("body contains the reserved daypage separator marker")
    # Ordinary Markdown dividers are safe: RawStorage accepts a legacy split
    # only when EVERY chunk is an independently parseable memo. Refuse the
    # ambiguous embedded-frontmatter case without rejecting normal prose.
    if LEGACY_SEPARATOR in body:
        for chunk in body.split(LEGACY_SEPARATOR)[1:]:
            if chunk.lstrip().startswith("---") and re.search(
                    r"(?m)^\s*id:\s*[\"']?[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}",
                    chunk):
                raise ParseError("body contains ambiguous legacy memo frontmatter")


# --------------------------------------------------------------------------
# parse_export
# --------------------------------------------------------------------------

def parse_export(zip_path, timezone: str = "Asia/Shanghai") -> Export:
    """Parse a flomo export ZIP into structured data. Fails closed on any
    unsupported input, unsafe entry/reference, or shape deviation."""
    try:
        tz = ZoneInfo(timezone)
    except (ZoneInfoNotFoundError, ValueError, KeyError, OSError) as exc:
        raise FlomoImportError("invalid timezone") from exc

    zip_path = str(zip_path)
    try:
        zf = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError) as exc:
        raise ParseError("cannot read export zip") from exc

    with zf:
        entries = _scan_zip(zf)
        html_entries = sorted(
            name for name in entries
            if name.lower().endswith((".html", ".htm"))
        )
        if len(html_entries) != 1:
            raise ParseError(
                f"expected exactly one HTML file in export, found {len(html_entries)}")
        html_entry = html_entries[0]
        raw = zf.read(entries[html_entry])
        if len(raw) > MAX_ENTRY_BYTES:
            raise SecurityError("html entry exceeds size bound")
        try:
            html_text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ParseError("export HTML is not valid UTF-8") from exc

        parser = _TreeParser()
        parser.feed(html_text)
        parser.close()

        catalog = _collect_taxonomy(parser.root)
        memo_nodes = _find_memos(parser.root)
        if not memo_nodes:
            raise ParseError("no memos found in export HTML")

        html_dir = posixpath.dirname(html_entry)
        pending: list = []
        identities: dict = {}
        adaptations = {key: 0 for key in _ADAPTATION_KEYS}
        for index, memo_node in enumerate(memo_nodes):
            time_node = _first_with_class(memo_node, "div", "time")
            if time_node is None:
                raise ParseError("memo without .time element")
            created_raw = _node_text(time_node)
            try:
                naive = datetime.datetime.strptime(created_raw, "%Y-%m-%d %H:%M:%S")
            except ValueError as exc:
                raise ParseError("unsupported memo timestamp") from exc
            created = naive.replace(tzinfo=tz)

            content_node = _first_with_class(memo_node, "div", "content")
            body = ""
            tags_source = ""
            if content_node is not None:
                for desc in content_node.descendants():
                    if desc.tag in _UNSUPPORTED_CONTENT_TAGS:
                        raise ParseError("unsupported structure in memo content")
                stats = {key: 0 for key in _ADAPTATION_KEYS}
                blocks = _render_blocks(content_node, stats)
                body = "\n\n".join(blocks)
                tags_source = _text_stream(content_node)
                for key in _ADAPTATION_KEYS:
                    adaptations[key] += stats[key]

            files_node = _first_with_class(memo_node, "div", "files")
            attachments = _collect_media(
                memo_node, files_node, html_dir, entries, zf)

            normalized_body = body.strip(_NATIVE_EDGE_WHITESPACE)
            adaptations["native_edge_whitespace"] += len(body) - len(normalized_body)
            body = normalized_body
            real_body = body  # normalized original content, before generated links
            _assert_body_safe(body)
            if not body and attachments:
                body = _media_link_body(attachments)
            _assert_body_safe(body)

            tags = tuple(_scan_tags(tags_source, catalog))

            identity = (
                created_raw,
                body,
                tuple((a.sha256, a.kind, a.ext) for a in attachments),
            )
            ordinal = identities.get(identity, 0)
            identities[identity] = ordinal + 1
            id_name = "\x1f".join([
                created_raw,
                body,
                ",".join(f"{a.sha256}:{a.kind}" for a in attachments),
                str(ordinal),
            ])
            memo_id = str(uuid.uuid5(_ID_NAMESPACE, id_name))

            pending.append(Memo(
                id=memo_id,
                type=_classify_type(real_body, attachments),
                created=created,
                created_raw=created_raw,
                body=body,
                tags=tags,
                attachments=attachments,
                source_index=index,
            ))

    return Export(
        zip_path=zip_path,
        timezone=timezone,
        html_entry=html_entry,
        memos=tuple(pending),
        tag_catalog=catalog,
        adaptations=adaptations,
    )


# --------------------------------------------------------------------------
# write_vault
# --------------------------------------------------------------------------

def _memo_block(memo: Memo) -> str:
    lines = [
        "---",
        f"id: {memo.id}",
        f"type: {memo.type}",
        f"created: {memo.created.isoformat(timespec='milliseconds')}",
        f'device: "{DEVICE}"',
        "entity_mentions: []",
    ]
    if not memo.attachments:
        lines.append("attachments: []")
    else:
        lines.append("attachments:")
        for att in memo.attachments:
            lines.append(f'  - file: "{att.file}"')
            lines.append(f"    kind: {att.kind}")
            if att.duration is not None:
                lines.append(f"    duration: {att.duration}")
            if att.transcription_status is not None:
                lines.append(f"    transcription_status: {att.transcription_status}")
    lines.append("---")
    lines.append("")
    return "\n".join(lines) + "\n" + memo.body


def _build_plan(export: Export):
    """Return (day_files, asset_files) as {rel_path: bytes} plus aggregate data."""
    by_day: dict = {}
    for memo in sorted(export.memos, key=lambda m: (m.created_raw, m.source_index)):
        by_day.setdefault(memo.day, []).append(memo)

    day_files: dict = {}
    for day, memos in sorted(by_day.items()):
        blocks = [_memo_block(m) for m in memos]
        day_files[f"vault/raw/{day}.md"] = (
            SEPARATOR.join(blocks) + "\n").encode("utf-8")

    asset_files: dict = {}
    attachment_records: dict = {}
    with zipfile.ZipFile(export.zip_path) as zf:
        for memo in export.memos:
            for att in memo.attachments:
                data = zf.read(att.source_entry)
                digest = hashlib.sha256(data).hexdigest()
                if digest != att.sha256:
                    raise FlomoImportError("media bytes failed sha256 validation")
                rel = f"vault/{att.file}"
                asset_files[rel] = data
                attachment_records.setdefault(att.file, {
                    "file": att.file,
                    "kind": att.kind,
                    "original_filename": att.original_filename,
                    "sha256": att.sha256,
                    "size": att.size,
                    "unsupported_cloud_media": att.unsupported_cloud_media,
                })

    tag_index: dict = {}
    for memo in export.memos:
        for tag in memo.tags:
            tag_index[tag] = tag_index.get(tag, 0) + 1

    return day_files, asset_files, by_day, attachment_records, tag_index


def _build_manifest(export: Export, day_files, asset_files, by_day,
                    attachment_records, tag_index) -> dict:
    with open(export.zip_path, "rb") as fh:
        zip_digest = hashlib.sha256(fh.read()).hexdigest()

    type_counts = {"text": 0, "voice": 0, "photo": 0, "mixed": 0}
    attachment_counts = {"photo": 0, "audio": 0, "file": 0}
    unsupported: dict = {}
    identity_seen: dict = {}
    duplicate_count = 0
    for memo in export.memos:
        type_counts[memo.type] += 1
        identity = (memo.created_raw, memo.body,
                    tuple((a.sha256, a.kind) for a in memo.attachments))
        if identity_seen.get(identity, 0) > 0:
            duplicate_count += 1
        identity_seen[identity] = identity_seen.get(identity, 0) + 1
        for att in memo.attachments:
            attachment_counts[att.kind] += 1
            if att.unsupported_cloud_media:
                unsupported[att.ext] = unsupported.get(att.ext, 0) + 1

    files = [
        {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
        for path, data in sorted({**day_files, **asset_files}.items())
    ]
    memos = [
        {
            "id": m.id,
            "created": m.created.isoformat(timespec="milliseconds"),
            "type": m.type,
            "day": m.day,
            "tags": list(m.tags),
        }
        for m in sorted(export.memos, key=lambda m: (m.created_raw, m.id))
    ]
    return {
        "format": MANIFEST_FORMAT,
        "version": MANIFEST_VERSION,
        "timezone": export.timezone,
        "source_zip_sha256": zip_digest,
        "counts": {
            "memos": len(export.memos),
            "days": len(by_day),
            "types": type_counts,
            "attachments": attachment_counts,
            "duplicate_memos": duplicate_count,
            "unique_tags": len(tag_index),
        },
        "tag_index": tag_index,
        "tag_catalog": list(export.tag_catalog),
        "formatting_adaptations": dict(export.adaptations),
        "unsupported_cloud_media": unsupported,
        "memos": memos,
        "attachments": [attachment_records[k] for k in sorted(attachment_records)],
        "files": files,
    }


def _manifest_bytes(manifest: dict) -> bytes:
    return (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n").encode("utf-8")


def _validated_temps(target: Path, expected: bytes) -> list:
    candidates = set(target.parent.glob(f".{target.name}.*{TEMP_SUFFIX}"))
    legacy = target.with_name(f".{target.name}{TEMP_SUFFIX}")
    if legacy.exists() or legacy.is_symlink():
        candidates.add(legacy)
    for candidate in candidates:
        try:
            fd = os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError as exc:
            raise SecurityError("unsafe import temporary file") from exc
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise SecurityError("non-regular import temporary file")
            if stream.read(len(expected) + 1) != expected:
                raise ConflictError("temporary file does not belong to this import")
    return sorted(candidates)


def _check_destination(destination: Path, manifest: dict) -> None:
    if not destination.exists():
        return
    if not destination.is_dir():
        raise ConflictError("destination exists and is not a directory")
    manifest_path = destination / MANIFEST_NAME
    if manifest_path.exists():
        try:
            existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ConflictError("destination manifest is unreadable") from exc
        if existing != manifest:
            raise ConflictError(
                "destination belongs to a different import; refusing to mix")
        return
    entries = set(destination.iterdir())
    if entries and entries == set(_validated_temps(manifest_path, _manifest_bytes(manifest))):
        return  # First manifest installation was interrupted; exact bytes prove ownership.
    if entries:
        raise ConflictError(
            "destination is a non-empty directory without an import manifest; "
            "refusing to write into an unowned vault")


def _safe_path(destination: Path, rel: str) -> Path:
    """Reject symlinks anywhere from the destination down to ``rel`` and
    verify the resolved target stays inside the owned destination."""
    cur = destination
    for part in Path(rel).parts:
        cur = cur / part
        if cur.is_symlink():
            raise SecurityError("symlink in destination tree rejected")
    target = destination / rel
    dest_real = os.path.realpath(destination)
    real = os.path.realpath(target)
    if real != os.path.normpath(os.path.join(dest_real, rel)):
        raise SecurityError("destination path escapes the owned staging directory")
    return target


def _fsync_dir(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _atomic_write(target: Path, data: bytes) -> None:
    """Exclusive private temp + fsync + atomic no-overwrite installation."""
    fd, name = tempfile.mkstemp(prefix=f".{target.name}.", suffix=TEMP_SUFFIX,
                                dir=target.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(tmp, target)
        except FileExistsError as exc:
            raise ConflictError("target appeared during import; refusing to overwrite") from exc
        _fsync_dir(target.parent)
    finally:
        if tmp.exists():
            tmp.unlink()


def write_vault(export: Export, destination, dry_run: bool = False) -> ImportSummary:
    """Write (or validate, with dry_run) the export into an import staging dir.

    Destination must be new/empty or previously owned (identical manifest).
    Idempotent: retries verify the owned manifest and identical content,
    recover owned temp artifacts and finish interrupted imports; conflicts
    fail closed and never overwrite unrelated data.
    """
    destination = Path(destination)
    if destination.is_symlink():
        raise SecurityError("symlink destination rejected")

    day_files, asset_files, by_day, attachment_records, tag_index = _build_plan(export)
    manifest = _build_manifest(export, day_files, asset_files, by_day,
                               attachment_records, tag_index)
    managed = sorted({**day_files, **asset_files})

    # Fail closed on any symlink escape BEFORE reading or writing anything.
    targets = {rel: _safe_path(destination, rel) for rel in managed}
    manifest_path = _safe_path(destination, MANIFEST_NAME)

    # Ownership/conflict validation before any write.
    _check_destination(destination, manifest)
    recoverable = _validated_temps(manifest_path, _manifest_bytes(manifest))
    for rel, data in {**day_files, **asset_files}.items():
        recoverable.extend(_validated_temps(targets[rel], data))

    counts = manifest["counts"]
    type_counts = counts["types"]
    attachment_counts = counts["attachments"]
    unsupported = dict(manifest["unsupported_cloud_media"])

    if dry_run:
        return ImportSummary(
            memo_count=counts["memos"],
            day_count=counts["days"],
            type_counts=type_counts,
            attachment_counts=attachment_counts,
            duplicate_memo_count=counts["duplicate_memos"],
            unique_tag_count=counts["unique_tags"],
            unsupported_cloud_media_counts=unsupported,
            formatting_adaptations=dict(export.adaptations),
            files_written=0,
            files_unchanged=0,
            dry_run=True,
        )

    destination.mkdir(parents=True, exist_ok=True)
    for temporary in recoverable:
        temporary.unlink()
    # Manifest first: it is the ownership marker for crash-safe retry.
    if not manifest_path.exists():
        _atomic_write(
            manifest_path,
            _manifest_bytes(manifest),
        )

    written = 0
    unchanged = 0
    for rel in managed:
        target = targets[rel]
        data = {**day_files, **asset_files}[rel]
        if target.exists():
            if target.read_bytes() != data:
                raise ConflictError("existing file does not match this import")
            unchanged += 1
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            _atomic_write(target, data)
            written += 1

    return ImportSummary(
        memo_count=counts["memos"],
        day_count=counts["days"],
        type_counts=type_counts,
        attachment_counts=attachment_counts,
        duplicate_memo_count=counts["duplicate_memos"],
        unique_tag_count=counts["unique_tags"],
        unsupported_cloud_media_counts=unsupported,
        formatting_adaptations=dict(export.adaptations),
        files_written=written,
        files_unchanged=unchanged,
        dry_run=False,
    )


# --------------------------------------------------------------------------
# CLI (aggregate counts only — no note text, tag labels, or media paths)
# --------------------------------------------------------------------------

def _print_summary(summary: ImportSummary) -> None:
    t = summary.type_counts
    a = summary.attachment_counts
    print("flomo import summary")
    print(f"memos: {summary.memo_count}")
    print(f"days: {summary.day_count}")
    print(f"types: text={t['text']} voice={t['voice']} photo={t['photo']} mixed={t['mixed']}")
    print(f"attachments: photo={a['photo']} audio={a['audio']} file={a['file']}")
    print(f"duplicate_memos: {summary.duplicate_memo_count}")
    print(f"unique_tags: {summary.unique_tag_count}")
    parts = [f"{ext}={summary.unsupported_cloud_media_counts[ext]}"
             for ext in UNSUPPORTED_CLOUD_EXTS
             if ext in summary.unsupported_cloud_media_counts]
    print("unsupported_cloud_media: " + (" ".join(parts) if parts else "none"))
    fa = summary.formatting_adaptations
    print("formatting_adaptations: "
          + " ".join(f"{key}={fa.get(key, 0)}" for key in _ADAPTATION_KEYS))
    print(f"files_written: {summary.files_written}")
    print(f"files_unchanged: {summary.files_unchanged}")
    print(f"dry_run: {'yes' if summary.dry_run else 'no'}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="One-time flomo export to DayPage vault import (counts only).")
    parser.add_argument("--input", required=True, help="flomo export ZIP")
    parser.add_argument("--output", required=True,
                        help="new or previously-owned import staging directory")
    parser.add_argument("--timezone", default="Asia/Shanghai",
                        help="timezone of export timestamps (default: Asia/Shanghai)")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate everything without writing user data")
    args = parser.parse_args(argv)

    try:
        export = parse_export(args.input, timezone=args.timezone)
        summary = write_vault(export, args.output, dry_run=args.dry_run)
    except FlomoImportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    _print_summary(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
