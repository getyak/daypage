#!/usr/bin/env python3
"""Synthetic unit tests for scripts/shared_backend_import.py (issue #884).

Fully offline: a scripted fake transport stands in for the Supabase backend and
every clock, sleeper and transport is injected for determinism. No live network
access, no private data, no credentials. Fixture values are synthetic.

Manifest-hash assertions use goldens produced by an independent JavaScript run
of packages/contracts/manifest-hash.mjs (never by a mirrored Python algorithm).
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.parse

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import shared_backend_import as sbi  # noqa: E402


# --------------------------------------------------------------------------
# Synthetic constants (all fake)
# --------------------------------------------------------------------------

PROJECT_ID = "abcdefghijklmnopqrst"  # exactly 20 lowercase letters
ORIGIN = "https://%s.supabase.co" % PROJECT_ID
OWNER_ID = "11111111-1111-4111-8111-111111111111"
MEMO_TEXT = "22222222-2222-4222-8222-222222222222"
MEMO_MEDIA = "33333333-3333-4333-8333-333333333333"
MEMO_MOV = "55555555-5555-4555-8555-555555555555"
DEVICE_ID = "44444444-4444-4444-8444-444444444444"
OP_TEXT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OP_MEDIA = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
OP_MOV = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
EMAIL = "synthetic@example.com"
ACCESS_TOKEN_1 = "synthetic-access-token-1"
REFRESH_TOKEN = "synthetic-refresh-token"
NOW = 1800000000.0

# Independent JS goldens (computed with node from packages/contracts/
# manifest-hash.mjs; golden A is also the parent's published cross-check).
GOLDEN_A = "4835da590363b7da780166df9a1e46b09cf3bb4d65547b3d357ebb5056732066"
GOLDEN_B = "0fbfee31d7ce261ee327ebf0d44ef1ae4d00ab2684f93117ad8e6ab8892f1014"
GOLDEN_B_NULL = "1ce5000446cb9a17ae8d64e135e5a9a671cf749c376454d8e7e3365dbfa3a26f"
GOLDEN_C = "d9b607a69e7be61ad630a299e0dee8732d195aff56f7ecbac682c8b2585c7c49"


def b64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def make_jwt(sub=OWNER_ID, iss=ORIGIN + "/auth/v1", role="authenticated", exp=NOW + 3600):
    header = {"alg": "HS256", "typ": "JWT"}
    claims = {"iss": iss, "sub": sub, "role": role, "exp": exp}
    return "%s.%s.%s" % (
        b64url(json.dumps(header).encode("utf-8")),
        b64url(json.dumps(claims).encode("utf-8")),
        b64url(b"synthetic-signature"),
    )


def iso(epoch):
    from datetime import datetime, timezone

    return (
        datetime.fromtimestamp(epoch, tz=timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


class Clock:
    """Deterministic injected clock/sleeper."""

    def __init__(self, now=NOW):
        self.now = now
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pattern_bytes(seed, size):
    block = ("daypage-synthetic-%s|" % seed).encode("utf-8")
    return (block * (size // len(block) + 1))[:size]


# --------------------------------------------------------------------------
# Workspace: private inputs, vault, export, tags, preflight
# --------------------------------------------------------------------------


class Workspace:
    def __init__(self, root):
        self.root = root
        self.vault = os.path.join(root, "vault")
        self.raw = os.path.join(self.vault, "raw")
        self.assets = os.path.join(self.raw, "assets")
        os.makedirs(self.assets)

        self.png_bytes = pattern_bytes("png", 64)
        self.aac_bytes = pattern_bytes("aac", 6 * 1024 * 1024 + 1)  # TUS path
        self.mov_bytes = pattern_bytes("mov", 128)
        self.files = {
            "assets/photo.png": self.png_bytes,
            "assets/voice.aac": self.aac_bytes,
            "assets/clip.mov": self.mov_bytes,
        }
        for relative, data in self.files.items():
            path = os.path.join(self.raw, relative.replace("/", os.sep))
            with open(path, "wb") as handle:
                handle.write(data)

        self.body_text = "synthetic text memo, comma/slash kept #tag,ok"
        self.body_media = "synthetic media memo — 世界"
        self.body_mov = "synthetic mov memo"

        def descriptor(memo_id, position, kind, mime, ext, filename, data, **extra):
            record = {
                "position": position,
                "kind": kind,
                "content_sha256": sha(data),
                "size_bytes": len(data),
                "mime_type": mime,
                "object_key": "%s/%s/%s.%s" % (OWNER_ID.lower(), memo_id.lower(), sha(data), ext),
                "original_filename": filename,
            }
            record.update(extra)
            return record

        self.png_desc = descriptor(
            MEMO_MEDIA, 0, "photo", "image/png", "png", "photo.png", self.png_bytes
        )
        self.aac_desc = descriptor(
            MEMO_MEDIA,
            1,
            "audio",
            "audio/aac",
            "aac",
            "voice.aac",
            self.aac_bytes,
            duration_ms=9000,
            transcript="synthetic transcript, with comma",
            transcription_status="done",
        )
        self.mov_desc = descriptor(
            MEMO_MOV, 0, "file", "video/quicktime", "mov", "clip.mov", self.mov_bytes
        )

        self.records = [
            self._record(
                OP_TEXT,
                MEMO_TEXT,
                self.body_text,
                "text",
                [],
                [],
                "2026-01-02T03:04:05Z",
            ),
            self._record(
                OP_MEDIA,
                MEMO_MEDIA,
                self.body_media,
                "voice",
                [self.png_desc, self.aac_desc],
                ["assets/photo.png", "assets/voice.aac"],
                "2026-01-03T10:00:00.123+08:00",
            ),
            self._record(
                OP_MOV,
                MEMO_MOV,
                self.body_mov,
                "file",
                [self.mov_desc],
                ["assets/clip.mov"],
                "2026-01-04T23:59:59Z",
            ),
        ]
        self.export_doc = {
            "version": 1,
            "format": "daypage-private-import-operations",
            "project_id": PROJECT_ID,
            "user_id": OWNER_ID,
            "source_zip_sha256": sha(b"synthetic-source-zip"),
            "records": self.records,
        }
        self.tag_doc = {
            "version": 1,
            "catalog": ["#标签/one", "#a,b", "#unused", "#Synthetic-Case"],
            "memos": [
                {"memo_id": MEMO_TEXT, "tags": ["#标签/one", "#a,b", "#a,b"]},
                {"memo_id": MEMO_MEDIA, "tags": ["#Synthetic-Case"]},
                {"memo_id": MEMO_MOV, "tags": []},
            ],
        }

        self.config_path = self._write(
            "config.json",
            {
                "project_id": PROJECT_ID,
                "url": ORIGIN,
                "publishable_key": "sb_publishable_synthetic_fixture_key",
            },
            private=True,
        )
        self.owner_path = self._write(
            "owner.json",
            {
                "project_id": PROJECT_ID,
                "user_id": OWNER_ID,
                "email": EMAIL,
                "email_confirmed": True,
                "profile_matches_auth": True,
            },
            private=True,
        )
        self.access_token = make_jwt()
        self.session_path = self._write(
            "session.json",
            {
                "access_token": self.access_token,
                "refresh_token": REFRESH_TOKEN,
                "user": {
                    "id": OWNER_ID,
                    "email": EMAIL,
                    "email_confirmed": True,
                    "aud": "authenticated",
                },
                "expires_at": NOW + 3600,
                "expires_in": 3600,
                "token_type": "bearer",
                "weak_password": None,
            },
            private=True,
        )
        self.operations_path = self._write(
            "operations.json", self.export_doc
        )
        self.export_sha256 = sha(self._raw("operations.json"))
        self.tags_path = self._write("tags.json", self.tag_doc)
        self.tag_payload_sha256 = sha(self._raw("tags.json"))

        attachment_bytes = sum(
            desc["size_bytes"]
            for record in self.records
            for desc in record["operation"]["payload"]["attachments"]
        )
        self.preflight_path = self._write(
            "preflight.json",
            {
                "result": "passed",
                "export_sha256": self.export_sha256,
                "memos": 3,
                "attachments": 3,
                "attachment_bytes": attachment_bytes,
                "native_and_javascript_manifest_hashes_agree": True,
                "all_operations_conform_to_current_v2_schema": True,
                # frozen independent-receipt metadata must be tolerated
                "mime_counts": {"image/png": 1, "audio/aac": 1, "video/quicktime": 1},
                "network_requests": 0,
                "user_content_logged": False,
                "synthetic_fixture": True,
                "provenance": "synthetic-unit-test",
            },
        )
        self.checkpoint_path = os.path.join(root, "checkpoint.json")
        self.receipt_path = os.path.join(root, "receipt.json")

    def _record(self, operation_id, memo_id, body, ptype, descs, local_files, created_at):
        payload = {
            "type": ptype,
            "body": body,
            "created_at": created_at,
            "source": "ios",
            "vault_path": "raw/2026-01-02.md",
            "attachments": descs,
        }
        operation = {
            "protocol_version": 2,
            "operation_id": operation_id,
            "memo_id": memo_id,
            "kind": "upsert",
            "revision": 1,
            "modified_at": created_at,
            "content_hash": sha(("content:" + memo_id).encode("utf-8")),
            "attachment_manifest_hash": sbi.attachment_manifest_hash(descs),
            "device_id": DEVICE_ID,
            "payload": payload,
            "size_bytes": len(body.encode("utf-8")),
        }
        return {
            "operation": operation,
            "local_files": local_files,
            "body_sha256": sha(body.encode("utf-8")),
        }

    def _raw(self, name):
        with open(os.path.join(self.root, name), "rb") as handle:
            return handle.read()

    def _write(self, name, doc, private=False):
        path = os.path.join(self.root, name)
        data = (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600 if private else 0o644)
        os.write(fd, data)
        os.close(fd)
        return path

    def argv(self, execute=False):
        argv = [
            "--config", self.config_path,
            "--owner", self.owner_path,
            "--session", self.session_path,
            "--operations", self.operations_path,
            "--preflight-receipt", self.preflight_path,
            "--vault", self.vault,
            "--tags", self.tags_path,
            "--checkpoint", self.checkpoint_path,
            "--receipt", self.receipt_path,
        ]
        if execute:
            argv.append("--execute")
        return argv


# --------------------------------------------------------------------------
# Fake backend + fake transport with fault-injection hooks
# --------------------------------------------------------------------------


def json_response(status, doc):
    return sbi.Response(status, {"content-type": "application/json"}, json.dumps(doc).encode("utf-8"))


class FakeServer:
    """Scripted Supabase-shaped backend: auth, rest RPCs, storage, TUS."""

    def __init__(self, workspace):
        self.ws = workspace
        self.objects = {}
        self.tus_sessions = {}
        self.reservations = []
        self.memos = {}
        self.applied = {}
        self.next_sequence = 1
        self.tags_payload = None
        self.tags_receipt = None
        self.snapshot = None
        self.auth_calls = 0
        self.refresh_calls = 0
        self.user = {
            "id": OWNER_ID,
            "email": EMAIL,
            "email_confirmed": True,
            "email_confirmed_at": "2026-01-01T00:00:00Z",
        }
        self.refresh_ok = True
        self.refresh_exp = NOW + 7200
        self.refresh_user = None  # defaults to self.user in refresh packets
        self.force_401_once = False
        self.tus_create_location = None  # override for host-escape tests

    # -- helpers -----------------------------------------------------------
    def _metadata_key(self, headers):
        raw = headers.get("upload-metadata") or ""
        for part in raw.split(","):
            pieces = part.strip().split(" ", 1)
            if len(pieces) == 2 and pieces[0] == "objectName":
                return base64.b64decode(pieces[1]).decode("utf-8")
        return None

    # -- dispatch ----------------------------------------------------------
    def handle(self, method, url, headers, body):
        parts = urllib.parse.urlsplit(url)
        path = parts.path
        lowered_headers = {str(k).lower(): v for k, v in (headers or {}).items()}
        ctype = lowered_headers.get("content-type")
        json_rpc_paths = (
            "/rest/v1/rpc/daypage_prepare_attachment_upload",
            "/rest/v1/rpc/daypage_apply_sync_operations_v2",
            "/rest/v1/rpc/daypage_import_tags_v1",
            "/rest/v1/rpc/daypage_pull_sync_changes_v2",
        )
        if path in json_rpc_paths or (method == "POST" and path == "/auth/v1/token"):
            # The fake refuses form-encoded JSON like the real PostgREST would.
            if ctype != "application/json":
                return json_response(400, {"message": "json content type required"})
            if self.force_401_once and path != "/auth/v1/token":
                self.force_401_once = False
                return json_response(401, {"message": "expired token"})
        if method == "GET" and path == "/auth/v1/user":
            self.auth_calls += 1
            return json_response(200, self.user)

        if method == "POST" and path == "/auth/v1/token":
            self.refresh_calls += 1
            if not self.refresh_ok:
                return json_response(200, {"access_token": make_jwt(sub="99999999-9999-4999-8999-999999999999"),
                                           "refresh_token": REFRESH_TOKEN})
            request = json.loads(body)
            if request.get("refresh_token") != REFRESH_TOKEN:
                return json_response(400, {"message": "invalid refresh"})
            new_token = make_jwt(exp=self.refresh_exp)
            return json_response(
                200,
                {
                    "access_token": new_token,
                    "refresh_token": REFRESH_TOKEN,
                    "user": self.refresh_user or self.user,
                    "expires_at": NOW + 7200,
                    "expires_in": 7200,
                    "token_type": "bearer",
                    "weak_password": None,
                },
            )

        if method == "POST" and path == "/rest/v1/rpc/daypage_prepare_attachment_upload":
            request = json.loads(body)
            key = "%s/%s/%s.%s" % (
                OWNER_ID.lower(),
                request["p_memo_id"].lower(),
                request["p_content_sha256"],
                request["p_extension"],
            )
            self.reservations.append(key)
            return json_response(
                200,
                {
                    "reservation_id": "99999999-9999-4999-8999-999999999999",
                    "object_key": key,
                    "expires_at": iso(NOW + 3600),
                    "already_exists": key in self.objects,
                },
            )

        if method == "POST" and path.startswith("/storage/v1/object/memo-attachments/"):
            key = path[len("/storage/v1/object/memo-attachments/"):]
            if ctype not in sbi.MIME_EXTENSIONS:
                return json_response(400, {"message": "binary content type required"})
            if key in self.objects:
                return json_response(400, {"message": "The resource already exists"})
            self.objects[key] = bytes(body)
            return json_response(200, {"Key": key})

        if method == "POST" and path.rstrip("/") == "/storage/v1/upload/resumable":
            key = self._metadata_key(lowered_headers)
            session_id = "88888888-8888-4888-8888-888888888888"
            self.tus_sessions[session_id] = {
                "key": key,
                "length": int(lowered_headers.get("upload-length")),
                "offset": 0,
                "data": bytearray(),
            }
            location = self.tus_create_location or (
                ORIGIN + "/storage/v1/upload/resumable/" + session_id
            )
            return sbi.Response(201, {"location": location, "upload-offset": "0"}, b"")

        if method == "HEAD" and path.startswith("/storage/v1/upload/resumable/"):
            session = self.tus_sessions.get(path.rsplit("/", 1)[-1])
            if session is None:
                return sbi.Response(404, {}, b"")
            return sbi.Response(
                200,
                {
                    "upload-offset": str(session["offset"]),
                    "upload-length": str(session["length"]),
                },
                b"",
            )

        if method == "PATCH" and path.startswith("/storage/v1/upload/resumable/"):
            if ctype != "application/offset+octet-stream":
                return sbi.Response(400, {}, b"")
            session = self.tus_sessions.get(path.rsplit("/", 1)[-1])
            if session is None:
                return sbi.Response(404, {}, b"")
            requested = int(lowered_headers.get("upload-offset"))
            if requested != session["offset"]:
                return sbi.Response(409, {}, b"")
            session["data"].extend(body)
            session["offset"] += len(body)
            if session["offset"] == session["length"]:
                self.objects[session["key"]] = bytes(session["data"])
            return sbi.Response(204, {"upload-offset": str(session["offset"])}, b"")

        if method == "GET" and path.startswith("/storage/v1/object/authenticated/memo-attachments/"):
            key = path[len("/storage/v1/object/authenticated/memo-attachments/"):]
            data = self.objects.get(key)
            if data is None:
                return sbi.Response(404, {}, b"")
            return sbi.Response(200, {"content-type": "application/octet-stream"}, data)

        if method == "POST" and path == "/rest/v1/rpc/daypage_apply_sync_operations_v2":
            operations = json.loads(body)["p_operations"]
            accepted = []
            for operation in operations:
                operation_key = operation["operation_id"].lower()
                if operation_key in self.applied:
                    accepted.append(self.applied[operation_key])
                    continue
                memo_key = operation["memo_id"].lower()
                current = self.memos.get(memo_key)
                if current is not None and current["sync_revision"] >= operation["revision"]:
                    accepted.append(
                        {
                            "operation_id": operation["operation_id"],
                            "memo_id": operation["memo_id"],
                            "revision": operation["revision"],
                            "remote_revision": current["sync_revision"],
                            "status": "stale",
                            "attachment_manifest_hash": operation["attachment_manifest_hash"],
                        }
                    )
                    continue
                sequence = self.next_sequence
                self.next_sequence += 1
                payload = operation["payload"]
                self.memos[memo_key] = {
                    "id": operation["memo_id"],
                    "type": payload["type"],
                    "body": payload["body"],
                    "created_at": payload["created_at"],
                    "pinned_at": payload.get("pinned_at"),
                    "location": payload.get("location"),
                    "weather": payload.get("weather"),
                    "device": payload.get("device"),
                    "source": payload["source"],
                    "vault_path": payload["vault_path"],
                    "source_modified_at": operation["modified_at"],
                    "content_hash": operation["content_hash"],
                    "sync_revision": operation["revision"],
                    "last_sync_device_id": operation["device_id"],
                    "deleted_at": None,
                    "change_sequence": sequence,
                    "attachment_manifest_hash": operation["attachment_manifest_hash"],
                    "attachments": payload["attachments"],
                }
                receipt = {
                    "operation_id": operation["operation_id"],
                    "memo_id": operation["memo_id"],
                    "revision": operation["revision"],
                    "remote_revision": operation["revision"],
                    "status": "applied",
                    "attachment_manifest_hash": operation["attachment_manifest_hash"],
                }
                self.applied[operation_key] = receipt
                accepted.append(receipt)
            return json_response(200, {"accepted": accepted, "rejected": []})

        if method == "POST" and path == "/rest/v1/rpc/daypage_pull_sync_changes_v2":
            request = json.loads(body)
            after = request["p_after_sequence"]
            limit = request["p_limit"]
            ordered = sorted(self.memos.values(), key=lambda item: item["change_sequence"])
            batch = [c for c in ordered if c["change_sequence"] > after][:limit]
            next_cursor = batch[-1]["change_sequence"] if batch else after
            has_more = any(c["change_sequence"] > next_cursor for c in ordered)
            return json_response(
                200,
                {"changes": batch, "next_cursor": next_cursor, "has_more": has_more},
            )

        if method == "POST" and path == "/rest/v1/rpc/daypage_import_tags_v1":
            request = json.loads(body)
            source = request["p_source_sha256"]
            payload = request["p_payload"]
            if self.tags_receipt is not None and self.tags_payload != payload:
                return json_response(409, {"message": "conflicting import"})
            catalog = payload["catalog"]
            union = set(catalog)
            memberships = set()
            for entry in payload["memos"]:
                for label in entry["tags"]:
                    union.add(label)
                    memberships.add((entry["memo_id"].lower(), label))
            result = {
                "version": 1,
                "source_sha256": source,
                "status": "imported" if self.tags_receipt is None else "replayed",
                "catalog_labels": len(catalog),
                "distinct_labels": len(union),
                "memos": len(payload["memos"]),
                "memberships": len(memberships),
            }
            self.tags_payload = payload
            self.tags_receipt = result
            self.snapshot = {
                "version": 1,
                "source_sha256": source,
                "payload_hash": sha(json.dumps(payload, sort_keys=True).encode("utf-8")),
                "payload": payload,
                "created_at": "2026-01-02T03:04:05.000000+00:00",
            }
            return json_response(200, result)

        if method == "GET" and path == "/rest/v1/memo_tag_imports":
            query = urllib.parse.parse_qs(parts.query)
            source = (query.get("source_sha256") or [""])[0]
            source = source[len("eq."):] if source.startswith("eq.") else source
            if self.snapshot is not None and self.snapshot["source_sha256"] == source:
                return json_response(200, [self.snapshot])
            return json_response(200, [])

        return json_response(404, {"message": "not found"})


class FakeTransport:
    def __init__(self, server):
        self.server = server
        self.hooks = []
        self.log = []

    def request(self, method, url, headers, body=None):
        self.log.append((method, urllib.parse.urlsplit(url).path))

        def call_next(m, u, h, b):
            return self.server.handle(m, u, h, b)

        chain = call_next
        for hook in reversed(self.hooks):
            chain = _bind(hook, chain)
        return chain(method, url, headers, body)


def _bind(hook, nxt):
    def run(method, url, headers, body):
        return hook(method, url, headers, body, nxt)

    return run


def match_path(substring, method=None):
    def predicate(m, u):
        return (method is None or m == method) and substring in urllib.parse.urlsplit(u).path

    return predicate


def hook_status(predicate, status, headers=None, body=b"", times=1):
    state = {"left": times}

    def hook(method, url, headers_, body_, call_next):
        if state["left"] > 0 and predicate(method, url):
            state["left"] -= 1
            return sbi.Response(status, headers or {}, body)
        return call_next(method, url, headers_, body_)

    return hook


def hook_raise(predicate, times=1, before=True):
    state = {"left": times}

    def hook(method, url, headers_, body_, call_next):
        if state["left"] > 0 and predicate(method, url):
            state["left"] -= 1
            if before:
                raise sbi.TransportError()
            response = call_next(method, url, headers_, body_)
            raise sbi.TransportError()
        return call_next(method, url, headers_, body_)

    return hook


def hook_transform(predicate, fn, times=1):
    state = {"left": times}

    def hook(method, url, headers_, body_, call_next):
        response = call_next(method, url, headers_, body_)
        if state["left"] > 0 and predicate(method, url):
            state["left"] -= 1
            return fn(response)
        return response

    return hook


def run_cli(ws, transport=None, execute=False, clock=None, forbid_network=False):
    if clock is None:
        clock = Clock()

    def factory():
        if forbid_network:
            raise AssertionError("network used during offline run")
        return transport

    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = sbi.main(
            ws.argv(execute=execute),
            transport_factory=factory,
            clock=clock,
            sleeper=clock.sleep,
        )
    lines = [line for line in out.getvalue().splitlines() if line.strip()]
    payload = json.loads(lines[-1]) if lines else None
    return code, payload, clock


def make_workspace(test):
    root = tempfile.mkdtemp(prefix="sbi-test-")
    test.addCleanup(shutil.rmtree, root, True)
    return Workspace(root)


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def read_json(path):
    return json.loads(read_bytes(path).decode("utf-8"))


# --------------------------------------------------------------------------
# Tests: manifest hash against independent JS goldens
# --------------------------------------------------------------------------


class ManifestHashGoldenTests(unittest.TestCase):
    def test_golden_single_non_ascii(self):
        attachment = {
            "position": 0,
            "kind": "photo",
            "content_sha256": "a" * 64,
            "size_bytes": 4,
            "mime_type": "image/png",
            "object_key": (
                "11111111-1111-4111-8111-111111111111/"
                "22222222-2222-4222-8222-222222222222/" + "a" * 64 + ".png"
            ),
            "original_filename": "测试.png",
        }
        self.assertEqual(sbi.attachment_manifest_hash([attachment]), GOLDEN_A)

    def test_golden_optional_fields_non_ascii(self):
        attachment = {
            "position": 3,
            "kind": "audio",
            "content_sha256": "b" * 64,
            "size_bytes": 52428801,
            "mime_type": "audio/aac",
            "object_key": (
                "11111111-1111-4111-8111-111111111111/"
                "22222222-2222-4222-8222-222222222222/" + "b" * 64 + ".aac"
            ),
            "original_filename": "vòice, part/2.m4a→.aac",
            "duration_ms": 1234,
            "transcript": "héllo, wörld — 世界",
            "transcription_status": "done",
        }
        self.assertEqual(sbi.attachment_manifest_hash([attachment]), GOLDEN_B)

    def test_golden_explicit_nulls(self):
        attachment = {
            "position": 3,
            "kind": "audio",
            "content_sha256": "b" * 64,
            "size_bytes": 52428801,
            "mime_type": "audio/aac",
            "object_key": (
                "11111111-1111-4111-8111-111111111111/"
                "22222222-2222-4222-8222-222222222222/" + "b" * 64 + ".aac"
            ),
            "original_filename": "vòice, part/2.m4a→.aac",
            "duration_ms": None,
            "transcript": None,
            "transcription_status": None,
        }
        self.assertEqual(sbi.attachment_manifest_hash([attachment]), GOLDEN_B_NULL)

    def test_golden_multiple_ordered_records(self):
        first = {
            "position": 0,
            "kind": "file",
            "content_sha256": "c" * 64,
            "size_bytes": 7,
            "mime_type": "video/quicktime",
            "object_key": (
                "11111111-1111-4111-8111-111111111111/"
                "22222222-2222-4222-8222-222222222222/" + "c" * 64 + ".mov"
            ),
            "original_filename": "a,b.mov",
        }
        second = {
            "position": 1,
            "kind": "audio",
            "content_sha256": "d" * 64,
            "size_bytes": 9,
            "mime_type": "audio/m4a",
            "object_key": (
                "11111111-1111-4111-8111-111111111111/"
                "22222222-2222-4222-8222-222222222222/" + "d" * 64 + ".m4a"
            ),
            "original_filename": "声.m4a",
            "duration_ms": 0,
            "transcript": "",
            "transcription_status": "pending",
        }
        self.assertEqual(sbi.attachment_manifest_hash([second, first]), GOLDEN_C)


# --------------------------------------------------------------------------
# Tests: offline dry-run (no network, no session refresh)
# --------------------------------------------------------------------------


class DryRunTests(unittest.TestCase):
    def test_native_vault_relative_files_dry_run_and_execute(self):
        for execute in (False, True):
            with self.subTest(execute=execute):
                ws = make_workspace(self)
                doc = read_json(ws.operations_path)
                for record in doc["records"]:
                    record["local_files"] = ["raw/" + name for name in record["local_files"]]
                ws._write("operations.json", doc)
                preflight = read_json(ws.preflight_path)
                preflight["export_sha256"] = sha(read_bytes(ws.operations_path))
                ws._write("preflight.json", preflight)
                server = FakeServer(ws)
                code, payload, _ = run_cli(
                    ws, transport=FakeTransport(server), execute=execute,
                    forbid_network=not execute,
                )
                self.assertEqual(code, 0, payload)
                self.assertEqual(payload["result"], "passed" if execute else "dry_run")
                self.assertEqual(payload["attachments"], 3)
                self.assertEqual(read_json(ws.operations_path), doc)

    def test_native_vault_prefix_does_not_allow_traversal_or_symlinks(self):
        for relative, error in (("raw/assets/../../clip.mov", "E_FILE_PATH"),
                                ("raw/linked.mov", "E_FILE_SYMLINK")):
            with self.subTest(relative=relative):
                ws = make_workspace(self)
                doc = read_json(ws.operations_path)
                doc["records"][2]["local_files"] = [relative]
                ws._write("operations.json", doc)
                os.symlink(os.path.join(ws.raw, "assets", "clip.mov"),
                           os.path.join(ws.raw, "linked.mov"))
                code, payload, _ = run_cli(ws, forbid_network=True)
                self.assertEqual(code, 2)
                self.assertEqual(payload, {"result": "failed", "error_code": error})

    def test_dry_run_success_touches_no_network(self):
        ws = make_workspace(self)
        code, payload, clock = run_cli(ws, forbid_network=True)
        self.assertEqual(code, 0)
        self.assertEqual(payload["result"], "dry_run")
        self.assertEqual(payload["memos"], 3)
        self.assertEqual(payload["attachments"], 3)
        self.assertEqual(
            payload["attachment_bytes"],
            len(ws.png_bytes) + len(ws.aac_bytes) + len(ws.mov_bytes),
        )
        self.assertEqual(payload["export_sha256"], ws.export_sha256)
        self.assertEqual(payload["tag_catalog_labels"], 4)
        self.assertEqual(payload["tag_distinct_labels"], 4)  # includes unused
        self.assertEqual(payload["tag_memberships"], 3)  # duplicate collapses
        self.assertEqual(clock.sleeps, [])
        self.assertFalse(os.path.exists(ws.checkpoint_path))
        receipt = read_json(ws.receipt_path)
        self.assertEqual(receipt["result"], "dry_run")

    def test_dry_run_report_carries_no_secrets(self):
        ws = make_workspace(self)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(code, 0)
        raw = read_bytes(ws.receipt_path).decode("utf-8")
        self.assertNotIn(ACCESS_TOKEN_1, raw)
        self.assertNotIn(REFRESH_TOKEN, raw)
        self.assertNotIn(OWNER_ID, raw)
        self.assertNotIn(EMAIL, raw)

    def test_dry_run_rejects_trailing_newline_hash(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["records"][0]["operation"]["content_hash"] += "\n"
        ws._write("operations.json", doc)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(code, 2)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OPERATION_SCHEMA"})


# --------------------------------------------------------------------------
# Tests: execute happy path with injected fake transport
# --------------------------------------------------------------------------


class ExecuteHappyPathTests(unittest.TestCase):
    def test_execute_happy_path(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport = FakeTransport(server)
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["result"], "passed")
        self.assertEqual(payload["imported_memos"], 3)
        self.assertEqual(payload["imported_attachments"], 3)
        self.assertEqual(payload["tag_status"], "imported")
        self.assertTrue(payload["readback_verified"])
        self.assertTrue(payload["media_reverified"])

        # all three objects live in the private bucket with exact bytes
        keys = set(server.objects)
        expected_keys = {
            ws.png_desc["object_key"],
            ws.aac_desc["object_key"],
            ws.mov_desc["object_key"],
        }
        self.assertEqual(keys, expected_keys)
        self.assertEqual(server.objects[ws.aac_desc["object_key"]], ws.aac_bytes)

        # AAC was TUS-uploaded in 6MiB chunks, MOV/PNG direct
        patch_calls = [m for m, _ in transport.log if m == "PATCH"]
        self.assertEqual(len(patch_calls), 2)
        self.assertIn(ws.aac_desc["object_key"], server.reservations)

        # every object GET-hashed before its memo commit, plus full final proof
        get_calls = [
            p for m, p in transport.log
            if m == "GET" and "/object/authenticated/memo-attachments/" in p
        ]
        self.assertEqual(len(get_calls), 6)

        # tags imported exactly once, snapshot payload byte-identical
        self.assertEqual(server.tags_payload, ws.tag_doc)
        self.assertEqual(server.tags_receipt["distinct_labels"], 4)

        # checkpoint and receipt hold aggregates only: no tokens, no email,
        # and the public receipt never carries the owner UUID
        checkpoint_raw = read_bytes(ws.checkpoint_path).decode("utf-8")
        receipt_raw = read_bytes(ws.receipt_path).decode("utf-8")
        for secret in (ACCESS_TOKEN_1, REFRESH_TOKEN, EMAIL):
            self.assertNotIn(secret, checkpoint_raw)
            self.assertNotIn(secret, receipt_raw)
        self.assertNotIn(OWNER_ID, receipt_raw)
        self.assertNotIn(EMAIL, receipt_raw)
        checkpoint = read_json(ws.checkpoint_path)
        self.assertTrue(checkpoint["readback_verified"])
        self.assertEqual(len(checkpoint["committed_operations"]), 3)
        self.assertEqual(len(checkpoint["uploads"]), 3)

    def test_execute_is_explicit_operator_action(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport = FakeTransport(server)
        # no --execute: pure dry-run even with a live-looking transport around
        code, payload, _ = run_cli(ws, transport=transport)
        self.assertEqual(code, 0)
        self.assertEqual(payload["result"], "dry_run")
        self.assertEqual(transport.log, [])
        self.assertEqual(server.objects, {})


# --------------------------------------------------------------------------
# Tests: identity, JWT and project binding
# --------------------------------------------------------------------------


class IdentityTests(unittest.TestCase):
    def _execute(self, ws, server=None):
        if server is None:
            server = FakeServer(ws)
        return run_cli(ws, transport=FakeTransport(server), execute=True)

    def test_same_user_wrong_project_owner(self):
        ws = make_workspace(self)
        ws._write(
            "owner.json",
            {
                "project_id": "zzzzzzzzzzzzzzzzzzzz",
                "user_id": OWNER_ID,
                "email": EMAIL,
                "email_confirmed": True,
                "profile_matches_auth": True,
            },
            private=True,
        )
        code, payload, _ = self._execute(ws)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OWNER_PROJECT"})

    def test_same_user_wrong_project_export(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["project_id"] = "zzzzzzzzzzzzzzzzzzzz"
        ws._write("operations.json", doc)
        code, payload, _ = self._execute(ws)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_EXPORT_PROJECT"})

    def test_jwt_sub_mismatch(self):
        ws = make_workspace(self)
        ws._write(
            "session.json",
            {
                "access_token": make_jwt(sub="99999999-9999-4999-8999-999999999999"),
                "refresh_token": REFRESH_TOKEN,
                "user": {"id": OWNER_ID, "email": EMAIL},
                "expires_at": NOW + 3600,
                "expires_in": 3600,
                "token_type": "bearer",
                "weak_password": None,
            },
            private=True,
        )
        code, payload, _ = self._execute(ws)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_JWT"})

    def test_jwt_issuer_mismatch(self):
        ws = make_workspace(self)
        ws._write(
            "session.json",
            {
                "access_token": make_jwt(iss="https://zzzzzzzzzzzzzzzzzzzz.supabase.co/auth/v1"),
                "refresh_token": REFRESH_TOKEN,
                "user": {"id": OWNER_ID, "email": EMAIL},
                "expires_at": NOW + 3600,
                "expires_in": 3600,
                "token_type": "bearer",
                "weak_password": None,
            },
            private=True,
        )
        code, payload, _ = self._execute(ws)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_JWT"})

    def test_server_user_id_mismatch(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.user = dict(server.user, id="99999999-9999-4999-8999-999999999999")
        code, payload, _ = self._execute(ws, server)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_IDENTITY"})

    def test_server_user_email_mismatch(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.user = dict(server.user, email="other@example.com")
        code, payload, _ = self._execute(ws, server)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_IDENTITY"})

    def test_server_email_unconfirmed(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.user = {
            "id": OWNER_ID,
            "email": EMAIL,
            "email_confirmed": False,
        }
        code, payload, _ = self._execute(ws, server)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_UNCONFIRMED"})

    def test_refresh_with_wrong_sub_aborts(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.refresh_ok = False
        transport = FakeTransport(server)
        transport.hooks.append(
            hook_status(match_path("daypage_prepare_attachment_upload"), 401, times=1)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_REFRESH"})

    def test_401_one_refresh_then_retry(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport = FakeTransport(server)
        transport.hooks.append(
            hook_status(match_path("daypage_prepare_attachment_upload"), 401, times=1)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["result"], "passed")
        self.assertEqual(server.refresh_calls, 1)
        self.assertGreaterEqual(server.auth_calls, 2)  # identity re-verified
        session = read_json(ws.session_path)
        self.assertNotEqual(session["access_token"], ACCESS_TOKEN_1)
        self.assertEqual(session["refresh_token"], REFRESH_TOKEN)
        self.assertEqual(session["token_type"], "bearer")

    def test_expired_token_refreshes_before_first_mutation(self):
        ws = make_workspace(self)
        ws._write(
            "session.json",
            {
                "access_token": make_jwt(exp=NOW - 100),
                "refresh_token": REFRESH_TOKEN,
                "user": {"id": OWNER_ID, "email": EMAIL},
                "expires_at": NOW - 100,
                "expires_in": 3600,
                "token_type": "bearer",
                "weak_password": None,
            },
            private=True,
        )
        server = FakeServer(ws)
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["result"], "passed")
        self.assertEqual(server.refresh_calls, 1)
        session = read_json(ws.session_path)
        self.assertNotEqual(session["access_token"], make_jwt(exp=NOW - 100))


# --------------------------------------------------------------------------
# Tests: tampered inputs fail closed
# --------------------------------------------------------------------------


class TamperTests(unittest.TestCase):
    def test_tampered_export_bytes_unbinds_preflight(self):
        ws = make_workspace(self)
        with open(ws.operations_path, "ab") as handle:
            handle.write(b" ")  # byte-level tamper, same JSON meaning
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PREFLIGHT_BIND"})

    def test_tampered_body_sha(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["records"][0]["body_sha256"] = sha(b"other")
        ws._write("operations.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_BODY_HASH"})

    def test_tampered_asset_bytes(self):
        ws = make_workspace(self)
        path = os.path.join(ws.raw, "assets", "clip.mov")
        tampered = b"XXXX" + ws.mov_bytes[4:]  # same length, different bytes
        with open(path, "wb") as handle:
            handle.write(tampered)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_FILE_HASH"})

    def test_missing_asset(self):
        ws = make_workspace(self)
        os.unlink(os.path.join(ws.raw, "assets", "photo.png"))
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_INPUT_MISSING"})

    def test_manifest_hash_mismatch(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["records"][1]["operation"]["attachment_manifest_hash"] = "0" * 64
        ws._write("operations.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_MANIFEST_HASH"})


# --------------------------------------------------------------------------
# Tests: path traversal, symlinks, output aliasing, checkpoint binding
# --------------------------------------------------------------------------


class FilesystemSafetyTests(unittest.TestCase):
    def test_traversal_relative_rejected(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["records"][2]["local_files"] = ["assets/../../clip.mov"]
        ws._write("operations.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_FILE_PATH"})

    def test_absolute_path_rejected(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["records"][2]["local_files"] = ["/etc/passwd"]
        ws._write("operations.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_FILE_PATH"})

    def test_symlink_asset_rejected(self):
        ws = make_workspace(self)
        target = os.path.join(ws.root, "outside.mov")
        with open(target, "wb") as handle:
            handle.write(ws.mov_bytes)
        link = os.path.join(ws.raw, "assets", "clip.mov")
        os.unlink(link)
        os.symlink(target, link)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_FILE_SYMLINK"})

    def test_fifo_asset_fails_fast_without_hanging(self):
        ws = make_workspace(self)
        path = os.path.join(ws.raw, "assets", "photo.png")
        os.unlink(path)
        os.mkfifo(path)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_INPUT_TYPE"})

    def test_receipt_cannot_alias_operations(self):
        ws = make_workspace(self)
        ws.receipt_path = ws.operations_path
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"})

    def test_session_cannot_alias_operations(self):
        ws = make_workspace(self)
        ws.session_path = ws.operations_path
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"})

    def test_checkpoint_cannot_alias_tags(self):
        ws = make_workspace(self)
        ws.checkpoint_path = ws.tags_path
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"})

    def test_symlinked_receipt_rejected_and_target_untouched(self):
        ws = make_workspace(self)
        victim = os.path.join(ws.root, "victim.txt")
        with open(victim, "wb") as handle:
            handle.write(b"victim-content")
        os.symlink(victim, ws.receipt_path)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"})
        with open(victim, "rb") as handle:
            self.assertEqual(handle.read(), b"victim-content")

    def test_preexisting_hardlink_temp_never_truncated(self):
        ws = make_workspace(self)
        victim = os.path.join(ws.root, "victim-secret.txt")
        with open(victim, "wb") as handle:
            handle.write(b"must-not-be-truncated")
        # regression: predictable temp names used by the old implementation
        os.link(victim, ws.receipt_path + ".tmp." + str(os.getpid()))
        os.link(victim, os.path.join(ws.root, ".receipt.json.tmp.deadbeef"))
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(code, 0, payload)
        with open(victim, "rb") as handle:
            self.assertEqual(handle.read(), b"must-not-be-truncated")

    def test_private_outputs_are_mode_0600_and_no_stray_temps(self):
        ws = make_workspace(self)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(code, 0, payload)
        for name in os.listdir(ws.root):
            if name.startswith(".receipt.json.tmp.") or ".tmp." in name:
                self.fail("stray temp file left behind: %r" % name)
        self.assertEqual(os.stat(ws.receipt_path).st_mode & 0o777, 0o600)

    def test_checkpoint_binding_mismatch_refused(self):
        ws = make_workspace(self)
        ws._write(
            "checkpoint.json",
            {
                "version": 1,
                "project_id": PROJECT_ID,
                "owner_user_id": OWNER_ID,
                "export_sha256": "0" * 64,
                "tag_payload_sha256": ws.tag_payload_sha256,
                "source_zip_sha256": sha(b"synthetic-source-zip"),
                "uploads": {},
                "tus": {},
                "committed_operations": {},
                "tags_state": None,
                "readback_verified": False,
            },
            private=True,
        )
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_CHECKPOINT_BIND"})


# --------------------------------------------------------------------------
# Tests: preflight receipt must be present, well-formed and current
# --------------------------------------------------------------------------


class PreflightReceiptTests(unittest.TestCase):
    def test_missing_preflight_receipt(self):
        ws = make_workspace(self)
        os.unlink(ws.preflight_path)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_INPUT_MISSING"})

    def test_malformed_preflight_receipt(self):
        ws = make_workspace(self)
        doc = read_json(ws.preflight_path)
        del doc["all_operations_conform_to_current_v2_schema"]
        ws._write("preflight.json", doc)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PREFLIGHT_SHAPE"})

    def test_stale_preflight_counts(self):
        ws = make_workspace(self)
        doc = read_json(ws.preflight_path)
        doc["memos"] = 2
        ws._write("preflight.json", doc)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PREFLIGHT_BIND"})

    def test_unpassed_preflight_result(self):
        ws = make_workspace(self)
        doc = read_json(ws.preflight_path)
        doc["result"] = "failed"
        ws._write("preflight.json", doc)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PREFLIGHT_SHAPE"})

    def test_no_success_without_preflight(self):
        ws = make_workspace(self)
        os.unlink(ws.preflight_path)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(payload["result"], "failed")
        self.assertFalse(os.path.exists(ws.receipt_path))
        self.assertEqual(FakeServer(ws).objects, {})


# --------------------------------------------------------------------------
# Helpers for JSON-level fault injection
# --------------------------------------------------------------------------


def hook_json_transform(predicate, fn, times=1):
    def transform(response):
        doc = json.loads(response.body.decode("utf-8"))
        return json_response(response.status, fn(doc))

    return hook_transform(predicate, transform, times)


def hook_block_after_first_patch():
    state = {"seen": 0}

    def hook(method, url, headers_, body_, call_next):
        if method == "PATCH" and "resumable" in urllib.parse.urlsplit(url).path:
            state["seen"] += 1
            if state["seen"] > 1:
                raise sbi.TransportError()
        return call_next(method, url, headers_, body_)

    return hook


# --------------------------------------------------------------------------
# Tests: bounded retries, 429 throttling
# --------------------------------------------------------------------------


class RetryTests(unittest.TestCase):
    def test_429_retry_after_honored_and_succeeds(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_status(
                match_path("daypage_prepare_attachment_upload"),
                429,
                headers={"retry-after": "2"},
                times=1,
            )
        )
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["result"], "passed")
        self.assertEqual(clock.sleeps[0], 2.0)

    def test_429_retry_after_is_bounded(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_status(
                match_path("daypage_prepare_attachment_upload"),
                429,
                headers={"retry-after": "9999"},
                times=1,
            )
        )
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(clock.sleeps[0], 60.0)  # clamped

    def test_transient_failures_never_loop_indefinitely(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_raise(match_path("daypage_apply_sync_operations_v2"), times=100)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_NETWORK"})
        self.assertLessEqual(len(transport.log), 10)  # bounded attempts

    def test_reservation_throttle_caps_new_reservations_per_minute(self):
        clock = Clock()
        throttle = sbi.ReservationThrottle(clock, clock.sleep)
        for _ in range(sbi.RESERVATIONS_PER_MINUTE):
            throttle.wait_for_slot()
        self.assertEqual(clock.sleeps, [])
        throttle.wait_for_slot()  # 56th reservation inside the minute
        self.assertTrue(clock.sleeps)
        self.assertLessEqual(clock.sleeps[0], 61.0)  # bounded pacing delay


# --------------------------------------------------------------------------
# Tests: TUS resume, ambiguous PATCH, offsets, host escapes
# --------------------------------------------------------------------------


class TusTests(unittest.TestCase):
    def test_ambiguous_patch_heads_before_retry(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport = FakeTransport(server)
        transport.hooks.append(
            hook_raise(match_path("resumable", "PATCH"), times=1, before=False)
        )
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(clock.sleeps, [])  # progress: no delay on a resend-less path
        resumable = [
            (m, p) for m, p in transport.log if "resumable" in p
        ]
        patch_indexes = [i for i, (m, _) in enumerate(resumable) if m == "PATCH"]
        self.assertEqual(len(patch_indexes), 2)  # chunk never re-sent blind
        first_patch = patch_indexes[0]
        self.assertEqual(resumable[first_patch + 1][0], "HEAD")
        self.assertEqual(server.objects[ws.aac_desc["object_key"]], ws.aac_bytes)

    def test_unexpected_patch_offset_aborts(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def bump(response):
            offset = int(response.header("upload-offset"))
            return sbi.Response(
                response.status, {"upload-offset": str(offset + 999)}, b""
            )

        transport.hooks.append(
            hook_transform(match_path("resumable", "PATCH"), bump, times=1)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TUS_OFFSET"})

    def test_tus_location_host_escape_rejected(self):
        for evil in (
            "https://evil.example/storage/v1/upload/resumable/x",
            "//evil.example/storage/v1/upload/resumable/x",
            ORIGIN + "/storage/v1/other/../upload/resumable/",
            ORIGIN + "/storage/v1/upload/resumable/x?token=1",
        ):
            with self.subTest(location=evil):
                ws = make_workspace(self)
                server = FakeServer(ws)
                server.tus_create_location = evil
                code, payload, _ = run_cli(
                    ws, transport=FakeTransport(server), execute=True
                )
                self.assertEqual(
                    payload, {"result": "failed", "error_code": "E_TUS_LOCATION"}
                )

    def test_saved_tus_url_host_escape_rejected(self):
        ws = make_workspace(self)
        ws._write(
            "checkpoint.json",
            {
                "version": 1,
                "project_id": PROJECT_ID,
                "owner_user_id": OWNER_ID,
                "export_sha256": ws.export_sha256,
                "tag_payload_sha256": ws.tag_payload_sha256,
                "source_zip_sha256": sha(b"synthetic-source-zip"),
                "uploads": {},
                "tus": {
                    ws.aac_desc["object_key"]: {
                        "url": "https://evil.example/storage/v1/upload/resumable/x",
                        "offset": 0,
                    }
                },
                "committed_operations": {},
                "tags_state": None,
                "readback_verified": False,
            },
            private=True,
        )
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TUS_LOCATION"})

    def test_tus_resumes_after_interruption_without_duplicates(self):
        ws = make_workspace(self)
        server = FakeServer(ws)

        transport1 = FakeTransport(server)
        transport1.hooks.append(hook_block_after_first_patch())
        code1, payload1, _ = run_cli(ws, transport=transport1, execute=True)
        self.assertEqual(payload1, {"result": "failed", "error_code": "E_NETWORK"})
        checkpoint = read_json(ws.checkpoint_path)
        tus = checkpoint["tus"][ws.aac_desc["object_key"]]
        self.assertEqual(tus["offset"], 6 * 1024 * 1024)
        self.assertTrue(tus["url"].startswith(ORIGIN + "/storage/v1/upload/resumable/"))

        transport2 = FakeTransport(server)
        code2, payload2, _ = run_cli(ws, transport=transport2, execute=True)
        self.assertEqual(code2, 0, payload2)
        self.assertEqual(payload2["result"], "passed")
        self.assertEqual(server.objects[ws.aac_desc["object_key"]], ws.aac_bytes)
        self.assertEqual(len(server.tus_sessions), 1)  # resumed, not re-created
        self.assertEqual(read_json(ws.checkpoint_path)["tus"], {})


# --------------------------------------------------------------------------
# Tests: complete readback, pull progression, media hash proof
# --------------------------------------------------------------------------


class ReadbackTests(unittest.TestCase):
    def test_pull_duplicate_change_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def duplicate(doc):
            doc["changes"].append(dict(doc["changes"][0]))
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), duplicate)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_SHAPE"})

    def test_pull_cursor_regression_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def regress(doc):
            doc["next_cursor"] = 0
            doc["has_more"] = True
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), regress)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_PROGRESSION"})

    def test_pull_body_mismatch_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def tamper(doc):
            for change in doc["changes"]:
                if change["id"].lower() == MEMO_TEXT:
                    change["body"] = "tampered body"
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), tamper)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_MISMATCH"})

    def test_tombstoned_imported_memo_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def tombstone(doc):
            for change in doc["changes"]:
                if change["id"].lower() == MEMO_TEXT:
                    change["deleted_at"] = "2026-02-01T00:00:00Z"
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), tombstone)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_MISMATCH"})

    def test_final_media_hash_mismatch_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        state = {"gets": 0}
        key = ws.mov_desc["object_key"]

        def corrupt_final_get_only(method, url, headers_, body_, call_next):
            response = call_next(method, url, headers_, body_)
            if method == "GET" and key in urllib.parse.urlsplit(url).path:
                state["gets"] += 1
                if state["gets"] == 2:  # first GET is the precommit proof
                    return sbi.Response(200, response.headers, b"corrupted-final")
            return response

        transport.hooks.append(corrupt_final_get_only)
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_MEDIA_HASH"})
        # the precommit proof passed, so the memo committed; the independent
        # final GET still failed the run and no passed receipt was written
        self.assertIn(MEMO_MOV, transport.server.memos)
        self.assertFalse(os.path.exists(ws.receipt_path))

    def test_additional_owner_memos_coexist(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.next_sequence = 2
        server.memos["66666666-6666-4666-8666-666666666666"] = {
            "id": "66666666-6666-4666-8666-666666666666",
            "type": "text",
            "body": "pre-existing owner memo",
            "created_at": "2025-12-31T00:00:00Z",
            "content_hash": sha(b"pre-existing"),
            "sync_revision": 1,
            "attachment_manifest_hash": None,
            "deleted_at": None,
            "change_sequence": 1,
            "attachments": [],
        }
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code, 0, payload)
        self.assertIn("66666666-6666-4666-8666-666666666666", server.memos)
        self.assertEqual(len(server.memos), 4)


# --------------------------------------------------------------------------
# Tests: tag fidelity and exact tag receipts
# --------------------------------------------------------------------------


class TagFidelityTests(unittest.TestCase):
    def test_unused_comma_unicode_labels_survive_exactly(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(server.tags_payload, ws.tag_doc)  # exact round trip
        self.assertIn("#unused", server.tags_payload["catalog"])  # unused kept
        self.assertIn("#标签/one", server.tags_payload["catalog"])
        self.assertIn("#a,b", server.tags_payload["catalog"])  # comma not split
        text_tags = server.tags_payload["memos"][0]["tags"]
        self.assertEqual(text_tags, ["#标签/one", "#a,b", "#a,b"])  # not deduped
        self.assertEqual(payload["tag_status"], "imported")
        self.assertEqual(payload["tag_catalog_labels"], 4)
        self.assertEqual(payload["tag_distinct_labels"], 4)  # unused included
        self.assertEqual(payload["tag_memberships"], 3)  # distinct links

    def test_tag_result_count_mismatch_aborts(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def bump(doc):
            doc["distinct_labels"] += 1
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_import_tags_v1"), bump)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TAG_RECEIPT"})

    def test_tag_snapshot_payload_mismatch_aborts(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def tamper(doc):
            doc[0]["payload"] = dict(doc[0]["payload"], catalog=["#other"])
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("memo_tag_imports"), tamper)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TAG_SNAPSHOT"})

    def test_label_with_trailing_newline_rejected(self):
        ws = make_workspace(self)
        doc = read_json(ws.tags_path)
        doc["catalog"][0] = "#synthetic\n"
        ws._write("tags.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TAG_LABEL"})

    def test_tag_memo_set_mismatch_rejected(self):
        ws = make_workspace(self)
        doc = read_json(ws.tags_path)
        doc["memos"] = doc["memos"][:2]
        ws._write("tags.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TAG_MEMO_SET"})

    def test_duplicate_catalog_entry_rejected(self):
        ws = make_workspace(self)
        doc = read_json(ws.tags_path)
        doc["catalog"].append(doc["catalog"][0])
        ws._write("tags.json", doc)
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TAG_SCHEMA"})


# --------------------------------------------------------------------------
# Tests: idempotent retries and reverified receipts
# --------------------------------------------------------------------------


class IdempotencyTests(unittest.TestCase):
    def test_execute_rerun_does_not_duplicate(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        code1, payload1, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code1, 0, payload1)
        object_keys_after_first = set(server.objects)
        transport2 = FakeTransport(server)
        code2, payload2, _ = run_cli(ws, transport=transport2, execute=True)
        self.assertEqual(code2, 0, payload2)
        self.assertEqual(payload2["result"], "passed")
        self.assertEqual(payload2["tag_status"], "replayed")
        self.assertEqual(len(server.memos), 3)
        self.assertEqual(set(server.objects), object_keys_after_first)
        self.assertEqual(server.tags_receipt["status"], "replayed")
        # reservations are re-prepared on resume (live reservation proof) but
        # are idempotent for the same immutable keys; nothing is re-uploaded
        self.assertEqual(len(server.reservations), 6)
        self.assertEqual(server.reservations[3:], server.reservations[:3])
        rerun_mutations = [
            (m, p) for m, p in transport2.log
            if m == "PATCH"
            or (m == "POST" and p.startswith("/storage/v1/object/memo-attachments/"))
        ]
        self.assertEqual(rerun_mutations, [])

    def test_rerun_without_checkpoint_is_server_idempotent(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        code1, payload1, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code1, 0, payload1)
        os.unlink(ws.checkpoint_path)
        code2, payload2, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code2, 0, payload2)
        self.assertEqual(len(server.memos), 3)  # same operation IDs applied once
        self.assertEqual(len(server.objects), 3)

    def test_failed_rerun_never_overwrites_completed_receipt(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        code1, payload1, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code1, 0, payload1)
        completed = read_bytes(ws.receipt_path)
        # corrupt remote bytes (same size): precommit proof must fail, and the
        # completed receipt must remain untouched
        server.objects[ws.mov_desc["object_key"]] = b"X" * len(ws.mov_bytes)
        code2, payload2, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(payload2, {"result": "failed", "error_code": "E_MEDIA_HASH"})
        self.assertEqual(read_bytes(ws.receipt_path), completed)

    def test_rerun_recovers_missing_object_without_duplicates(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        code1, payload1, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code1, 0, payload1)
        del server.objects[ws.mov_desc["object_key"]]  # supported recovery path
        code2, payload2, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code2, 0, payload2)
        self.assertEqual(payload2["result"], "passed")
        self.assertEqual(len(server.memos), 3)  # nothing duplicated
        self.assertEqual(server.objects[ws.mov_desc["object_key"]], ws.mov_bytes)

    def test_unrelated_completed_receipt_never_clobbered(self):
        ws = make_workspace(self)
        ws._write(
            "receipt.json",
            {"result": "passed", "export_sha256": "0" * 64},
        )
        code, payload, _ = run_cli(ws, transport=FakeTransport(FakeServer(ws)), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_RECEIPT_CONFLICT"})


# --------------------------------------------------------------------------
# Helpers for real-urllib request capture (CORE-P1-02 closure evidence)
# --------------------------------------------------------------------------


class FakeHTTPResponse:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = dict(headers)
        self._body = body

    def read(self, n=-1):
        if n is None or n < 0:
            return self._body
        return self._body[:n]

    def getcode(self):
        return self.status


class CapturingOpener:
    """Applies real urllib request preprocessing (including the default
    Content-Type selection), captures the request, then delegates to the
    fake server."""

    def __init__(self, server):
        self.server = server
        self.captured = []

    def open(self, request, timeout=None):
        handler = urllib.request.AbstractHTTPHandler()
        director = urllib.request.OpenerDirector()
        director.addheaders = []
        handler.add_parent(director)
        handler.do_request_(request)
        self.captured.append(request)
        response = self.server.handle(
            request.get_method(),
            request.full_url,
            dict(request.header_items()),
            request.data,
        )
        return FakeHTTPResponse(response.status, response.headers, response.body)


# --------------------------------------------------------------------------
# Tests: mutable outputs must never touch the Vault or validated assets
# --------------------------------------------------------------------------


class OutputSafetyTests(unittest.TestCase):
    def _asset(self, ws):
        return os.path.join(ws.raw, "assets", "photo.png")

    def test_dry_run_receipt_equals_asset_rejected(self):
        ws = make_workspace(self)
        asset = self._asset(ws)
        before = read_bytes(asset)
        ws.receipt_path = asset
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(
            payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"}
        )
        self.assertEqual(read_bytes(asset), before)  # asset untouched
        self.assertFalse(os.path.exists(ws.checkpoint_path + ".lock"))

    def test_outputs_nested_inside_vault_rejected(self):
        for field in ("receipt_path", "checkpoint_path", "session_path"):
            with self.subTest(field=field):
                ws = make_workspace(self)
                target = os.path.join(ws.vault, "nested", "out.json")
                if field == "session_path":
                    # an actual session file living inside the Vault must be
                    # refused as an output destination before any refresh
                    os.makedirs(os.path.dirname(target))
                    shutil.copy(ws.session_path, target)
                    os.chmod(target, 0o600)
                setattr(ws, field, target)
                transport = FakeTransport(FakeServer(ws))
                code, payload, _ = run_cli(ws, transport=transport, execute=True)
                self.assertEqual(
                    payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"}
                )
                self.assertEqual(transport.log, [])  # before any network

    def test_checkpoint_and_lock_inside_vault_rejected_before_mutation(self):
        ws = make_workspace(self)
        ws.checkpoint_path = os.path.join(ws.raw, "assets", "checkpoint.json")
        transport = FakeTransport(FakeServer(ws))
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(
            payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"}
        )
        self.assertEqual(transport.log, [])
        self.assertFalse(os.path.exists(ws.checkpoint_path))
        self.assertFalse(os.path.exists(ws.checkpoint_path + ".lock"))

    def test_hardlink_alias_to_asset_rejected(self):
        ws = make_workspace(self)
        asset = self._asset(ws)
        before = read_bytes(asset)
        link = os.path.join(ws.root, "receipt-alias.json")
        os.link(asset, link)
        ws.receipt_path = link
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(
            payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"}
        )
        self.assertEqual(read_bytes(asset), before)

    def test_normal_private_outputs_outside_vault_accepted(self):
        ws = make_workspace(self)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(code, 0, payload)
        self.assertTrue(os.path.exists(ws.receipt_path))
        self.assertEqual(read_json(ws.receipt_path)["result"], "dry_run")

    def test_symlink_parent_dotdot_cannot_replace_raw_markdown(self):
        ws = make_workspace(self)
        nested = os.path.join(ws.vault, "nested")
        os.makedirs(nested)
        outside = os.path.join(ws.root, "outside")
        os.makedirs(outside)
        alias = os.path.join(outside, "alias")
        os.symlink(nested, alias)
        raw_memo = os.path.join(ws.raw, "2026-01-02.md")
        original = b"untouched raw memo\n"
        with open(raw_memo, "wb") as stream:
            stream.write(original)
        ws.receipt_path = os.path.join(alias, "..", "raw", "2026-01-02.md")
        self.assertEqual(os.path.realpath(ws.receipt_path), os.path.realpath(raw_memo))
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"})
        self.assertEqual(read_bytes(raw_memo), original)
        self.assertFalse(os.path.exists(ws.checkpoint_path + ".lock"))

    def test_lock_cannot_share_an_input_or_receipt_role(self):
        for field in ("config_path", "owner_path", "session_path", "operations_path",
                      "preflight_path", "tags_path", "receipt_path"):
            with self.subTest(field=field):
                ws = make_workspace(self)
                lock = ws.checkpoint_path + ".lock"
                source = getattr(ws, field)
                original = read_bytes(source) if os.path.exists(source) else None
                if original is not None:
                    with open(lock, "wb") as stream:
                        stream.write(original)
                    os.chmod(lock, 0o600)
                setattr(ws, field, lock)
                code, payload, _ = run_cli(ws, forbid_network=True)
                self.assertEqual(payload, {"result": "failed", "error_code": "E_OUTPUT_ALIAS"})
                self.assertFalse(os.path.exists(ws.checkpoint_path))
                if original is None:
                    self.assertFalse(os.path.exists(lock))
                else:
                    self.assertEqual(read_bytes(lock), original)


# --------------------------------------------------------------------------
# Tests: JSON RPC requests carry application/json through real urllib
# --------------------------------------------------------------------------


class JsonContentTypeTests(unittest.TestCase):
    def test_all_json_rpcs_send_application_json_via_real_urllib(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.force_401_once = True  # also capture the refresh packet
        transport = sbi.UrllibTransport()
        opener = CapturingOpener(server)
        transport.opener = opener
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        rpc_shapes = {
            "/rest/v1/rpc/daypage_prepare_attachment_upload": {
                "p_memo_id",
                "p_content_sha256",
                "p_size_bytes",
                "p_mime_type",
                "p_extension",
            },
            "/rest/v1/rpc/daypage_apply_sync_operations_v2": {"p_operations"},
            "/rest/v1/rpc/daypage_import_tags_v1": {
                "p_source_sha256",
                "p_payload",
            },
            "/rest/v1/rpc/daypage_pull_sync_changes_v2": {
                "p_after_sequence",
                "p_limit",
            },
            "/auth/v1/token": {"refresh_token"},
        }
        seen = set()
        patch_ctype = set()
        for request in opener.captured:
            path = urllib.parse.urlsplit(request.full_url).path
            ctype = request.get_header("Content-type")
            if path in rpc_shapes:
                seen.add(path)
                self.assertEqual(ctype, "application/json", path)
                body = json.loads(request.data.decode("utf-8"))
                self.assertEqual(set(body), rpc_shapes[path])
            elif path.startswith("/storage/v1/object/memo-attachments/"):
                self.assertIn(ctype, sbi.MIME_EXTENSIONS)  # binary preserved
            elif request.get_method() == "PATCH":
                patch_ctype.add(ctype)
        self.assertEqual(seen, set(rpc_shapes))
        self.assertEqual(patch_ctype, {"application/offset+octet-stream"})

    def test_form_encoded_json_is_refused_by_endpoint(self):
        # Guard against regressions: the fake endpoint rejects missing or
        # wrong JSON Content-Type just like PostgREST would.
        ws = make_workspace(self)
        server = FakeServer(ws)
        response = server.handle(
            "POST",
            ORIGIN + "/rest/v1/rpc/daypage_pull_sync_changes_v2",
            {"Content-Type": "application/x-www-form-urlencoded"},
            b'{"p_after_sequence":0,"p_limit":200}',
        )
        self.assertEqual(response.status, 400)


# --------------------------------------------------------------------------
# Tests: mandatory private byte proof before every media memo commit
# --------------------------------------------------------------------------


class PrecommitProofTests(unittest.TestCase):
    def _seed_verified_checkpoint(self, ws, descriptors):
        ws._write(
            "checkpoint.json",
            {
                "version": 1,
                "project_id": PROJECT_ID,
                "owner_user_id": OWNER_ID,
                "export_sha256": ws.export_sha256,
                "tag_payload_sha256": ws.tag_payload_sha256,
                "source_zip_sha256": sha(b"synthetic-source-zip"),
                "uploads": {
                    desc["object_key"]: {
                        "sha256": desc["content_sha256"],
                        "size_bytes": desc["size_bytes"],
                        "state": "verified",
                    }
                    for desc in descriptors
                },
                "tus": {},
                "committed_operations": {},
                "tags_state": None,
                "readback_verified": False,
            },
            private=True,
        )

    def test_get_proof_precedes_every_media_commit(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        events = []
        for method, path in transport.log:
            if method == "POST" and path.endswith(
                "/rest/v1/rpc/daypage_apply_sync_operations_v2"
            ):
                events.append(("commit", None))
            elif method == "GET" and "/object/authenticated/memo-attachments/" in path:
                events.append(
                    ("get", path.split("/object/authenticated/memo-attachments/")[1])
                )
        png = ws.png_desc["object_key"]
        aac = ws.aac_desc["object_key"]
        mov = ws.mov_desc["object_key"]
        expected = [
            ("commit", None),  # text-only batch
            ("get", png),
            ("get", aac),
            ("commit", None),  # media memo commits only after both proofs
            ("get", mov),
            ("commit", None),
            ("get", png),
            ("get", aac),
            ("get", mov),  # complete final independent proof
        ]
        self.assertEqual(events, expected)

    def test_checkpoint_verified_entry_reproven_before_commit(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        self._seed_verified_checkpoint(ws, [ws.png_desc, ws.aac_desc, ws.mov_desc])
        server.objects[ws.png_desc["object_key"]] = ws.png_bytes
        server.objects[ws.aac_desc["object_key"]] = ws.aac_bytes
        server.objects[ws.mov_desc["object_key"]] = b"Y" * len(ws.mov_bytes)
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_MEDIA_HASH"})
        self.assertNotIn(MEMO_MOV, server.memos)  # never committed unproven
        self.assertIn(MEMO_MEDIA, server.memos)  # its own proofs passed first

    def test_same_size_local_mutation_aborts_before_commit(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport = FakeTransport(server)
        mov_path = os.path.join(ws.raw, "assets", "clip.mov")

        def mutate_after_first_commit(method, url, headers_, body_, call_next):
            response = call_next(method, url, headers_, body_)
            if method == "POST" and url.endswith(
                "/rest/v1/rpc/daypage_apply_sync_operations_v2"
            ):
                with open(mov_path, "wb") as handle:
                    handle.write(b"Z" * len(ws.mov_bytes))  # same size, new bytes
            return response

        transport.hooks.append(mutate_after_first_commit)
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_MEDIA_HASH"})
        self.assertNotIn(MEMO_MOV, server.memos)

    def test_existing_corrupt_object_requires_byte_proof(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.objects[ws.png_desc["object_key"]] = b"X" * len(ws.png_bytes)
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_MEDIA_HASH"})
        self.assertNotIn(MEMO_MEDIA, server.memos)


# --------------------------------------------------------------------------
# Tests: malformed/missing/stale/duplicate/extra commit acknowledgements
# --------------------------------------------------------------------------


class CommitReceiptTests(unittest.TestCase):
    def _run_with_receipt_change(self, ws, fn):
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_json_transform(
                match_path("daypage_apply_sync_operations_v2"), fn, times=1
            )
        )
        return run_cli(ws, transport=transport, execute=True)

    def test_malformed_acknowledgement_rejected(self):
        ws = make_workspace(self)

        def malformed(doc):
            del doc["accepted"][0]["status"]
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, malformed)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_RECEIPT"})

    def test_missing_acknowledgement_rejected(self):
        ws = make_workspace(self)

        def missing(doc):
            doc["accepted"] = []
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, missing)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_RECEIPT"})

    def test_stale_acknowledgement_rejected(self):
        ws = make_workspace(self)

        def stale(doc):
            doc["accepted"][0]["status"] = "stale"
            doc["accepted"][0]["remote_revision"] = 7
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, stale)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_CONFLICT"})

    def test_duplicate_acknowledgement_rejected(self):
        ws = make_workspace(self)

        def duplicate(doc):
            doc["accepted"].append(dict(doc["accepted"][0]))
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, duplicate)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_RECEIPT"})

    def test_extra_acknowledgement_rejected(self):
        ws = make_workspace(self)

        def extra(doc):
            doc["accepted"].append(
                {
                    "operation_id": OP_MEDIA,
                    "memo_id": MEMO_MEDIA,
                    "revision": 1,
                    "remote_revision": 1,
                    "status": "applied",
                    "attachment_manifest_hash": "0" * 64,
                }
            )
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, extra)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_RECEIPT"})

    def test_rejected_list_nonempty_aborts(self):
        ws = make_workspace(self)

        def rejected(doc):
            doc["rejected"] = [
                {"operation_id": OP_TEXT, "memo_id": MEMO_TEXT, "reason": "synthetic"}
            ]
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, rejected)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_RECEIPT"})

    def test_wrong_manifest_hash_acknowledgement_rejected(self):
        ws = make_workspace(self)

        def wrong_hash(doc):
            doc["accepted"][0]["attachment_manifest_hash"] = "0" * 64
            return doc

        code, payload, _ = self._run_with_receipt_change(ws, wrong_hash)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_COMMIT_RECEIPT"})


# --------------------------------------------------------------------------
# Tests: TUS HEAD Upload-Length contract and Retry-After pacing
# --------------------------------------------------------------------------


class TusLengthAndPacingTests(unittest.TestCase):
    def test_tus_head_upload_length_variants_reject(self):
        variants = {
            "missing": lambda h: {
                k: v for k, v in h.items() if k != "upload-length"
            },
            "malformed": lambda h: {**h, "upload-length": "abc"},
            "wrong": lambda h: {**h, "upload-length": "1"},
        }
        for name, mutate in variants.items():
            with self.subTest(name=name):
                ws = make_workspace(self)
                transport = FakeTransport(FakeServer(ws))

                def change(response, mutate=mutate):
                    return sbi.Response(
                        response.status, mutate(response.headers), response.body
                    )

                transport.hooks.append(
                    hook_transform(match_path("resumable", "HEAD"), change, times=1)
                )
                code, payload, _ = run_cli(ws, transport=transport, execute=True)
                self.assertEqual(
                    payload, {"result": "failed", "error_code": "E_TUS_STATE"}
                )

    def test_resume_head_wrong_length_rejects_before_any_patch(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport1 = FakeTransport(server)
        transport1.hooks.append(
            hook_raise(match_path("resumable", "PATCH"), times=100)
        )
        run_cli(ws, transport=transport1, execute=True)  # interruption at offset 0
        transport2 = FakeTransport(server)

        def wrong_length(response):
            return sbi.Response(
                response.status,
                {**response.headers, "upload-length": "1"},
                response.body,
            )

        transport2.hooks.append(
            hook_transform(match_path("resumable", "HEAD"), wrong_length, times=1)
        )
        code, payload, _ = run_cli(ws, transport=transport2, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_TUS_STATE"})
        self.assertEqual([m for m, _ in transport2.log if m == "PATCH"], [])

    def test_tus_resume_from_zero_offset(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        transport1 = FakeTransport(server)
        transport1.hooks.append(
            hook_raise(match_path("resumable", "PATCH"), times=100)
        )
        code1, payload1, _ = run_cli(ws, transport=transport1, execute=True)
        self.assertEqual(payload1, {"result": "failed", "error_code": "E_NETWORK"})
        checkpoint = read_json(ws.checkpoint_path)
        self.assertEqual(
            checkpoint["tus"][ws.aac_desc["object_key"]]["offset"], 0
        )
        transport2 = FakeTransport(server)
        code2, payload2, _ = run_cli(ws, transport=transport2, execute=True)
        self.assertEqual(code2, 0, payload2)
        self.assertEqual(server.objects[ws.aac_desc["object_key"]], ws.aac_bytes)
        self.assertEqual([m for m, _ in transport2.log if m == "PATCH"], ["PATCH", "PATCH"])

    def test_patch_429_head_then_bounded_sleep_before_resend(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_status(
                match_path("resumable", "PATCH"),
                429,
                headers={"retry-after": "12"},
                times=1,
            )
        )
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(clock.sleeps[0], 12.0)
        resumable = [(m, p) for m, p in transport.log if "resumable" in p]
        first_patch = next(i for i, (m, _) in enumerate(resumable) if m == "PATCH")
        self.assertEqual(resumable[first_patch + 1][0], "HEAD")  # HEAD first
        self.assertEqual(resumable[first_patch + 2][0], "PATCH")  # then resend

    def test_patch_503_retry_after_is_clamped(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_status(
                match_path("resumable", "PATCH"),
                503,
                headers={"retry-after": "9999"},
                times=1,
            )
        )
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(clock.sleeps[0], 60.0)  # bounded

    def test_patch_permanent_no_progress_is_finite(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))
        transport.hooks.append(
            hook_status(
                match_path("resumable", "PATCH"),
                429,
                headers={"retry-after": "1"},
                times=100,
            )
        )
        code, payload, clock = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_NETWORK"})
        self.assertEqual([m for m, _ in transport.log if m == "PATCH"], ["PATCH"] * 5)
        self.assertEqual(clock.sleeps, [1.0] * 5)


# --------------------------------------------------------------------------
# Tests: exact timezone-normalized created_at comparison
# --------------------------------------------------------------------------


class TimestampTests(unittest.TestCase):
    def _run_with_created_at(self, ws, memo_id, created_at):
        transport = FakeTransport(FakeServer(ws))

        def change(doc):
            for item in doc["changes"]:
                if item["id"].lower() == memo_id:
                    item["created_at"] = created_at
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), change)
        )
        return run_cli(ws, transport=transport, execute=True)

    def test_equivalent_representations_compare_equal(self):
        ws = make_workspace(self)
        code, payload, _ = self._run_with_created_at(
            ws, MEMO_TEXT, "2026-01-02T03:04:05+00:00"  # same instant as Z
        )
        self.assertEqual(code, 0, payload)
        ws = make_workspace(self)
        code, payload, _ = self._run_with_created_at(
            ws, MEMO_MEDIA, "2026-01-03T02:00:00.123Z"  # same as +08:00 form
        )
        self.assertEqual(code, 0, payload)

    def test_six_fractional_digits_exact(self):
        ws = make_workspace(self)
        code, payload, _ = self._run_with_created_at(
            ws, MEMO_TEXT, "2026-01-02T03:04:05.000000Z"
        )
        self.assertEqual(code, 0, payload)

    def test_one_microsecond_drift_rejected(self):
        ws = make_workspace(self)
        code, payload, _ = self._run_with_created_at(
            ws, MEMO_TEXT, "2026-01-02T03:04:05.000001Z"
        )
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_MISMATCH"})

    def test_export_excessive_fractional_precision_rejected(self):
        ws = make_workspace(self)
        doc = read_json(ws.operations_path)
        doc["records"][0]["operation"]["payload"]["created_at"] = (
            "2026-01-02T03:04:05.1234567Z"  # 7 digits: rejected, not rounded
        )
        ws._write("operations.json", doc)
        code, payload, _ = run_cli(ws, forbid_network=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PAYLOAD_SCHEMA"})


# --------------------------------------------------------------------------
# Tests: publishable key policy (modern allowlist / legacy anon / no secrets)
# --------------------------------------------------------------------------


class PublishableKeyTests(unittest.TestCase):
    def _run_with_key(self, key):
        ws = make_workspace(self)
        doc = read_json(ws.config_path)
        doc["publishable_key"] = key
        ws._write("config.json", doc, private=True)
        return run_cli(ws, forbid_network=True)

    def test_modern_publishable_key_accepted(self):
        code, payload, _ = self._run_with_key("sb_publishable_synthetic_fixture_key")
        self.assertEqual(code, 0, payload)

    def test_sb_secret_rejected(self):
        code, payload, _ = self._run_with_key("sb_secret_synthetic")
        self.assertEqual(payload, {"result": "failed", "error_code": "E_CONFIG_KEY"})

    def test_legacy_service_role_jwt_rejected(self):
        code, payload, _ = self._run_with_key(
            make_jwt(iss="supabase", role="service_role")
        )
        self.assertEqual(payload, {"result": "failed", "error_code": "E_CONFIG_KEY"})

    def test_legacy_anon_jwt_accepted(self):
        code, payload, _ = self._run_with_key(make_jwt(iss="supabase", role="anon"))
        self.assertEqual(code, 0, payload)

    def test_arbitrary_string_rejected(self):
        code, payload, _ = self._run_with_key("synthetic-publishable-key")
        self.assertEqual(payload, {"result": "failed", "error_code": "E_CONFIG_KEY"})


# --------------------------------------------------------------------------
# Tests: canonical full-pull cursor binding
# --------------------------------------------------------------------------


class PullStub:
    def __init__(self, pages):
        self.pages = list(pages)
        self.calls = 0

    def request(self, method, path, **kwargs):
        self.calls += 1
        return json_response(200, self.pages.pop(0))


def pull_change(sequence, memo_id):
    return {
        "id": memo_id,
        "type": "text",
        "body": "b",
        "created_at": "2026-01-02T03:04:05Z",
        "content_hash": sha(b"c"),
        "sync_revision": 1,
        "attachment_manifest_hash": None,
        "deleted_at": None,
        "change_sequence": sequence,
        "attachments": [],
    }


class PullCursorTests(unittest.TestCase):
    def test_multi_page_progression_with_empty_terminal_page(self):
        pages = [
            {
                "changes": [pull_change(1, MEMO_TEXT), pull_change(2, MEMO_MEDIA)],
                "next_cursor": 2,
                "has_more": True,
            },
            {"changes": [], "next_cursor": 2, "has_more": False},
        ]
        changes = sbi.pull_all_changes(PullStub(pages))
        self.assertEqual(len(changes), 2)

    def test_backward_cursor_on_later_page_rejected(self):
        pages = [
            {
                "changes": [pull_change(1, MEMO_TEXT), pull_change(2, MEMO_MEDIA)],
                "next_cursor": 2,
                "has_more": True,
            },
            {
                "changes": [pull_change(3, MEMO_MOV)],
                "next_cursor": 1,  # backward and not the page maximum
                "has_more": False,
            },
        ]
        with self.assertRaises(sbi.ImportFailure) as caught:
            sbi.pull_all_changes(PullStub(pages))
        self.assertEqual(caught.exception.code, "E_PULL_PROGRESSION")

    def test_jumped_cursor_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def jump(doc):
            doc["next_cursor"] = 9999
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), jump)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_PROGRESSION"})

    def test_unsorted_page_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def unsort(doc):
            doc["changes"] = list(reversed(doc["changes"]))
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), unsort)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_SHAPE"})

    def test_oversized_page_rejected(self):
        ws = make_workspace(self)
        transport = FakeTransport(FakeServer(ws))

        def oversized(doc):
            doc["changes"] = doc["changes"] * 71  # 213 > requested limit 200
            return doc

        transport.hooks.append(
            hook_json_transform(match_path("daypage_pull_sync_changes_v2"), oversized)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_PULL_SHAPE"})

    def test_sequence_gaps_are_allowed(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.next_sequence = 5  # legitimate gaps left by synthetic cleanup
        for sequence, memo_id in (
            (1, "66666666-6666-4666-8666-666666666666"),
            (4, "77777777-7777-4777-8777-777777777777"),
        ):
            server.memos[memo_id] = {
                "id": memo_id,
                "type": "text",
                "body": "pre-existing",
                "created_at": "2025-12-31T00:00:00Z",
                "content_hash": sha(memo_id.encode("utf-8")),
                "sync_revision": 1,
                "attachment_manifest_hash": None,
                "deleted_at": None,
                "change_sequence": sequence,
                "attachments": [],
            }
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(code, 0, payload)
        self.assertEqual(len(server.memos), 5)


# --------------------------------------------------------------------------
# Tests: non-finite numerics (NaN/Infinity) rejected before any request
# --------------------------------------------------------------------------


class NonFiniteNumericTests(unittest.TestCase):
    def _session_with(self, field, value):
        ws = make_workspace(self)
        doc = read_json(ws.session_path)
        doc[field] = value
        ws._write("session.json", doc, private=True)  # json.dumps emits NaN/Infinity
        return ws

    def test_session_nan_expiry_rejected_before_network(self):
        ws = self._session_with("expires_at", float("nan"))
        transport = FakeTransport(FakeServer(ws))
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_JSON"})
        self.assertEqual(transport.log, [])  # before any request or refresh

    def test_session_infinite_expires_in_rejected_before_network(self):
        ws = self._session_with("expires_in", float("inf"))
        transport = FakeTransport(FakeServer(ws))
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertIn(
            payload["error_code"], ("E_JSON", "E_SESSION_SHAPE")
        )
        self.assertEqual(transport.log, [])

    def test_jwt_nonfinite_exp_rejected_before_network(self):
        for exp in (float("nan"), float("inf"), float("-inf"), 1e400):
            with self.subTest(exp=exp):
                ws = make_workspace(self)
                ws._write(
                    "session.json",
                    {
                        "access_token": make_jwt(exp=exp),
                        "refresh_token": REFRESH_TOKEN,
                        "user": {"id": OWNER_ID, "email": EMAIL},
                        "expires_at": NOW + 3600,
                        "expires_in": 3600,
                        "token_type": "bearer",
                        "weak_password": None,
                    },
                    private=True,
                )
                transport = FakeTransport(FakeServer(ws))
                code, payload, _ = run_cli(ws, transport=transport, execute=True)
                self.assertEqual(
                    payload, {"result": "failed", "error_code": "E_AUTH_JWT"}
                )
                self.assertEqual(transport.log, [])


# --------------------------------------------------------------------------
# Tests: project id is exactly 20 lowercase ASCII letters
# --------------------------------------------------------------------------


class ProjectIdTests(unittest.TestCase):
    def test_project_id_shape_rejected(self):
        for project in ("a", "a" * 19, "a" * 21, "A" * 20, "a" * 19 + "1"):
            with self.subTest(length=len(project), sample=project[:1]):
                ws = make_workspace(self)
                doc = read_json(ws.config_path)
                doc["project_id"] = project
                ws._write("config.json", doc, private=True)
                code, payload, _ = run_cli(ws, forbid_network=True)
                self.assertEqual(
                    payload, {"result": "failed", "error_code": "E_CONFIG_SHAPE"}
                )


# --------------------------------------------------------------------------
# Tests: refresh expiry validation and post-refresh identity proof
# --------------------------------------------------------------------------


class RefreshExpiryTests(unittest.TestCase):
    def test_invalid_refreshed_expiry_rejected(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.refresh_exp = NOW - 100  # refresh yields a still-expired token
        transport = FakeTransport(server)
        transport.hooks.append(
            hook_status(match_path("daypage_prepare_attachment_upload"), 401, times=1)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_REFRESH"})

    def test_expired_initial_session_then_server_owner_mismatch(self):
        ws = make_workspace(self)
        ws._write(
            "session.json",
            {
                "access_token": make_jwt(exp=NOW - 100),
                "refresh_token": REFRESH_TOKEN,
                "user": {"id": OWNER_ID, "email": EMAIL},
                "expires_at": NOW - 100,
                "expires_in": 3600,
                "token_type": "bearer",
                "weak_password": None,
            },
            private=True,
        )
        server = FakeServer(ws)
        server.refresh_user = dict(server.user)  # refresh packet is well-formed
        server.user = dict(server.user, id="99999999-9999-4999-8999-999999999999")
        code, payload, _ = run_cli(ws, transport=FakeTransport(server), execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_IDENTITY"})

    def test_refresh_packet_owner_mismatch_rejected(self):
        ws = make_workspace(self)
        server = FakeServer(ws)
        server.refresh_user = dict(
            server.user, id="99999999-9999-4999-8999-999999999999"
        )
        transport = FakeTransport(server)
        transport.hooks.append(
            hook_status(match_path("daypage_prepare_attachment_upload"), 401, times=1)
        )
        code, payload, _ = run_cli(ws, transport=transport, execute=True)
        self.assertEqual(payload, {"result": "failed", "error_code": "E_AUTH_REFRESH"})


if __name__ == "__main__":
    unittest.main()
