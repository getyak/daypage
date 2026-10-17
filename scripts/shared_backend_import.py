#!/usr/bin/env python3
"""DayPage shared backend private import CLI (issue #884).

Imports a PREVALIDATED native DayPage flomo operation export into a shared
Supabase backend with private media and exact imported tags. Offline dry-run by
default; the real import is an explicit operator action behind --execute.

Architecture is settled by ADR0016 / ADR0020 / ADR0023. Python stdlib only.

Output discipline: only static error codes and aggregate counts/hashes are ever
emitted. Never note bodies, labels, filenames, user identifiers, URLs carrying
keys, HTTP packets, credentials, or tracebacks. Passwords and access tokens are
never written to the checkpoint or the receipt.

This is a focused operator tool, not a general SDK.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Bounds (fail closed on oversized input)
# --------------------------------------------------------------------------

TOOL_VERSION = "1.0.0"

MAX_CONFIG_BYTES = 65536
MAX_OWNER_BYTES = 65536
MAX_SESSION_BYTES = 1048576
MAX_PREFLIGHT_BYTES = 1048576
MAX_EXPORT_BYTES = 67108864
MAX_TAGS_BYTES = 8388608
MAX_CHECKPOINT_BYTES = 33554432
MAX_REQUEST_BYTES = 8388608
MAX_RESPONSE_BYTES = 67108864
MAX_ATTACHMENT_BYTES = 52428800
MAX_BODY_BYTES = 4194304
MAX_RECORDS = 10000
MAX_ATTACHMENTS = 20
MAX_JWT_BYTES = 16384

TUS_CHUNK_BYTES = 6 * 1024 * 1024
DIRECT_UPLOAD_MAX_BYTES = 6 * 1024 * 1024

RESERVATIONS_PER_MINUTE = 55
MAX_OUTSTANDING_RESERVATIONS = 95
COMMIT_TEXT_BATCH = 20
PULL_LIMIT = 200

MAX_HTTP_ATTEMPTS = 5
MAX_RETRY_AFTER_SECONDS = 60
RETRY_BACKOFF_BASE = 0.5

# --------------------------------------------------------------------------
# Canonical MIME/extension pairs (9 pairs; AAC and MOV are first-class)
# --------------------------------------------------------------------------

MIME_EXTENSIONS = {
    "audio/m4a": "m4a",
    "audio/mp4": "mp4",
    "audio/aac": "aac",
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/heic": "heic",
    "image/heif": "heif",
    "application/pdf": "pdf",
    "video/quicktime": "mov",
}
KIND_BY_MIME = {
    "audio/m4a": "audio",
    "audio/mp4": "audio",
    "audio/aac": "audio",
    "image/jpeg": "photo",
    "image/png": "photo",
    "image/heic": "photo",
    "image/heif": "photo",
    "application/pdf": "file",
    "video/quicktime": "file",
}

# --------------------------------------------------------------------------
# Static patterns
# --------------------------------------------------------------------------

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}"
    r"-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)
SESSION_REQUIRED_KEYS = {"access_token", "refresh_token", "user", "expires_at"}
SESSION_OPTIONAL_KEYS = {"expires_in", "token_type", "weak_password"}
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
TS_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$"
)
PROJECT_RE = re.compile(r"^[a-z]{20}$")
PUBLISHABLE_KEY_RE = re.compile(r"^sb_publishable_[A-Za-z0-9_\-]{1,512}$")
VAULT_PATH_RE = re.compile(r"^raw/\d{4}-\d{2}-\d{2}\.md$")
FILENAME_RE = re.compile(r"^[^/\\\u0000-\u001F\u007F]+$")
LABEL_RE = re.compile(r"^#[^\u0000-\u001F\u007F]+$")
SOURCES = ("ios", "macos", "android", "web")
PAYLOAD_TYPES = ("text", "url", "voice", "photo", "file")
TRANSCRIPTION_STATES = ("pending", "done", "failed")

PREFLIGHT_KEYS = {
    "result",
    "export_sha256",
    "memos",
    "attachments",
    "attachment_bytes",
    "native_and_javascript_manifest_hashes_agree",
    "all_operations_conform_to_current_v2_schema",
}


# --------------------------------------------------------------------------
# Failure handling: only static error codes ever leave this tool
# --------------------------------------------------------------------------


class ImportFailure(Exception):
    """A failure carrying exactly one static error code."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


def fail(code):
    raise ImportFailure(code)


def require(condition, code):
    if not condition:
        fail(code)


# --------------------------------------------------------------------------
# JSON helpers (strict: duplicate object keys are rejected)
# --------------------------------------------------------------------------


class _DuplicateKeyError(ValueError):
    pass


def _pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKeyError()
        result[key] = value
    return result


def _reject_json_constant(name):
    raise ValueError("nonstandard JSON constant: %s" % name)


def json_loads_strict(data, code):
    if isinstance(data, bytes):
        try:
            data = data.decode("utf-8")
        except UnicodeDecodeError:
            fail(code)
    try:
        return json.loads(
            data,
            object_pairs_hook=_pairs_no_duplicates,
            parse_constant=_reject_json_constant,
        )
    except _DuplicateKeyError:
        fail("E_JSON_DUPLICATE_KEY")
    except (ValueError, TypeError):
        fail(code)


def json_dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


# --------------------------------------------------------------------------
# Filesystem helpers
# --------------------------------------------------------------------------


def _no_follow_flag():
    return getattr(os, "O_NOFOLLOW", 0)


def lstat_regular(path, code):
    """Cheap pre-check for clear diagnostics; identity is enforced on the fd."""
    try:
        st = os.lstat(path)
    except OSError:
        fail("E_INPUT_MISSING")
    if stat.S_ISLNK(st.st_mode):
        fail("E_INPUT_SYMLINK")
    if not stat.S_ISREG(st.st_mode):
        fail(code)
    return st


def open_regular(path):
    """Open a file read-only: no symlink following, no blocking, same-fd fstat.

    Only regular files are accepted, so FIFOs, device nodes and sockets are
    refused deterministically before any read. All later mode/size/identity
    checks use this fd's fstat, never a second lstat.
    """
    flags = os.O_RDONLY | _no_follow_flag() | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        fail("E_INPUT_SYMLINK")
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        fail("E_INPUT_TYPE")
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        fail("E_INPUT_TYPE")
    return fd, st


def read_input_bytes(path, limit):
    lstat_regular(path, "E_INPUT_TYPE")
    fd, st = open_regular(path)
    if st.st_size > limit:
        os.close(fd)
        fail("E_INPUT_SIZE")
    chunks = []
    total = 0
    try:
        while True:
            chunk = os.read(fd, min(1024 * 1024, limit + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                fail("E_INPUT_SIZE")
            chunks.append(chunk)
    finally:
        os.close(fd)
    if total != st.st_size:
        fail("E_INPUT_SIZE")
    return b"".join(chunks), st


def read_private_json(path, limit):
    raw, st = read_input_bytes(path, limit)
    if (st.st_mode & 0o777) != 0o600:
        fail("E_INPUT_MODE")
    return json_loads_strict(raw, "E_JSON"), raw


def read_json(path, limit):
    raw, _st = read_input_bytes(path, limit)
    return json_loads_strict(raw, "E_JSON"), raw


def _fsync_dir(path):
    try:
        fd = os.open(path or ".", os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_private_atomic(path, data):
    """Write bytes to path as mode 0600 via durable atomic replace.

    The temporary file lives in the destination directory with an
    unpredictable name created exclusively (O_CREAT|O_EXCL, no symlink
    following), so no pre-existing file or hardlink can ever be truncated and
    no permissive temp can be reused. Data and directory are fsynced and the
    temp is cleaned up on every failure path.
    """
    directory = os.path.dirname(path) or "."
    tmp = None
    fd = None
    for _ in range(32):
        candidate = os.path.join(
            directory, ".%s.tmp.%s" % (os.path.basename(path), os.urandom(8).hex())
        )
        try:
            fd = os.open(
                candidate,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | _no_follow_flag(),
                0o600,
            )
            tmp = candidate
            break
        except FileExistsError:
            continue
        except OSError:
            fail("E_OUTPUT_ALIAS")
    if tmp is None:
        fail("E_OUTPUT_ALIAS")
    replaced = False
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = None
        # Permitted-target check immediately before the atomic replacement.
        try:
            dst = os.lstat(path)
        except OSError:
            dst = None
        if dst is not None and (
            stat.S_ISLNK(dst.st_mode) or not stat.S_ISREG(dst.st_mode)
        ):
            fail("E_OUTPUT_ALIAS")
        os.replace(tmp, path)
        replaced = True
    except OSError:
        fail("E_OUTPUT_ALIAS")
    finally:
        if fd is not None:
            os.close(fd)
        if not replaced:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    _fsync_dir(directory)
    try:
        st = os.lstat(path)
    except OSError:
        fail("E_OUTPUT_ALIAS")
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        fail("E_OUTPUT_ALIAS")
    if (st.st_mode & 0o777) != 0o600:
        fail("E_INPUT_MODE")


def check_output_path(path, other_paths):
    """Outputs must never alias inputs and must never follow symlinks."""
    for other in other_paths:
        if os.path.abspath(path) == os.path.abspath(other):
            fail("E_OUTPUT_ALIAS")
    try:
        st = os.lstat(path)
    except OSError:
        return
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        fail("E_OUTPUT_ALIAS")
    for other in other_paths:
        try:
            ost = os.lstat(other)
        except OSError:
            continue
        if (ost.st_dev, ost.st_ino) == (st.st_dev, st.st_ino):
            fail("E_OUTPUT_ALIAS")


def check_output_outside_vault(path, vault_real):
    """Mutable outputs and the checkpoint lock must never live under the
    Vault; parents are resolved so aliasing symlinks are caught too."""
    # Resolve symlinks before processing '..'; abspath would collapse it
    # lexically and disagree with the path the filesystem actually opens.
    real_parent = os.path.realpath(os.path.dirname(path) or ".")
    require(
        real_parent != vault_real
        and not real_parent.startswith(vault_real + os.sep),
        "E_OUTPUT_ALIAS",
    )
    real_target = os.path.realpath(path)
    require(
        real_target != vault_real
        and not real_target.startswith(vault_real + os.sep),
        "E_OUTPUT_ALIAS",
    )


class CheckpointLock:
    """Single-writer lock for the checkpoint file (advisory, one process)."""

    def __init__(self, checkpoint_path):
        self.lock_path = checkpoint_path + ".lock"
        self.fd = None

    def __enter__(self):
        import fcntl

        try:
            self.fd = os.open(
                self.lock_path,
                os.O_RDWR | os.O_CREAT | _no_follow_flag(),
                0o600,
            )
        except OSError:
            fail("E_CHECKPOINT_LOCK")
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.fd)
            self.fd = None
            fail("E_CHECKPOINT_LOCK")
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.fd is not None:
            import fcntl

            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(self.fd)
            self.fd = None
        return False


# --------------------------------------------------------------------------
# Hashing helpers
# --------------------------------------------------------------------------


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def hash_file(path):
    """Stream a local file (regular, no symlinks) and return (sha256_hex, size)."""
    fd, st = open_regular(path)
    if st.st_size > MAX_ATTACHMENT_BYTES:
        os.close(fd)
        fail("E_INPUT_SIZE")
    digest = hashlib.sha256()
    size = 0
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_ATTACHMENT_BYTES:
                fail("E_INPUT_SIZE")
            digest.update(chunk)
    finally:
        os.close(fd)
    if size != st.st_size:
        fail("E_FILE_SIZE")
    return digest.hexdigest(), size


def _lp(data):
    """Raw byte length prefix: b'<len>:' + data (never a Python repr)."""
    return ("%d:" % len(data)).encode("ascii") + data


def _lp_text(value):
    return _lp(str(value).encode("utf-8"))


def attachment_manifest_hash(attachments):
    """Byte-exact port of packages/contracts/manifest-hash.mjs (manifest v2).

    Records are raw UTF-8 length-prefixed bytes; independent JS goldens are
    pinned in the test suite.
    """
    ordered = sorted(attachments, key=lambda item: item["position"])
    records = []
    for attachment in ordered:
        fields = [
            attachment["position"],
            attachment["kind"],
            attachment["content_sha256"],
            attachment["size_bytes"],
            attachment["mime_type"],
            attachment["object_key"],
            attachment["original_filename"],
        ]
        for optional in ("duration_ms", "transcript", "transcription_status"):
            value = attachment.get(optional)
            fields.append("" if value is None else value)
        records.append(b"".join(_lp_text(field) for field in fields))
    canonical = _lp(b"2") + b"".join(_lp(record) for record in records)
    return hashlib.sha256(canonical).hexdigest()


# --------------------------------------------------------------------------
# Time helpers
# --------------------------------------------------------------------------


def now_epoch():
    return time.time()


_TS_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def parse_timestamp(value):
    """Exact timezone-normalized integer microseconds since epoch, or None.

    Fractional precision above microseconds is rejected (never truncated or
    rounded); equivalent Z/+00:00/offset representations of the same instant
    compare exactly equal.
    """
    if not isinstance(value, str) or not TS_RE.fullmatch(value):
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    delta = parsed - _TS_EPOCH
    return (delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds


def now_micros(epoch_seconds):
    return int(epoch_seconds * 1000000)


# --------------------------------------------------------------------------
# Shared field validation
# --------------------------------------------------------------------------


def is_uuid(value):
    return isinstance(value, str) and bool(UUID_RE.fullmatch(value))


def is_hash(value):
    return isinstance(value, str) and bool(HASH_RE.fullmatch(value))


def is_timestamp(value):
    return isinstance(value, str) and bool(TS_RE.fullmatch(value))


def exact_keys(value, keys, code):
    require(isinstance(value, dict), code)
    require(set(value.keys()) == set(keys), code)


# --------------------------------------------------------------------------
# Config / owner / session / preflight receipt validation
# --------------------------------------------------------------------------


def validate_config(value):
    exact_keys(value, {"project_id", "url", "publishable_key"}, "E_CONFIG_SHAPE")
    project_id = value["project_id"]
    require(
        isinstance(project_id, str) and bool(PROJECT_RE.fullmatch(project_id)),
        "E_CONFIG_SHAPE",
    )
    url = value["url"]
    require(isinstance(url, str) and 1 <= len(url) <= 512, "E_CONFIG_SHAPE")
    origin = "https://%s.supabase.co" % project_id
    require(url == origin, "E_CONFIG_ORIGIN")
    parts = urllib.parse.urlsplit(url)
    require(parts.scheme == "https", "E_CONFIG_ORIGIN")
    require(parts.netloc == "%s.supabase.co" % project_id, "E_CONFIG_ORIGIN")
    require("@" not in parts.netloc and parts.username is None, "E_CONFIG_ORIGIN")
    require(parts.port is None, "E_CONFIG_ORIGIN")
    require(parts.path in ("", "/"), "E_CONFIG_ORIGIN")
    require(not parts.query and not parts.fragment, "E_CONFIG_ORIGIN")
    key = value["publishable_key"]
    require(isinstance(key, str) and 1 <= len(key) <= 4096, "E_CONFIG_KEY")
    require(not re.search(r"[\s\u0000-\u001F\u007F]", key), "E_CONFIG_KEY")
    require(not key.lower().startswith("sb_secret_"), "E_CONFIG_KEY")
    if key.startswith("sb_publishable_"):
        require(bool(PUBLISHABLE_KEY_RE.fullmatch(key)), "E_CONFIG_KEY")
    else:
        # Legacy JWT-shaped publishable key: decode-only role check. This is
        # NOT signature proof; user authorization always uses the ordinary
        # server-verified user JWT, and service-role keys are refused.
        parts = key.split(".")
        require(len(parts) == 3 and all(parts), "E_CONFIG_KEY")
        claims = json_loads_strict(_b64url_decode(parts[1]), "E_CONFIG_KEY")
        require(isinstance(claims, dict), "E_CONFIG_KEY")
        require(claims.get("role") == "anon", "E_CONFIG_KEY")
    return {"project_id": project_id, "origin": origin, "publishable_key": key}


def validate_owner(value, config):
    exact_keys(
        value,
        {
            "project_id",
            "user_id",
            "email",
            "email_confirmed",
            "profile_matches_auth",
        },
        "E_OWNER_SHAPE",
    )
    require(value["project_id"] == config["project_id"], "E_OWNER_PROJECT")
    require(is_uuid(value["user_id"]), "E_OWNER_SHAPE")
    email = value["email"]
    require(
        isinstance(email, str)
        and 3 <= len(email) <= 320
        and "@" in email
        and not re.search(r"[\s\u0000-\u001F\u007F]", email),
        "E_OWNER_SHAPE",
    )
    require(value["email_confirmed"] is True, "E_OWNER_SHAPE")
    require(value["profile_matches_auth"] is True, "E_OWNER_SHAPE")
    return {
        "project_id": value["project_id"],
        "user_id": value["user_id"],
        "user_id_lower": value["user_id"].lower(),
        "email": email,
    }


def validate_session(value, owner):
    """Validate a standard GoTrue session packet.

    The official packet carries seven top-level keys (access_token,
    refresh_token, user, expires_at, expires_in, token_type, weak_password);
    the four identity-critical keys are required and safe metadata extras are
    accepted and preserved on refresh.
    """
    require(isinstance(value, dict), "E_SESSION_SHAPE")
    require(SESSION_REQUIRED_KEYS <= set(value.keys()), "E_SESSION_SHAPE")
    require(
        set(value.keys()) <= SESSION_REQUIRED_KEYS | SESSION_OPTIONAL_KEYS,
        "E_SESSION_SHAPE",
    )
    if "expires_in" in value:
        expires_in = value["expires_in"]
        require(
            isinstance(expires_in, (int, float))
            and not isinstance(expires_in, bool)
            and math.isfinite(expires_in)
            and expires_in >= 0,
            "E_SESSION_SHAPE",
        )
    if "token_type" in value:
        token_type = value["token_type"]
        require(
            isinstance(token_type, str)
            and 1 <= len(token_type) <= 64
            and not re.search(r"[\s\u0000-\u001F\u007F]", token_type),
            "E_SESSION_SHAPE",
        )
    if "weak_password" in value:
        weak_password = value["weak_password"]
        require(
            weak_password is None or isinstance(weak_password, (dict, list)),
            "E_SESSION_SHAPE",
        )
        if weak_password is not None:
            require(len(json_dumps(weak_password)) <= 4096, "E_SESSION_SHAPE")
    access_token = value["access_token"]
    refresh_token = value["refresh_token"]
    require(
        isinstance(access_token, str) and 1 <= len(access_token) <= MAX_JWT_BYTES,
        "E_SESSION_SHAPE",
    )
    require(
        isinstance(refresh_token, str) and 1 <= len(refresh_token) <= MAX_JWT_BYTES,
        "E_SESSION_SHAPE",
    )
    require(not re.search(r"[\s\u0000-\u001F\u007F]", access_token), "E_SESSION_SHAPE")
    require(not re.search(r"[\s\u0000-\u001F\u007F]", refresh_token), "E_SESSION_SHAPE")
    user = value["user"]
    require(isinstance(user, dict), "E_SESSION_SHAPE")
    require(is_uuid(user.get("id")), "E_SESSION_SHAPE")
    require(user["id"].lower() == owner["user_id_lower"], "E_SESSION_USER")
    if "email" in user:
        require(
            isinstance(user["email"], str)
            and user["email"].lower() == owner["email"].lower(),
            "E_SESSION_USER",
        )
    expires_at = value["expires_at"]
    require(
        isinstance(expires_at, (int, float))
        and not isinstance(expires_at, bool)
        and math.isfinite(expires_at),
        "E_SESSION_SHAPE",
    )
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "user_id": user["id"],
        "expires_at": float(expires_at),
    }


def validate_safe_metadata(value, depth=0):
    """Bound extra receipt metadata to plain, bounded JSON scalars/containers."""
    require(depth <= 6, "E_PREFLIGHT_SHAPE")
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        require(math.isfinite(value), "E_PREFLIGHT_SHAPE")
        return
    if isinstance(value, str):
        require(len(value.encode("utf-8")) <= 4096, "E_PREFLIGHT_SHAPE")
        return
    if isinstance(value, list):
        require(len(value) <= 1000, "E_PREFLIGHT_SHAPE")
        for item in value:
            validate_safe_metadata(item, depth + 1)
        return
    if isinstance(value, dict):
        require(len(value) <= 200, "E_PREFLIGHT_SHAPE")
        for key, item in value.items():
            require(
                isinstance(key, str)
                and 1 <= len(key) <= 64
                and not re.search(r"[\u0000-\u001F\u007F]", key),
                "E_PREFLIGHT_SHAPE",
            )
            validate_safe_metadata(item, depth + 1)
        return
    fail("E_PREFLIGHT_SHAPE")


def validate_preflight(value, export_sha256, memos, attachments, attachment_bytes):
    """Independent preflight receipt: core fields verified, safe extras kept."""
    require(isinstance(value, dict), "E_PREFLIGHT_SHAPE")
    require(PREFLIGHT_KEYS <= set(value.keys()), "E_PREFLIGHT_SHAPE")
    validate_safe_metadata(value)
    require(value["result"] == "passed", "E_PREFLIGHT_SHAPE")
    require(value["export_sha256"] == export_sha256, "E_PREFLIGHT_BIND")
    require(
        isinstance(value["memos"], int)
        and not isinstance(value["memos"], bool)
        and value["memos"] == memos,
        "E_PREFLIGHT_BIND",
    )
    require(
        isinstance(value["attachments"], int)
        and not isinstance(value["attachments"], bool)
        and value["attachments"] == attachments,
        "E_PREFLIGHT_BIND",
    )
    require(
        isinstance(value["attachment_bytes"], int)
        and not isinstance(value["attachment_bytes"], bool)
        and value["attachment_bytes"] == attachment_bytes,
        "E_PREFLIGHT_BIND",
    )
    require(
        value["native_and_javascript_manifest_hashes_agree"] is True,
        "E_PREFLIGHT_SHAPE",
    )
    require(
        value["all_operations_conform_to_current_v2_schema"] is True,
        "E_PREFLIGHT_SHAPE",
    )


# --------------------------------------------------------------------------
# Operation export validation (never normalizes or edits operation contents)
# --------------------------------------------------------------------------


def _validate_attachment(descriptor, owner, memo_id):
    require(isinstance(descriptor, dict), "E_ATTACHMENT_SCHEMA")
    require(
        set(descriptor.keys())
        <= {
            "position",
            "kind",
            "content_sha256",
            "size_bytes",
            "mime_type",
            "object_key",
            "original_filename",
            "duration_ms",
            "transcript",
            "transcription_status",
        },
        "E_ATTACHMENT_SCHEMA",
    )
    require(
        {
            "position",
            "kind",
            "content_sha256",
            "size_bytes",
            "mime_type",
            "object_key",
            "original_filename",
        }
        <= set(descriptor.keys()),
        "E_ATTACHMENT_SCHEMA",
    )
    position = descriptor["position"]
    require(
        isinstance(position, int)
        and not isinstance(position, bool)
        and 0 <= position <= 19,
        "E_ATTACHMENT_SCHEMA",
    )
    kind = descriptor["kind"]
    require(kind in ("audio", "photo", "file"), "E_ATTACHMENT_SCHEMA")
    require(is_hash(descriptor["content_sha256"]), "E_ATTACHMENT_SCHEMA")
    size_bytes = descriptor["size_bytes"]
    require(
        isinstance(size_bytes, int)
        and not isinstance(size_bytes, bool)
        and 1 <= size_bytes <= MAX_ATTACHMENT_BYTES,
        "E_ATTACHMENT_SCHEMA",
    )
    mime_type = descriptor["mime_type"]
    require(mime_type in MIME_EXTENSIONS, "E_MIME_EXT")
    require(KIND_BY_MIME[mime_type] == kind, "E_MIME_EXT")
    extension = MIME_EXTENSIONS[mime_type]
    expected_key = "%s/%s/%s.%s" % (
        owner["user_id_lower"],
        memo_id.lower(),
        descriptor["content_sha256"],
        extension,
    )
    require(descriptor["object_key"] == expected_key, "E_OBJECT_KEY")
    filename = descriptor["original_filename"]
    require(
        isinstance(filename, str)
        and 1 <= len(filename) <= 255
        and bool(FILENAME_RE.fullmatch(filename)),
        "E_ATTACHMENT_SCHEMA",
    )
    if "duration_ms" in descriptor:
        duration = descriptor["duration_ms"]
        require(
            duration is None
            or (
                isinstance(duration, int)
                and not isinstance(duration, bool)
                and duration >= 0
            ),
            "E_ATTACHMENT_SCHEMA",
        )
    if "transcript" in descriptor:
        transcript = descriptor["transcript"]
        require(
            transcript is None
            or (isinstance(transcript, str) and len(transcript.encode("utf-8")) <= 200000),
            "E_ATTACHMENT_SCHEMA",
        )
    if "transcription_status" in descriptor:
        require(
            descriptor["transcription_status"] in (None,) + TRANSCRIPTION_STATES,
            "E_ATTACHMENT_SCHEMA",
        )
    return extension


def _validate_payload(payload, memo_id, owner):
    require(isinstance(payload, dict), "E_PAYLOAD_SCHEMA")
    require(
        set(payload.keys())
        <= {
            "type",
            "body",
            "created_at",
            "source",
            "vault_path",
            "attachments",
            "pinned_at",
            "location",
            "weather",
            "device",
        },
        "E_PAYLOAD_SCHEMA",
    )
    require(
        {"type", "body", "created_at", "source", "vault_path", "attachments"}
        <= set(payload.keys()),
        "E_PAYLOAD_SCHEMA",
    )
    require(payload["type"] in PAYLOAD_TYPES, "E_PAYLOAD_SCHEMA")
    body = payload["body"]
    require(
        isinstance(body, str) and 1 <= len(body.encode("utf-8")) <= MAX_BODY_BYTES,
        "E_PAYLOAD_SCHEMA",
    )
    require(is_timestamp(payload["created_at"]), "E_PAYLOAD_SCHEMA")
    if "pinned_at" in payload:
        require(
            payload["pinned_at"] is None or is_timestamp(payload["pinned_at"]),
            "E_PAYLOAD_SCHEMA",
        )
    if "location" in payload:
        location = payload["location"]
        require(
            location is None
            or (
                isinstance(location, dict)
                and set(location.keys()) <= {"name", "lat", "lng"}
                and (
                    location.get("name") is None
                    or isinstance(location.get("name"), str)
                )
                and (
                    location.get("lat") is None
                    or (
                        isinstance(location.get("lat"), (int, float))
                        and not isinstance(location.get("lat"), bool)
                        and -90 <= location.get("lat") <= 90
                    )
                )
                and (
                    location.get("lng") is None
                    or (
                        isinstance(location.get("lng"), (int, float))
                        and not isinstance(location.get("lng"), bool)
                        and -180 <= location.get("lng") <= 180
                    )
                )
            ),
            "E_PAYLOAD_SCHEMA",
        )
    if "weather" in payload:
        weather = payload["weather"]
        require(
            weather is None
            or (
                isinstance(weather, dict)
                and set(weather.keys()) == {"condition"}
                and isinstance(weather.get("condition"), str)
                and 1 <= len(weather.get("condition")) <= 240
            ),
            "E_PAYLOAD_SCHEMA",
        )
    if "device" in payload:
        device = payload["device"]
        require(
            device is None or (isinstance(device, str) and len(device) <= 240),
            "E_PAYLOAD_SCHEMA",
        )
    require(payload["source"] in SOURCES, "E_PAYLOAD_SCHEMA")
    require(
        isinstance(payload["vault_path"], str)
        and bool(VAULT_PATH_RE.fullmatch(payload["vault_path"])),
        "E_PAYLOAD_SCHEMA",
    )
    attachments = payload["attachments"]
    require(isinstance(attachments, list), "E_PAYLOAD_SCHEMA")
    require(len(attachments) <= MAX_ATTACHMENTS, "E_PAYLOAD_SCHEMA")
    seen_positions = set()
    for descriptor in attachments:
        _validate_attachment(descriptor, owner, memo_id)
        require(descriptor["position"] not in seen_positions, "E_ATTACHMENT_SCHEMA")
        seen_positions.add(descriptor["position"])
    return body


def validate_export(value, config, owner):
    require(isinstance(value, dict), "E_EXPORT_SHAPE")
    require(
        set(value.keys())
        == {
            "version",
            "format",
            "project_id",
            "user_id",
            "source_zip_sha256",
            "records",
        },
        "E_EXPORT_SHAPE",
    )
    require(value["version"] == 1, "E_EXPORT_SHAPE")
    require(value["format"] == "daypage-private-import-operations", "E_EXPORT_SHAPE")
    require(value["project_id"] == config["project_id"], "E_EXPORT_PROJECT")
    require(
        isinstance(value["user_id"], str)
        and value["user_id"].lower() == owner["user_id_lower"],
        "E_EXPORT_USER",
    )
    require(is_hash(value["source_zip_sha256"]), "E_EXPORT_SOURCE")
    records = value["records"]
    require(isinstance(records, list), "E_EXPORT_SHAPE")
    require(1 <= len(records) <= MAX_RECORDS, "E_EXPORT_SHAPE")

    seen_operations = set()
    seen_memos = set()
    total_attachments = 0
    total_attachment_bytes = 0
    for record in records:
        require(isinstance(record, dict), "E_EXPORT_SHAPE")
        require(
            set(record.keys()) == {"operation", "local_files", "body_sha256"},
            "E_EXPORT_SHAPE",
        )
        operation = record["operation"]
        require(isinstance(operation, dict), "E_OPERATION_SCHEMA")
        require(
            set(operation.keys())
            <= {
                "protocol_version",
                "operation_id",
                "memo_id",
                "kind",
                "revision",
                "modified_at",
                "content_hash",
                "attachment_manifest_hash",
                "device_id",
                "payload",
                "size_bytes",
            },
            "E_OPERATION_SCHEMA",
        )
        require(
            {
                "protocol_version",
                "operation_id",
                "memo_id",
                "kind",
                "revision",
                "modified_at",
                "device_id",
                "size_bytes",
            }
            <= set(operation.keys()),
            "E_OPERATION_SCHEMA",
        )
        require(operation["protocol_version"] == 2, "E_OPERATION_SCHEMA")
        require(is_uuid(operation["operation_id"]), "E_OPERATION_SCHEMA")
        require(is_uuid(operation["memo_id"]), "E_OPERATION_SCHEMA")
        require(is_uuid(operation["device_id"]), "E_OPERATION_SCHEMA")
        require(operation["kind"] == "upsert", "E_OPERATION_KIND")
        revision = operation["revision"]
        require(
            isinstance(revision, int)
            and not isinstance(revision, bool)
            and revision >= 1,
            "E_OPERATION_SCHEMA",
        )
        require(is_timestamp(operation["modified_at"]), "E_OPERATION_SCHEMA")
        require(is_hash(operation["content_hash"]), "E_OPERATION_SCHEMA")
        require(is_hash(operation["attachment_manifest_hash"]), "E_OPERATION_SCHEMA")
        size_bytes = operation["size_bytes"]
        require(
            isinstance(size_bytes, int)
            and not isinstance(size_bytes, bool)
            and size_bytes >= 1,
            "E_OPERATION_SCHEMA",
        )
        operation_id = operation["operation_id"]
        memo_id = operation["memo_id"]
        require(operation_id.lower() not in seen_operations, "E_EXPORT_ID_DUP")
        seen_operations.add(operation_id.lower())
        require(memo_id.lower() not in seen_memos, "E_EXPORT_ID_DUP")
        seen_memos.add(memo_id.lower())

        body = _validate_payload(operation["payload"], memo_id, owner)
        require(
            is_hash(record["body_sha256"])
            and record["body_sha256"] == sha256_bytes(body.encode("utf-8")),
            "E_BODY_HASH",
        )
        attachments = operation["payload"]["attachments"]
        require(
            attachment_manifest_hash(attachments)
            == operation["attachment_manifest_hash"],
            "E_MANIFEST_HASH",
        )
        local_files = record["local_files"]
        require(isinstance(local_files, list), "E_LOCAL_FILES")
        require(len(local_files) == len(attachments), "E_LOCAL_FILES")
        for name in local_files:
            require(
                isinstance(name, str) and 1 <= len(name) <= 1024, "E_FILE_PATH"
            )
            require("\\" not in name and "\x00" not in name, "E_FILE_PATH")
            require(not os.path.isabs(name), "E_FILE_PATH")
            require(not re.match(r"^[A-Za-z]:", name), "E_FILE_PATH")
            segments = name.split("/")
            require(all(seg not in ("", ".", "..") for seg in segments), "E_FILE_PATH")
        total_attachments += len(attachments)
        for descriptor in attachments:
            total_attachment_bytes += descriptor["size_bytes"]

    return {
        "records": records,
        "memo_ids": seen_memos,
        "memos": len(records),
        "attachments": total_attachments,
        "attachment_bytes": total_attachment_bytes,
        "source_zip_sha256": value["source_zip_sha256"],
    }


# --------------------------------------------------------------------------
# Vault local file verification (native Vault-relative or raw-relative)
# --------------------------------------------------------------------------


def resolve_local_file(raw_root, raw_real, relative):
    """Resolve a local file strictly inside VAULT/raw, refusing symlinks."""
    # The native exporter preserves attachment.file as raw/assets/... relative
    # to the Vault. Also retain the raw-relative assets/... operator format.
    # Original segments were validated before this single prefix is removed.
    if relative.startswith("raw/"):
        relative = relative[4:]
    candidate = os.path.join(raw_root, relative.replace("/", os.sep))
    current = raw_root
    segments = relative.split("/")
    for index, segment in enumerate(segments):
        current = os.path.join(current, segment)
        try:
            st = os.lstat(current)
        except OSError:
            fail("E_INPUT_MISSING")
        if stat.S_ISLNK(st.st_mode):
            fail("E_FILE_SYMLINK")
        if index == len(segments) - 1 and not stat.S_ISREG(st.st_mode):
            fail("E_INPUT_TYPE")
    try:
        real = os.path.realpath(candidate)
    except OSError:
        fail("E_FILE_ESCAPE")
    if real != raw_real and not real.startswith(raw_real + os.sep):
        fail("E_FILE_ESCAPE")
    return candidate


def verify_local_files(export_info, raw_root):
    raw_real = os.path.realpath(raw_root)
    if not os.path.isdir(raw_root) or os.path.islink(raw_root):
        fail("E_FILE_ESCAPE")
    if os.path.realpath(raw_root) != raw_real:
        fail("E_FILE_ESCAPE")
    resolved_paths = []
    for record in export_info["records"]:
        attachments = record["operation"]["payload"]["attachments"]
        for relative, descriptor in zip(record["local_files"], attachments):
            path = resolve_local_file(raw_root, raw_real, relative)
            digest, size = hash_file(path)
            require(size == descriptor["size_bytes"], "E_FILE_SIZE")
            require(digest == descriptor["content_sha256"], "E_FILE_HASH")
            resolved_paths.append(path)
    return resolved_paths


# --------------------------------------------------------------------------
# Tag payload validation (exact fidelity; nothing is normalized or deduped)
# --------------------------------------------------------------------------


def _validate_label(label):
    require(
        isinstance(label, str)
        and bool(LABEL_RE.fullmatch(label))
        and 1 <= len(label.encode("utf-8")) <= 1024,
        "E_TAG_LABEL",
    )


def validate_tags(value, memo_ids):
    require(isinstance(value, dict), "E_TAG_SCHEMA")
    require(
        set(value.keys()) == {"version", "catalog", "memos"}, "E_TAG_SCHEMA"
    )
    require(value["version"] == 1, "E_TAG_SCHEMA")
    catalog = value["catalog"]
    require(isinstance(catalog, list) and len(catalog) <= 20000, "E_TAG_SCHEMA")
    seen_catalog = set()
    for label in catalog:
        _validate_label(label)
        require(label not in seen_catalog, "E_TAG_SCHEMA")
        seen_catalog.add(label)
    memos = value["memos"]
    require(isinstance(memos, list) and len(memos) <= 10000, "E_TAG_SCHEMA")
    seen_memos = set()
    memberships = set()
    union_labels = set(catalog)
    for entry in memos:
        require(isinstance(entry, dict), "E_TAG_SCHEMA")
        require(set(entry.keys()) == {"memo_id", "tags"}, "E_TAG_SCHEMA")
        require(is_uuid(entry["memo_id"]), "E_TAG_SCHEMA")
        memo_key = entry["memo_id"].lower()
        require(memo_key not in seen_memos, "E_TAG_SCHEMA")
        seen_memos.add(memo_key)
        tags = entry["tags"]
        require(isinstance(tags, list) and len(tags) <= 200, "E_TAG_SCHEMA")
        for label in tags:
            _validate_label(label)
            union_labels.add(label)
            memberships.add((memo_key, label))
    require(seen_memos == set(memo_ids), "E_TAG_MEMO_SET")
    return {
        "payload": value,
        "catalog_labels": len(catalog),
        "distinct_labels": len(union_labels),
        "memos": len(memos),
        "memberships": len(memberships),
    }


# --------------------------------------------------------------------------
# JWT claim validation (decoding alone is never sufficient authentication)
# --------------------------------------------------------------------------


def _b64url_decode(part):
    try:
        return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
    except Exception:
        fail("E_AUTH_JWT")


def decode_jwt_claims(token):
    require(
        isinstance(token, str) and 1 <= len(token) <= MAX_JWT_BYTES, "E_AUTH_JWT"
    )
    parts = token.split(".")
    require(len(parts) == 3 and all(parts), "E_AUTH_JWT")
    header = json_loads_strict(_b64url_decode(parts[0]), "E_AUTH_JWT")
    claims = json_loads_strict(_b64url_decode(parts[1]), "E_AUTH_JWT")
    require(isinstance(header, dict) and isinstance(claims, dict), "E_AUTH_JWT")
    return header, claims


def validate_jwt(token, origin, owner, now):
    header, claims = decode_jwt_claims(token)
    alg = header.get("alg")
    require(isinstance(alg, str) and alg.lower() != "none", "E_AUTH_JWT")
    require(claims.get("iss") == origin + "/auth/v1", "E_AUTH_JWT")
    sub = claims.get("sub")
    require(
        isinstance(sub, str) and sub.lower() == owner["user_id_lower"], "E_AUTH_JWT"
    )
    require(claims.get("role") == "authenticated", "E_AUTH_JWT")
    exp = claims.get("exp")
    require(
        isinstance(exp, (int, float))
        and not isinstance(exp, bool)
        and math.isfinite(exp),
        "E_AUTH_JWT",
    )
    if exp <= now:
        fail("E_AUTH_EXPIRED")


# --------------------------------------------------------------------------
# Origin rules: exact HTTPS <project>.supabase.co, no userinfo/port/escape
# --------------------------------------------------------------------------


def ensure_same_origin(url, origin, path_prefix=None, allow_query=False):
    parts = urllib.parse.urlsplit(url)
    base = urllib.parse.urlsplit(origin)
    require(parts.scheme == "https", "E_ORIGIN")
    require(parts.netloc == base.netloc, "E_ORIGIN")
    require("@" not in parts.netloc and parts.username is None, "E_ORIGIN")
    require(parts.port is None, "E_ORIGIN")
    if path_prefix is not None:
        require(parts.path.startswith(path_prefix), "E_ORIGIN")
    if not allow_query:
        require(not parts.query, "E_ORIGIN")
    require(not parts.fragment, "E_ORIGIN")


def resolve_tus_location(location, origin):
    """TUS Location must be absolute same-origin, or a safe relative path."""
    require(isinstance(location, str) and 1 <= len(location) <= 2048, "E_TUS_LOCATION")
    parts = urllib.parse.urlsplit(location)
    if parts.scheme == "" and parts.netloc == "":
        require(location.startswith("/"), "E_TUS_LOCATION")
        base = urllib.parse.urlsplit(origin)
        parts = urllib.parse.urlsplit(
            urllib.parse.urlunsplit(
                (base.scheme, base.netloc, parts.path, parts.query, parts.fragment)
            )
        )
    require(parts.scheme == "https", "E_TUS_LOCATION")
    base = urllib.parse.urlsplit(origin)
    require(parts.netloc == base.netloc, "E_TUS_LOCATION")
    require("@" not in parts.netloc and parts.username is None, "E_TUS_LOCATION")
    require(parts.port is None, "E_TUS_LOCATION")
    require(parts.path.startswith("/storage/v1/upload/resumable/"), "E_TUS_LOCATION")
    require(not parts.query and not parts.fragment, "E_TUS_LOCATION")
    return urllib.parse.urlunsplit(("https", base.netloc, parts.path, "", ""))


# --------------------------------------------------------------------------
# Transport: HTTPS only, redirects disabled, bounded packets
# --------------------------------------------------------------------------


class TransportError(Exception):
    """Transient transport failure (connection, timeout, truncated read)."""


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = {}
        for key, value in (headers or {}).items():
            self.headers[str(key).lower()] = value
        self.body = body

    def header(self, name):
        return self.headers.get(name.lower())


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibTransport:
    """Real transport. Redirects are refused; all reads are size-bounded."""

    def __init__(self, timeout=120):
        self.timeout = timeout
        self.opener = urllib.request.build_opener(_NoRedirects())

    def request(self, method, url, headers, body=None):
        parts = urllib.parse.urlsplit(url)
        require(parts.scheme == "https", "E_ORIGIN")
        require("@" not in parts.netloc and parts.username is None, "E_ORIGIN")
        require(parts.port is None, "E_ORIGIN")
        if body is not None:
            require(len(body) <= MAX_REQUEST_BYTES, "E_SIZE_LIMIT")
        request = urllib.request.Request(url, data=body, method=method)
        for key, value in headers.items():
            request.add_header(key, value)
        try:
            try:
                response = self.opener.open(request, timeout=self.timeout)
            except urllib.error.HTTPError as exc:
                if 300 <= exc.code < 400:
                    fail("E_REDIRECT")
                data = exc.read(MAX_RESPONSE_BYTES + 1)
                require(len(data) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
                return Response(exc.code, dict(exc.headers or {}), data)
            data = response.read(MAX_RESPONSE_BYTES + 1)
            require(len(data) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
            return Response(response.getcode(), dict(response.headers or {}), data)
        except ImportFailure:
            raise
        except Exception:
            raise TransportError()


# --------------------------------------------------------------------------
# Authenticated client: bounded retries, one refresh on 401, identity checks
# --------------------------------------------------------------------------


def _backoff_delay(attempt):
    return min(RETRY_BACKOFF_BASE * (2 ** (attempt - 1)), 30.0)


def _retry_delay(response, attempt):
    retry_after = response.header("retry-after")
    if isinstance(retry_after, str) and retry_after.strip().isdigit():
        return float(min(int(retry_after.strip()), MAX_RETRY_AFTER_SECONDS))
    return _backoff_delay(attempt)


class Client:
    def __init__(
        self,
        config,
        owner,
        session,
        session_doc,
        session_path,
        session_protected,
        transport,
        clock,
        sleeper,
    ):
        self.config = config
        self.owner = owner
        self.session = session
        self.session_doc = session_doc
        self.session_path = session_path
        self.session_protected = session_protected
        self.transport = transport
        self.clock = clock
        self.sleeper = sleeper
        self._refreshing = False

    def _url(self, path, query=None):
        if path.startswith("https://"):
            require(query is None, "E_INTERNAL")
            return path
        return self.config["origin"] + path + (("?" + query) if query else "")

    def _auth_headers(self, extra=None):
        headers = {
            "apikey": self.config["publishable_key"],
            "Authorization": "Bearer " + self.session["access_token"],
        }
        if extra:
            headers.update(extra)
        return headers

    def validate_session_claims(self):
        validate_jwt(
            self.session["access_token"],
            self.config["origin"],
            self.owner,
            self.clock(),
        )

    def ensure_valid_session(self):
        """Claims must be valid; an expired token gets the ordinary refresh,
        any other claim failure aborts."""
        try:
            self.validate_session_claims()
        except ImportFailure as exc:
            if exc.code != "E_AUTH_EXPIRED":
                raise
            self.refresh_session()

    def request(
        self,
        method,
        path,
        *,
        query=None,
        headers=None,
        body=None,
        json_body=None,
        auth=True,
        path_prefix=None,
        allow_query=False,
        retry=True,
    ):
        """retry=False is used for TUS PATCH: an ambiguous failure must be
        resolved by HEAD before any resend, never by blind retry.

        json_body sends an explicitly application/json encoded request body;
        media/TUS calls pass raw bytes with their own binary Content-Type.
        """
        if json_body is not None:
            require(body is None, "E_INTERNAL")
            body = json_dumps(json_body).encode("utf-8")
        url = self._url(path, query)
        ensure_same_origin(
            url,
            self.config["origin"],
            path_prefix=path_prefix,
            allow_query=allow_query or query is not None,
        )
        request_headers = {"apikey": self.config["publishable_key"]}
        if auth:
            request_headers["Authorization"] = "Bearer " + self.session["access_token"]
        if json_body is not None:
            request_headers["Content-Type"] = "application/json"
        if headers:
            request_headers.update(headers)
        if body is not None:
            require(len(body) <= MAX_REQUEST_BYTES, "E_SIZE_LIMIT")
        attempts = 0
        refreshed = False
        while True:
            attempts += 1
            try:
                response = self.transport.request(method, url, request_headers, body)
            except TransportError:
                if not retry or attempts >= MAX_HTTP_ATTEMPTS:
                    fail("E_NETWORK")
                self.sleeper(_backoff_delay(attempts))
                continue
            if response.status == 401 and auth and not refreshed:
                refreshed = True
                self.refresh_session()
                request_headers["Authorization"] = (
                    "Bearer " + self.session["access_token"]
                )
                continue
            if response.status in (408, 429) or 500 <= response.status <= 599:
                if not retry:
                    return response
                if attempts >= MAX_HTTP_ATTEMPTS:
                    fail("E_RETRY_EXHAUSTED")
                self.sleeper(_retry_delay(response, attempts))
                continue
            return response

    def refresh_session(self):
        """Ordinary refresh with the private refresh_token; saved only to the
        same private session file, atomically, preserving safe metadata."""
        require(not self._refreshing, "E_AUTH_REFRESH")
        self._refreshing = True
        try:
            body = json_dumps(
                {"refresh_token": self.session["refresh_token"]}
            ).encode("utf-8")
            require(len(body) <= MAX_REQUEST_BYTES, "E_SIZE_LIMIT")
            url = self._url("/auth/v1/token", "grant_type=refresh_token")
            ensure_same_origin(url, self.config["origin"], allow_query=True)
            try:
                response = self.transport.request(
                    "POST",
                    url,
                    {
                        "apikey": self.config["publishable_key"],
                        "Content-Type": "application/json",
                    },
                    body,
                )
            except TransportError:
                fail("E_AUTH_REFRESH")
            require(200 <= response.status < 300, "E_AUTH_REFRESH")
            require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
            data = json_loads_strict(response.body, "E_AUTH_REFRESH")
            require(isinstance(data, dict), "E_AUTH_REFRESH")
            access_token = data.get("access_token")
            refresh_token = data.get("refresh_token", self.session["refresh_token"])
            require(
                isinstance(access_token, str)
                and 1 <= len(access_token) <= MAX_JWT_BYTES,
                "E_AUTH_REFRESH",
            )
            require(
                isinstance(refresh_token, str)
                and 1 <= len(refresh_token) <= MAX_JWT_BYTES,
                "E_AUTH_REFRESH",
            )
            if "user" in data and data["user"] is not None:
                user = data["user"]
                require(isinstance(user, dict), "E_AUTH_REFRESH")
                require(
                    is_uuid(user.get("id"))
                    and user["id"].lower() == self.owner["user_id_lower"],
                    "E_AUTH_REFRESH",
                )
            self.session["access_token"] = access_token
            self.session["refresh_token"] = refresh_token
            try:
                self.validate_session_claims()
            except ImportFailure:
                fail("E_AUTH_REFRESH")
            merged = dict(self.session_doc)
            merged["access_token"] = access_token
            merged["refresh_token"] = refresh_token
            expires_at = data.get("expires_at")
            if not (
                isinstance(expires_at, (int, float))
                and not isinstance(expires_at, bool)
            ):
                expires_in = data.get("expires_in")
                if isinstance(expires_in, (int, float)) and not isinstance(
                    expires_in, bool
                ):
                    expires_at = self.clock() + float(expires_in)
                else:
                    _header, claims = decode_jwt_claims(access_token)
                    exp = claims.get("exp")
                    require(
                        isinstance(exp, (int, float))
                        and not isinstance(exp, bool)
                        and math.isfinite(exp),
                        "E_AUTH_REFRESH",
                    )
                    expires_at = float(exp)
            merged["expires_at"] = expires_at
            for key in ("expires_in", "token_type", "weak_password"):
                if key in data:
                    merged[key] = data[key]
            validate_session(merged, self.owner)
            self.session_doc = merged
            check_output_path(self.session_path, self.session_protected)
            write_private_atomic(
                self.session_path, (json_dumps(merged) + "\n").encode("utf-8")
            )
            self.verify_identity()
        finally:
            self._refreshing = False

    def verify_identity(self):
        """Server-side identity proof required before any mutation and after
        every refresh; JWT claims alone are never trusted."""
        response = self.request("GET", "/auth/v1/user")
        require(200 <= response.status < 300, "E_AUTH_IDENTITY")
        require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
        data = json_loads_strict(response.body, "E_AUTH_IDENTITY")
        require(isinstance(data, dict), "E_AUTH_IDENTITY")
        require(
            is_uuid(data.get("id"))
            and data["id"].lower() == self.owner["user_id_lower"],
            "E_AUTH_IDENTITY",
        )
        require(
            isinstance(data.get("email"), str)
            and data["email"].lower() == self.owner["email"].lower(),
            "E_AUTH_IDENTITY",
        )
        confirmed = data.get("email_confirmed") is True or bool(
            data.get("email_confirmed_at")
        )
        require(confirmed, "E_AUTH_UNCONFIRMED")


# --------------------------------------------------------------------------
# Reservation throttling (server allows 60 new/min, 100 outstanding)
# --------------------------------------------------------------------------


class ReservationThrottle:
    def __init__(self, clock, sleeper):
        self.clock = clock
        self.sleeper = sleeper
        self._times = deque()
        self.outstanding = 0

    def wait_for_slot(self):
        while True:
            now = self.clock()
            while self._times and self._times[0] <= now - 60.0:
                self._times.popleft()
            if len(self._times) < RESERVATIONS_PER_MINUTE:
                self._times.append(self.clock())
                return
            self.sleeper(max(0.05, self._times[0] + 60.0 - now + 0.05))

    def note_reserved(self, is_new):
        if is_new:
            self.outstanding += 1
            require(
                self.outstanding < MAX_OUTSTANDING_RESERVATIONS, "E_THROTTLE"
            )

    def note_committed(self):
        self.outstanding = 0


# --------------------------------------------------------------------------
# Media: reserve, direct upload, TUS resumable upload, private byte proof
# --------------------------------------------------------------------------


def expected_object_key(owner, memo_id, descriptor):
    return "%s/%s/%s.%s" % (
        owner["user_id_lower"],
        memo_id.lower(),
        descriptor["content_sha256"],
        MIME_EXTENSIONS[descriptor["mime_type"]],
    )


def prepare_attachment(client, throttle, owner, memo_id, descriptor):
    throttle.wait_for_slot()
    request_body = {
        "p_memo_id": memo_id,
        "p_content_sha256": descriptor["content_sha256"],
        "p_size_bytes": descriptor["size_bytes"],
        "p_mime_type": descriptor["mime_type"],
        "p_extension": MIME_EXTENSIONS[descriptor["mime_type"]],
    }
    response = client.request(
        "POST",
        "/rest/v1/rpc/daypage_prepare_attachment_upload",
        json_body=request_body,
    )
    require(200 <= response.status < 300, "E_RESERVATION")
    require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
    data = json_loads_strict(response.body, "E_RESERVATION")
    require(isinstance(data, dict), "E_RESERVATION")
    require(
        set(data.keys())
        == {"reservation_id", "object_key", "expires_at", "already_exists"},
        "E_RESERVATION",
    )
    require(is_uuid(data["reservation_id"]), "E_RESERVATION")
    require(
        data["object_key"] == expected_object_key(owner, memo_id, descriptor),
        "E_OBJECT_KEY",
    )
    expires_at = parse_timestamp(data["expires_at"])
    require(
        expires_at is not None and expires_at > now_micros(client.clock()),
        "E_RESERVATION",
    )
    require(isinstance(data["already_exists"], bool), "E_RESERVATION")
    throttle.note_reserved(not data["already_exists"])
    return data


def fetch_object_bytes(client, object_key):
    response = client.request(
        "GET",
        "/storage/v1/object/authenticated/memo-attachments/" + object_key,
        headers={"Accept-Encoding": "identity"},
    )
    require(200 <= response.status < 300, "E_MEDIA_HASH")
    require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
    return response.body


def verify_remote_object(client, descriptor):
    body = fetch_object_bytes(client, descriptor["object_key"])
    require(len(body) == descriptor["size_bytes"], "E_MEDIA_HASH")
    require(sha256_bytes(body) == descriptor["content_sha256"], "E_MEDIA_HASH")


def upload_direct(client, descriptor, data):
    response = client.request(
        "POST",
        "/storage/v1/object/memo-attachments/" + descriptor["object_key"],
        headers={
            "Content-Type": descriptor["mime_type"],
            "x-upsert": "false",
        },
        body=data,
    )
    if response.status in (400, 409):
        return "conflict"
    require(200 <= response.status < 300, "E_UPLOAD_FAILED")
    return "uploaded"


def tus_upload(client, descriptor, local_path, saved_state, save_state):
    """Resumable TUS upload with 6MiB chunks.

    Resume HEAD offset is authoritative (0..size, matching length). An
    ambiguous PATCH is resolved by HEAD before any retry; a wrong observed
    offset aborts. 404/410 restarts the upload safely (bounded).
    """
    size = descriptor["size_bytes"]
    url = None
    offset = 0
    restarts = 0
    if saved_state is not None:
        require(
            isinstance(saved_state, dict)
            and isinstance(saved_state.get("url"), str)
            and isinstance(saved_state.get("offset"), int)
            and not isinstance(saved_state.get("offset"), bool),
            "E_CHECKPOINT_SHAPE",
        )
        resume_url = resolve_tus_location(saved_state["url"], client.config["origin"])
        head = _tus_head(client, resume_url, size)
        if head is not None:
            require(0 <= head <= size, "E_TUS_OFFSET")
            url = resume_url
            offset = head
    while True:
        if url is None:
            require(restarts <= 2, "E_TUS_STATE")
            created = _tus_create(client, descriptor)
            if created is None:
                return "exists"
            url = created
            offset = 0
            save_state(url, offset)
        while offset < size:
            chunk = _read_chunk(
                descriptor, local_path, offset, min(TUS_CHUNK_BYTES, size - offset)
            )
            chunk_tries = 0
            advanced_offset = None
            while advanced_offset is None:
                chunk_tries += 1
                require(chunk_tries <= 5, "E_NETWORK")  # bounded no-progress budget
                status, advanced, delay = _tus_patch(client, url, offset, chunk)
                if status == "gone":
                    url = None
                    restarts += 1
                    break
                if status == "ambiguous":
                    # Authoritative HEAD before ANY resend of this chunk.
                    observed = _tus_head(client, url, size)
                    if observed is None:
                        url = None
                        restarts += 1
                        break
                    if observed == offset + len(chunk):
                        advanced_offset = observed
                    elif observed == offset:
                        # No progress: honor bounded Retry-After/backoff before
                        # a safe resend of the identical chunk.
                        client.sleeper(_bounded_delay(delay, chunk_tries))
                        continue
                    else:
                        fail("E_TUS_OFFSET")
                else:
                    require(advanced == offset + len(chunk), "E_TUS_OFFSET")
                    advanced_offset = advanced
            if url is None:
                break
            offset = advanced_offset
            save_state(url, offset)
        if url is not None and offset >= size:
            final_offset = _tus_head(client, url, size)
            if final_offset is None:
                url = None
                restarts += 1
                continue
            require(final_offset == size, "E_TUS_OFFSET")
            return "uploaded"


def _read_chunk(descriptor, local_path, offset, count):
    fd, st = open_regular(local_path)
    try:
        data = os.pread(fd, count, offset)
    finally:
        os.close(fd)
    require(len(data) == count, "E_FILE_SIZE")
    return data


def _tus_create(client, descriptor):
    metadata_values = [
        ("bucketName", "memo-attachments"),
        ("objectName", descriptor["object_key"]),
        ("contentType", descriptor["mime_type"]),
        ("cacheControl", "3600"),
    ]
    metadata = ",".join(
        "%s %s"
        % (key, base64.b64encode(value.encode("utf-8")).decode("ascii"))
        for key, value in metadata_values
    )
    response = client.request(
        "POST",
        "/storage/v1/upload/resumable/",
        headers={
            "Tus-Resumable": "1.0.0",
            "Upload-Length": str(descriptor["size_bytes"]),
            "Upload-Metadata": metadata,
            "x-upsert": "false",
        },
        body=b"",
    )
    if response.status in (400, 409):
        return None
    require(200 <= response.status < 300, "E_UPLOAD_FAILED")
    location = response.header("location")
    require(location, "E_TUS_LOCATION")
    return resolve_tus_location(location, client.config["origin"])


def _tus_head(client, url, size):
    """Authoritative offset probe for a fixed-length upload. Returns None when
    the upload resource is gone (404/410) so callers restart safely."""
    ensure_same_origin(
        url,
        client.config["origin"],
        path_prefix="/storage/v1/upload/resumable/",
    )
    response = client.request("HEAD", url, headers={"Tus-Resumable": "1.0.0"})
    if response.status in (404, 410):
        return None
    require(200 <= response.status < 300, "E_TUS_STATE")
    upload_length = response.header("upload-length")
    require(
        isinstance(upload_length, str) and upload_length.strip().isdigit(),
        "E_TUS_STATE",
    )
    require(int(upload_length.strip()) == size, "E_TUS_STATE")
    upload_offset = response.header("upload-offset")
    require(
        isinstance(upload_offset, str) and upload_offset.strip().isdigit(),
        "E_TUS_STATE",
    )
    return int(upload_offset.strip())


def _bounded_delay(delay, attempt):
    if delay is not None:
        return min(float(delay), MAX_RETRY_AFTER_SECONDS)
    return _backoff_delay(attempt)


def _tus_patch(client, url, offset, chunk):
    """Returns (status, advanced_offset, retry_delay_hint). Ambiguous
    outcomes carry the bounded server Retry-After (or None for backoff); the
    caller must HEAD before any resend."""
    ensure_same_origin(
        url,
        client.config["origin"],
        path_prefix="/storage/v1/upload/resumable/",
    )
    try:
        response = client.request(
            "PATCH",
            url,
            headers={
                "Tus-Resumable": "1.0.0",
                "Content-Type": "application/offset+octet-stream",
                "Upload-Offset": str(offset),
            },
            body=chunk,
            retry=False,
        )
    except ImportFailure as exc:
        if exc.code in ("E_NETWORK", "E_RETRY_EXHAUSTED"):
            return "ambiguous", None, None
        raise
    if response.status in (404, 410):
        return "gone", None, None
    if response.status in (408, 429) or 500 <= response.status <= 599:
        return "ambiguous", None, _retry_delay(response, 1)
    require(200 <= response.status < 300, "E_TUS_STATE")
    upload_offset = response.header("upload-offset")
    require(
        isinstance(upload_offset, str) and upload_offset.strip().isdigit(),
        "E_TUS_STATE",
    )
    return "ok", int(upload_offset.strip()), None


def _read_local_bounded(path, size):
    fd, _st = open_regular(path)
    chunks = []
    total = 0
    try:
        while total <= size:
            chunk = os.read(fd, size + 1 - total)
            if not chunk:
                break
            total += len(chunk)
            chunks.append(chunk)
    finally:
        os.close(fd)
    require(total == size, "E_FILE_SIZE")
    return b"".join(chunks)


def ensure_uploaded(
    client, throttle, owner, memo_id, descriptor, local_path, checkpoint, saver
):
    """Bring one object into the private bucket with a CURRENT reservation.

    prepare always runs (idempotent) so the reservation is live/refreshed even
    on resume. A checkpoint uploaded/verified flag is only an upload skip hint:
    it is never byte proof and never reservation proof; the byte proof is the
    mandatory precommit GET done by the caller for every descriptor.
    """
    object_key = descriptor["object_key"]
    preparation = prepare_attachment(client, throttle, owner, memo_id, descriptor)
    checkpointed = checkpoint.get("uploads", {}).get(object_key)
    if (
        isinstance(checkpointed, dict)
        and checkpointed.get("state") in ("uploaded", "verified")
        and preparation["already_exists"]
    ):
        return  # object present; precommit GET proof runs before the commit
    data = None
    if descriptor["size_bytes"] <= DIRECT_UPLOAD_MAX_BYTES:
        data = _read_local_bounded(local_path, descriptor["size_bytes"])
    if data is not None:
        outcome = upload_direct(client, descriptor, data)
        if outcome == "conflict":
            checkpoint_mark(checkpoint, saver, object_key, descriptor, "uploaded")
            return
    else:
        tus_state = checkpoint.get("tus", {}).get(object_key)
        outcome = tus_upload(
            client,
            descriptor,
            local_path,
            tus_state,
            lambda url, offset: save_tus_state(
                checkpoint, saver, object_key, url, offset
            ),
        )
        if outcome == "exists":
            checkpoint_mark(checkpoint, saver, object_key, descriptor, "uploaded")
            return
    checkpoint_mark(checkpoint, saver, object_key, descriptor, "uploaded")


def mark_verified(checkpoint, saver, descriptors):
    """Record post-proof state only after the precommit GET byte proof."""
    for descriptor in descriptors:
        checkpoint.setdefault("uploads", {})[descriptor["object_key"]] = {
            "sha256": descriptor["content_sha256"],
            "size_bytes": descriptor["size_bytes"],
            "state": "verified",
        }
    saver()


def checkpoint_mark(checkpoint, saver, object_key, descriptor, state):
    checkpoint.setdefault("uploads", {})[object_key] = {
        "sha256": descriptor["content_sha256"],
        "size_bytes": descriptor["size_bytes"],
        "state": state,
    }
    tus = checkpoint.get("tus")
    if isinstance(tus, dict):
        tus.pop(object_key, None)
    saver()


def save_tus_state(checkpoint, saver, object_key, url, offset):
    checkpoint.setdefault("tus", {})[object_key] = {"url": url, "offset": offset}
    saver()


# --------------------------------------------------------------------------
# Commit: exact per-operation accepted receipts, idempotent by operation_id
# --------------------------------------------------------------------------


def commit_operations(client, operations):
    require(1 <= len(operations) <= 100, "E_INTERNAL")  # server RPC cap
    response = client.request(
        "POST",
        "/rest/v1/rpc/daypage_apply_sync_operations_v2",
        json_body={"p_operations": operations},
    )
    require(200 <= response.status < 300, "E_POLICY")
    require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
    result = json_loads_strict(response.body, "E_COMMIT_RECEIPT")
    require(isinstance(result, dict), "E_COMMIT_RECEIPT")
    require(set(result.keys()) == {"accepted", "rejected"}, "E_COMMIT_RECEIPT")
    require(
        isinstance(result["rejected"], list) and len(result["rejected"]) == 0,
        "E_COMMIT_RECEIPT",
    )
    accepted = result["accepted"]
    require(
        isinstance(accepted, list) and len(accepted) == len(operations),
        "E_COMMIT_RECEIPT",
    )
    expected = {op["operation_id"].lower(): op for op in operations}
    seen = set()
    for entry in accepted:
        require(isinstance(entry, dict), "E_COMMIT_RECEIPT")
        require(
            set(entry.keys())
            == {
                "operation_id",
                "memo_id",
                "revision",
                "remote_revision",
                "status",
                "attachment_manifest_hash",
            },
            "E_COMMIT_RECEIPT",
        )
        operation_id = entry["operation_id"]
        require(
            is_uuid(operation_id)
            and operation_id.lower() in expected
            and operation_id.lower() not in seen,
            "E_COMMIT_RECEIPT",
        )
        seen.add(operation_id.lower())
        operation = expected[operation_id.lower()]
        require(
            isinstance(entry["memo_id"], str)
            and entry["memo_id"].lower() == operation["memo_id"].lower(),
            "E_COMMIT_RECEIPT",
        )
        require(entry["revision"] == operation["revision"], "E_COMMIT_RECEIPT")
        require(entry["status"] == "applied", "E_COMMIT_CONFLICT")
        remote_revision = entry["remote_revision"]
        require(
            isinstance(remote_revision, int)
            and not isinstance(remote_revision, bool)
            and remote_revision >= operation["revision"],
            "E_COMMIT_CONFLICT",
        )
        require(
            entry["attachment_manifest_hash"] == operation["attachment_manifest_hash"],
            "E_COMMIT_RECEIPT",
        )
    require(len(seen) == len(operations), "E_COMMIT_RECEIPT")


# --------------------------------------------------------------------------
# Tags: exact import, exact result counts, exact snapshot readback
# --------------------------------------------------------------------------


def import_tags(client, source_sha256, tag_info):
    response = client.request(
        "POST",
        "/rest/v1/rpc/daypage_import_tags_v1",
        json_body={"p_source_sha256": source_sha256, "p_payload": tag_info["payload"]},
    )
    require(200 <= response.status < 300, "E_POLICY")
    require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
    result = json_loads_strict(response.body, "E_TAG_RECEIPT")
    require(isinstance(result, dict), "E_TAG_RECEIPT")
    require(
        set(result.keys())
        == {
            "version",
            "source_sha256",
            "status",
            "catalog_labels",
            "distinct_labels",
            "memos",
            "memberships",
        },
        "E_TAG_RECEIPT",
    )
    require(result["version"] == 1, "E_TAG_RECEIPT")
    require(result["source_sha256"] == source_sha256, "E_TAG_RECEIPT")
    require(result["status"] in ("imported", "replayed"), "E_TAG_RECEIPT")
    require(result["catalog_labels"] == tag_info["catalog_labels"], "E_TAG_RECEIPT")
    require(result["distinct_labels"] == tag_info["distinct_labels"], "E_TAG_RECEIPT")
    require(result["memos"] == tag_info["memos"], "E_TAG_RECEIPT")
    require(result["memberships"] == tag_info["memberships"], "E_TAG_RECEIPT")
    return result


def read_tag_snapshot(client, source_sha256, tag_payload):
    query = (
        "select=version,source_sha256,payload_hash,payload,created_at"
        "&source_sha256=eq." + source_sha256
    )
    response = client.request(
        "GET", "/rest/v1/memo_tag_imports", query=query
    )
    require(200 <= response.status < 300, "E_TAG_SNAPSHOT")
    require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
    rows = json_loads_strict(response.body, "E_TAG_SNAPSHOT")
    require(isinstance(rows, list) and len(rows) == 1, "E_TAG_SNAPSHOT")
    row = rows[0]
    require(isinstance(row, dict), "E_TAG_SNAPSHOT")
    require(
        set(row.keys())
        == {"version", "source_sha256", "payload_hash", "payload", "created_at"},
        "E_TAG_SNAPSHOT",
    )
    require(row["version"] == 1, "E_TAG_SNAPSHOT")
    require(row["source_sha256"] == source_sha256, "E_TAG_SNAPSHOT")
    require(is_hash(row["payload_hash"]), "E_TAG_SNAPSHOT")
    require(is_timestamp(row["created_at"]), "E_TAG_SNAPSHOT")
    require(row["payload"] == tag_payload, "E_TAG_SNAPSHOT")


# --------------------------------------------------------------------------
# Full readback: complete pull progression and per-memo verification
# --------------------------------------------------------------------------


def pull_all_changes(client):
    cursor = 0
    changes = []
    seen_ids = set()
    seen_sequences = set()
    iterations = 0
    while True:
        iterations += 1
        require(iterations <= 10000, "E_PULL_PROGRESSION")
        response = client.request(
            "POST",
            "/rest/v1/rpc/daypage_pull_sync_changes_v2",
            json_body={"p_after_sequence": cursor, "p_limit": PULL_LIMIT},
        )
        require(200 <= response.status < 300, "E_POLICY")
        require(len(response.body) <= MAX_RESPONSE_BYTES, "E_RESPONSE_SIZE")
        data = json_loads_strict(response.body, "E_PULL_SHAPE")
        require(isinstance(data, dict), "E_PULL_SHAPE")
        require(
            set(data.keys()) == {"changes", "next_cursor", "has_more"},
            "E_PULL_SHAPE",
        )
        batch = data["changes"]
        require(isinstance(batch, list), "E_PULL_SHAPE")
        require(len(batch) <= PULL_LIMIT, "E_PULL_SHAPE")
        require(
            isinstance(data["next_cursor"], int)
            and not isinstance(data["next_cursor"], bool),
            "E_PULL_SHAPE",
        )
        require(isinstance(data["has_more"], bool), "E_PULL_SHAPE")
        previous_sequence = None
        for change in batch:
            require(isinstance(change, dict), "E_PULL_SHAPE")
            require(
                {
                    "id",
                    "type",
                    "body",
                    "created_at",
                    "content_hash",
                    "sync_revision",
                    "attachment_manifest_hash",
                    "deleted_at",
                    "change_sequence",
                    "attachments",
                }
                <= set(change.keys()),
                "E_PULL_SHAPE",
            )
            change_id = change["id"]
            sequence = change["change_sequence"]
            require(is_uuid(change_id), "E_PULL_SHAPE")
            require(
                isinstance(sequence, int)
                and not isinstance(sequence, bool),
                "E_PULL_SHAPE",
            )
            key = change_id.lower()
            require(key not in seen_ids, "E_PULL_SHAPE")
            require(sequence not in seen_sequences, "E_PULL_SHAPE")
            require(sequence > cursor, "E_PULL_PROGRESSION")
            if previous_sequence is not None:
                require(sequence > previous_sequence, "E_PULL_SHAPE")
            previous_sequence = sequence
            seen_ids.add(key)
            seen_sequences.add(sequence)
            changes.append(change)
        # Canonical cursor binding: next_cursor is the maximum returned
        # sequence (gaps are legitimate), or the unchanged cursor for an empty
        # terminal page. Jumped/backward cursors abort.
        next_cursor = data["next_cursor"]
        canonical_cursor = previous_sequence if batch else cursor
        require(next_cursor == canonical_cursor, "E_PULL_PROGRESSION")
        if data["has_more"]:
            require(next_cursor > cursor, "E_PULL_PROGRESSION")
        cursor = next_cursor
        if not data["has_more"]:
            return changes


def _attachments_equal(remote, local):
    if not isinstance(remote, list) or len(remote) != len(local):
        return False
    remote_sorted = sorted(
        remote,
        key=lambda item: item.get("position")
        if isinstance(item, dict) and isinstance(item.get("position"), int)
        else -1,
    )
    local_sorted = sorted(local, key=lambda item: item["position"])
    for remote_item, local_item in zip(remote_sorted, local_sorted):
        if not isinstance(remote_item, dict):
            return False
        for key in (
            "position",
            "kind",
            "content_sha256",
            "size_bytes",
            "mime_type",
            "object_key",
            "original_filename",
        ):
            if remote_item.get(key) != local_item.get(key):
                return False
        for key in ("duration_ms", "transcript", "transcription_status"):
            if remote_item.get(key) != local_item.get(key):
                # jsonb roundtrip keeps explicit nulls; None == absent here
                if not (
                    remote_item.get(key) is None and local_item.get(key) is None
                ):
                    return False
    return True


def verify_imported_memos(changes, export_info):
    by_id = {}
    for change in changes:
        by_id[change["id"].lower()] = change
    for record in export_info["records"]:
        operation = record["operation"]
        payload = operation["payload"]
        change = by_id.get(operation["memo_id"].lower())
        require(change is not None, "E_PULL_MISMATCH")
        require(change.get("deleted_at") is None, "E_PULL_MISMATCH")
        body = change.get("body")
        require(isinstance(body, str), "E_PULL_MISMATCH")
        require(
            sha256_bytes(body.encode("utf-8")) == record["body_sha256"],
            "E_PULL_MISMATCH",
        )
        require(change.get("type") == payload["type"], "E_PULL_MISMATCH")
        remote_created = parse_timestamp(change.get("created_at"))
        local_created = parse_timestamp(payload["created_at"])
        require(
            remote_created is not None
            and local_created is not None
            and remote_created == local_created,
            "E_PULL_MISMATCH",
        )
        require(change.get("content_hash") == operation["content_hash"], "E_PULL_MISMATCH")
        require(change.get("sync_revision") == operation["revision"], "E_PULL_MISMATCH")
        require(
            change.get("attachment_manifest_hash")
            == operation["attachment_manifest_hash"],
            "E_PULL_MISMATCH",
        )
        require(
            _attachments_equal(change.get("attachments"), payload["attachments"]),
            "E_PULL_MISMATCH",
        )


def verify_all_media(client, export_info):
    for record in export_info["records"]:
        for descriptor in record["operation"]["payload"]["attachments"]:
            verify_remote_object(client, descriptor)


# --------------------------------------------------------------------------
# Checkpoint: private, bound, durable, single-writer resumable state
# --------------------------------------------------------------------------


CHECKPOINT_KEYS = {
    "version",
    "project_id",
    "owner_user_id",
    "export_sha256",
    "tag_payload_sha256",
    "source_zip_sha256",
    "uploads",
    "tus",
    "committed_operations",
    "tags_state",
    "readback_verified",
}


def fresh_checkpoint(binding):
    checkpoint = dict(binding)
    checkpoint.update(
        {
            "uploads": {},
            "tus": {},
            "committed_operations": {},
            "tags_state": None,
            "readback_verified": False,
        }
    )
    return checkpoint


def checkpoint_binding(config, owner, export_sha256, tag_payload_sha256, source_zip_sha256):
    return {
        "version": 1,
        "project_id": config["project_id"],
        "owner_user_id": owner["user_id"],
        "export_sha256": export_sha256,
        "tag_payload_sha256": tag_payload_sha256,
        "source_zip_sha256": source_zip_sha256,
    }


def validate_checkpoint(doc):
    require(isinstance(doc, dict), "E_CHECKPOINT_SHAPE")
    require(set(doc.keys()) == CHECKPOINT_KEYS, "E_CHECKPOINT_SHAPE")
    require(doc["version"] == 1, "E_CHECKPOINT_SHAPE")
    require(isinstance(doc["project_id"], str), "E_CHECKPOINT_SHAPE")
    require(is_uuid(doc["owner_user_id"]), "E_CHECKPOINT_SHAPE")
    require(is_hash(doc["export_sha256"]), "E_CHECKPOINT_SHAPE")
    require(is_hash(doc["tag_payload_sha256"]), "E_CHECKPOINT_SHAPE")
    require(is_hash(doc["source_zip_sha256"]), "E_CHECKPOINT_SHAPE")
    uploads = doc["uploads"]
    require(isinstance(uploads, dict) and len(uploads) <= 20000, "E_CHECKPOINT_SHAPE")
    for key, entry in uploads.items():
        require(isinstance(key, str) and 1 <= len(key) <= 512, "E_CHECKPOINT_SHAPE")
        require(isinstance(entry, dict), "E_CHECKPOINT_SHAPE")
        require(
            set(entry.keys()) == {"sha256", "size_bytes", "state"},
            "E_CHECKPOINT_SHAPE",
        )
        require(is_hash(entry["sha256"]), "E_CHECKPOINT_SHAPE")
        require(
            isinstance(entry["size_bytes"], int)
            and not isinstance(entry["size_bytes"], bool)
            and entry["size_bytes"] >= 1,
            "E_CHECKPOINT_SHAPE",
        )
        require(entry["state"] in ("uploaded", "verified"), "E_CHECKPOINT_SHAPE")
    tus = doc["tus"]
    require(isinstance(tus, dict) and len(tus) <= 20000, "E_CHECKPOINT_SHAPE")
    for key, entry in tus.items():
        require(isinstance(key, str) and 1 <= len(key) <= 512, "E_CHECKPOINT_SHAPE")
        require(isinstance(entry, dict), "E_CHECKPOINT_SHAPE")
        require(set(entry.keys()) == {"url", "offset"}, "E_CHECKPOINT_SHAPE")
        require(
            isinstance(entry["url"], str) and 1 <= len(entry["url"]) <= 2048,
            "E_CHECKPOINT_SHAPE",
        )
        require(
            isinstance(entry["offset"], int)
            and not isinstance(entry["offset"], bool)
            and entry["offset"] >= 0,
            "E_CHECKPOINT_SHAPE",
        )
    committed = doc["committed_operations"]
    require(
        isinstance(committed, dict) and len(committed) <= 20000,
        "E_CHECKPOINT_SHAPE",
    )
    for key, entry in committed.items():
        require(is_uuid(key), "E_CHECKPOINT_SHAPE")
        require(isinstance(entry, dict), "E_CHECKPOINT_SHAPE")
        require(
            set(entry.keys()) == {"memo_id", "attachment_manifest_hash"},
            "E_CHECKPOINT_SHAPE",
        )
        require(is_uuid(entry["memo_id"]), "E_CHECKPOINT_SHAPE")
        require(
            entry["attachment_manifest_hash"] is None
            or is_hash(entry["attachment_manifest_hash"]),
            "E_CHECKPOINT_SHAPE",
        )
    tags_state = doc["tags_state"]
    require(tags_state is None or isinstance(tags_state, dict), "E_CHECKPOINT_SHAPE")
    if tags_state is not None:
        validate_safe_metadata(tags_state)
    require(isinstance(doc["readback_verified"], bool), "E_CHECKPOINT_SHAPE")


def load_checkpoint(path, binding):
    if not os.path.lexists(path):
        return fresh_checkpoint(binding)
    doc, _raw = read_private_json(path, MAX_CHECKPOINT_BYTES)
    validate_checkpoint(doc)
    require(doc["project_id"] == binding["project_id"], "E_CHECKPOINT_BIND")
    require(
        doc["owner_user_id"].lower() == binding["owner_user_id"].lower(),
        "E_CHECKPOINT_BIND",
    )
    require(doc["export_sha256"] == binding["export_sha256"], "E_CHECKPOINT_BIND")
    require(
        doc["tag_payload_sha256"] == binding["tag_payload_sha256"],
        "E_CHECKPOINT_BIND",
    )
    require(
        doc["source_zip_sha256"] == binding["source_zip_sha256"],
        "E_CHECKPOINT_BIND",
    )
    return doc


def save_checkpoint(path, doc):
    write_private_atomic(path, (json_dumps(doc) + "\n").encode("utf-8"))


def check_existing_receipt(path, export_sha256):
    """A completed receipt is reverified and rewritten, never blindly
    overwritten with an unrelated import."""
    if not os.path.lexists(path):
        return
    try:
        doc, _raw = read_json(path, MAX_PREFLIGHT_BYTES)
    except ImportFailure:
        return
    if (
        isinstance(doc, dict)
        and doc.get("result") == "passed"
        and doc.get("export_sha256") != export_sha256
    ):
        fail("E_RECEIPT_CONFLICT")


# --------------------------------------------------------------------------
# Reports: aggregate counts/hashes only
# --------------------------------------------------------------------------


def build_report(
    result, config, export_sha256, export_info, tag_payload_sha256, tag_info, tags_result=None
):
    report = {
        "result": result,
        "project_id": config["project_id"],
        "export_sha256": export_sha256,
        "source_zip_sha256": export_info["source_zip_sha256"],
        "tag_payload_sha256": tag_payload_sha256,
        "memos": export_info["memos"],
        "attachments": export_info["attachments"],
        "attachment_bytes": export_info["attachment_bytes"],
        "tag_catalog_labels": tag_info["catalog_labels"],
        "tag_distinct_labels": tag_info["distinct_labels"],
        "tag_memos": tag_info["memos"],
        "tag_memberships": tag_info["memberships"],
    }
    if result == "passed":
        report.update(
            {
                "imported_memos": export_info["memos"],
                "imported_attachments": export_info["attachments"],
                "imported_attachment_bytes": export_info["attachment_bytes"],
                "tag_status": tags_result["status"],
                "manifest_hash_verified": True,
                "media_reverified": True,
                "tag_snapshot_verified": True,
                "readback_verified": True,
            }
        )
    return report


# --------------------------------------------------------------------------
# Runner: offline dry-run (default) and explicit --execute import
# --------------------------------------------------------------------------


def run(args, transport_factory, clock, sleeper):
    input_paths = [
        args.config,
        args.owner,
        args.session,
        args.operations,
        args.preflight_receipt,
        args.tags,
    ]
    check_output_path(args.session, input_paths[0:2] + input_paths[3:] + [args.checkpoint, args.receipt])
    check_output_path(
        args.checkpoint,
        [args.config, args.owner, args.session, args.operations, args.preflight_receipt, args.tags, args.receipt],
    )
    check_output_path(
        args.receipt,
        [args.config, args.owner, args.session, args.operations, args.preflight_receipt, args.tags, args.checkpoint],
    )
    check_output_path(
        args.checkpoint + ".lock", input_paths + [args.checkpoint, args.receipt]
    )

    config_doc, _ = read_private_json(args.config, MAX_CONFIG_BYTES)
    config = validate_config(config_doc)
    owner_doc, _ = read_private_json(args.owner, MAX_OWNER_BYTES)
    owner = validate_owner(owner_doc, config)
    session_doc, _ = read_private_json(args.session, MAX_SESSION_BYTES)
    session = validate_session(session_doc, owner)

    export_doc, export_raw = read_json(args.operations, MAX_EXPORT_BYTES)
    export_sha256 = sha256_bytes(export_raw)
    export_info = validate_export(export_doc, config, owner)
    export_info["export_sha256"] = export_sha256

    require(isinstance(args.vault, str) and args.vault, "E_FILE_ESCAPE")
    require(os.path.isdir(args.vault) and not os.path.islink(args.vault), "E_FILE_ESCAPE")
    raw_root = os.path.join(args.vault, "raw")
    require(os.path.isdir(raw_root) and not os.path.islink(raw_root), "E_FILE_ESCAPE")
    asset_paths = verify_local_files(export_info, raw_root)

    # Mutable outputs (session/checkpoint/receipt and the checkpoint lock) must
    # never alias any validated input asset (path or hardlink, even outside the
    # Vault) and must never live under the Vault. Checked before any writing,
    # lock creation or network access.
    vault_real = os.path.realpath(args.vault)
    for output_path in (
        args.session,
        args.checkpoint,
        args.checkpoint + ".lock",
        args.receipt,
    ):
        others = [
            path
            for path in input_paths + asset_paths
            if os.path.abspath(path) != os.path.abspath(output_path)
        ]
        check_output_path(output_path, others)
        check_output_outside_vault(output_path, vault_real)

    tags_doc, tags_raw = read_json(args.tags, MAX_TAGS_BYTES)
    tag_info = validate_tags(tags_doc, export_info["memo_ids"])
    tag_payload_sha256 = sha256_bytes(tags_raw)

    preflight_doc, _ = read_json(args.preflight_receipt, MAX_PREFLIGHT_BYTES)
    validate_preflight(
        preflight_doc,
        export_sha256,
        export_info["memos"],
        export_info["attachments"],
        export_info["attachment_bytes"],
    )

    if not args.execute:
        report = build_report(
            "dry_run",
            config,
            export_sha256,
            export_info,
            tag_payload_sha256,
            tag_info,
        )
        write_private_atomic(
            args.receipt, (json_dumps(report) + "\n").encode("utf-8")
        )
        return report

    check_existing_receipt(args.receipt, export_sha256)
    binding = checkpoint_binding(
        config, owner, export_sha256, tag_payload_sha256, export_info["source_zip_sha256"]
    )
    transport = transport_factory()
    client = Client(
        config,
        owner,
        session,
        session_doc,
        args.session,
        [
            args.config,
            args.owner,
            args.operations,
            args.preflight_receipt,
            args.tags,
            args.checkpoint,
            args.receipt,
        ],
        transport,
        clock,
        sleeper,
    )
    throttle = ReservationThrottle(clock, sleeper)
    with CheckpointLock(args.checkpoint):
        checkpoint = load_checkpoint(args.checkpoint, binding)

        def saver():
            save_checkpoint(args.checkpoint, checkpoint)

        def mark_committed(operations):
            for operation in operations:
                checkpoint.setdefault("committed_operations", {})[
                    operation["operation_id"]
                ] = {
                    "memo_id": operation["memo_id"],
                    "attachment_manifest_hash": operation[
                        "attachment_manifest_hash"
                    ],
                }
            throttle.note_committed()
            saver()

        def commit_new(operations):
            pending = [
                operation
                for operation in operations
                if operation["operation_id"] not in checkpoint["committed_operations"]
            ]
            if not pending:
                return
            commit_operations(client, pending)
            mark_committed(pending)

        # Server-verified identity before the first mutation; JWT claims alone
        # are never sufficient. Offline dry-run above made zero requests.
        client.ensure_valid_session()
        client.verify_identity()

        text_batch = []
        raw_real = os.path.realpath(raw_root)
        for record in export_info["records"]:
            operation = record["operation"]
            attachments = operation["payload"]["attachments"]
            if attachments:
                if text_batch:
                    commit_new(text_batch)
                    text_batch = []
                for descriptor, relative in zip(
                    attachments, record["local_files"]
                ):
                    local_path = resolve_local_file(raw_root, raw_real, relative)
                    ensure_uploaded(
                        client,
                        throttle,
                        owner,
                        operation["memo_id"],
                        descriptor,
                        local_path,
                        checkpoint,
                        saver,
                    )
                # Full private GET length/SHA proof for EVERY descriptor,
                # including resumed checkpoint entries and pre-existing
                # objects, before this memo may commit. A saved uploaded or
                # verified flag never proves current bytes.
                for descriptor in attachments:
                    verify_remote_object(client, descriptor)
                mark_verified(checkpoint, saver, attachments)
                commit_new([operation])
            else:
                text_batch.append(operation)
                if len(text_batch) >= COMMIT_TEXT_BATCH:
                    commit_new(text_batch)
                    text_batch = []
        if text_batch:
            commit_new(text_batch)

        tags_result = import_tags(
            client, export_info["source_zip_sha256"], tag_info
        )
        read_tag_snapshot(
            client, export_info["source_zip_sha256"], tags_doc
        )

        changes = pull_all_changes(client)
        verify_imported_memos(changes, export_info)
        verify_all_media(client, export_info)
        # Final exact tag snapshot proof after the full media readback.
        read_tag_snapshot(
            client, export_info["source_zip_sha256"], tags_doc
        )

        checkpoint["tags_state"] = {
            "status": tags_result["status"],
            "catalog_labels": tags_result["catalog_labels"],
            "distinct_labels": tags_result["distinct_labels"],
            "memos": tags_result["memos"],
            "memberships": tags_result["memberships"],
        }
        checkpoint["readback_verified"] = True
        saver()

    report = build_report(
        "passed",
        config,
        export_sha256,
        export_info,
        tag_payload_sha256,
        tag_info,
        tags_result,
    )
    write_private_atomic(args.receipt, (json_dumps(report) + "\n").encode("utf-8"))
    return report


# --------------------------------------------------------------------------
# CLI entry
# --------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        prog="shared_backend_import",
        description=(
            "Import a prevalidated DayPage operation export into the shared "
            "backend. Default is an offline dry-run with no network access."
        ),
    )
    parser.add_argument("--config", required=True, help="private config JSON")
    parser.add_argument("--owner", required=True, help="owner identity JSON")
    parser.add_argument("--session", required=True, help="private auth session JSON")
    parser.add_argument("--operations", required=True, help="operation export JSON")
    parser.add_argument(
        "--preflight-receipt", required=True, help="independent preflight receipt JSON"
    )
    parser.add_argument("--vault", required=True, help="vault root (contains raw/)")
    parser.add_argument("--tags", required=True, help="tag import payload v1 JSON")
    parser.add_argument("--checkpoint", required=True, help="private resumable state")
    parser.add_argument("--receipt", required=True, help="safe aggregate report")
    parser.add_argument(
        "--execute",
        action="store_true",
        help="perform the real import (operator action; default is dry-run)",
    )
    return parser


def main(argv=None, transport_factory=None, clock=None, sleeper=None):
    args = build_parser().parse_args(argv)
    if clock is None:
        clock = now_epoch
    if sleeper is None:
        sleeper = time.sleep
    if transport_factory is None:
        transport_factory = UrllibTransport
    try:
        report = run(args, transport_factory, clock, sleeper)
    except ImportFailure as exc:
        sys.stdout.write(
            json_dumps({"result": "failed", "error_code": exc.code}) + "\n"
        )
        return 2
    except Exception:
        sys.stdout.write(
            json_dumps({"result": "failed", "error_code": "E_INTERNAL"}) + "\n"
        )
        return 3
    sys.stdout.write(json_dumps(report) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
