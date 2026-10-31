#!/usr/bin/env python3
# Update a TestFlight build's "What to Test" (changelog) via the App Store
# Connect API. Designed to run from CI as the second half of a two-step deploy:
# the deploy workflow uploads the IPA fast (no changelog), and this script runs
# afterwards once ASC has finished processing the build, restoring the
# changelog without blocking the upload step on Apple's processing queue.
#
# Required env:
#   APP_STORE_CONNECT_API_KEY_ID       — ASC API key id (10-char string)
#   APP_STORE_CONNECT_ISSUER_ID        — ASC API issuer id (UUID)
#   APP_STORE_CONNECT_API_KEY_CONTENT  — ES256 PEM-encoded private key (multi-line)
#   ASC_APP_ID                         — App Store Connect app id (numeric, e.g. 6762390618)
#   BUILD_NUMBER                       — CURRENT_PROJECT_VERSION used in the build (e.g. "446")
#   MARKETING_VERSION                  — CFBundleShortVersionString (e.g. "0.1.66")
#   CHANGELOG_FILE                     — path to plaintext changelog
# Optional:
#   LOCALE                             — beta-build-localization locale (default "en-US")
#   MAX_WAIT_SECONDS                   — total seconds to wait for build to reach processingState=VALID (default 1800)
#   POLL_INTERVAL_SECONDS              — seconds between polls (default 30)
#   EXPECTED_BUNDLE_ID                 — app identity guard (default com.daypage.app)
#   RELEASE_RECEIPT_FILE               — optional path for a non-sensitive JSON readback
#   RELEASE_SOURCE_SHA / RELEASE_TAG   — optional release provenance for the receipt
#
# Exits 0 on success, non-zero with diagnostic on failure.

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from datetime import datetime, timezone

ASC_BASE = "https://api.appstoreconnect.apple.com"


def env(name: str, default: str | None = None, *, required: bool = True) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        print(f"ERROR: env var {name} is required", file=sys.stderr)
        sys.exit(2)
    return value or ""


def make_jwt(key_id: str, issuer_id: str, private_key_pem: str) -> str:
    try:
        import jwt  # PyJWT is needed only when the live CI caller signs a token.
    except ImportError:
        raise RuntimeError("PyJWT not installed. Run: pip install pyjwt cryptography") from None
    # ASC tokens have a max lifetime of 20 minutes; we re-mint each polling
    # round to stay safe across long waits.
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 19 * 60,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": key_id, "typ": "JWT"}
    try:
        return jwt.encode(payload, private_key_pem, algorithm="ES256", headers=headers)
    except Exception:
        raise RuntimeError("Could not sign the App Store Connect API token") from None


def asc_request(method: str, path: str, token: str, *, body: dict | None = None,
                query: dict | None = None) -> tuple[int, dict]:
    url = ASC_BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query, doseq=True)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read().decode()
            return resp.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as e:
        # Error payloads are opaque and can contain sensitive diagnostics.
        # Callers report the operation and status, never serialize that body.
        e.close()
        return e.code, {}
    except urllib.error.URLError:
        raise RuntimeError(f"{method} {path} request failed") from None
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise RuntimeError(f"{method} {path} returned invalid JSON") from None


def require_resource(resource: dict, kind: str) -> dict:
    if (not isinstance(resource, dict) or resource.get("type") != kind
            or not isinstance(resource.get("id"), str) or not resource["id"].strip()
            or not isinstance(resource.get("attributes"), dict)):
        raise RuntimeError(f"ASC returned an invalid {kind} resource")
    return resource


def get_resource(token: str, path: str, kind: str, *, query=None) -> tuple[dict, list]:
    status, payload = asc_request("GET", path, token, query=query)
    if status != 200:
        raise RuntimeError(f"GET {path} failed: HTTP {status}")
    if not isinstance(payload, dict) or not isinstance(payload.get("included", []), list):
        raise RuntimeError(f"GET {path} returned an invalid response")
    return require_resource(payload.get("data"), kind), payload.get("included", [])


def verify_app(token: str, app_id: str, expected_bundle: str) -> dict:
    path = "/v1/apps/" + urllib.parse.quote(app_id, safe="")
    app, _ = get_resource(token, path, "apps", query={"fields[apps]": "bundleId"})
    if app["id"] != app_id or app["attributes"].get("bundleId") != expected_bundle:
        raise RuntimeError("App identity or bundle ID does not match the expected release target")
    return app


def validate_build(build: dict, included: list, app_id: str, build_number: str,
                   marketing_version: str, *, build_id: str | None = None) -> dict:
    require_resource(build, "builds")
    relationships = build.get("relationships") or {}
    app = (relationships.get("app") or {}).get("data") or {}
    version_link = (relationships.get("preReleaseVersion") or {}).get("data") or {}
    versions = [item for item in included if isinstance(item, dict)
                and item.get("type") == "preReleaseVersions" and item.get("id") == version_link.get("id")]
    if (build["attributes"].get("version") != build_number
            or (build_id is not None and build["id"] != build_id)
            or app.get("type") != "apps" or app.get("id") != app_id
            or version_link.get("type") != "preReleaseVersions" or len(versions) != 1
            or (versions[0].get("attributes") or {}).get("version") != marketing_version
            or (versions[0].get("attributes") or {}).get("platform") != "IOS"
            or not isinstance(build["attributes"].get("processingState"), str)):
        raise RuntimeError("ASC build identity/version does not match the exact release target")
    return build


def collection_pages(token: str, path: str, *, query=None):
    """Bound pagination to the same ASC origin and exact resource path."""
    seen = set()
    original_query = dict(query or {})
    for _ in range(100):
        status, payload = asc_request("GET", path, token, query=query)
        if status != 200:
            raise RuntimeError(f"GET {path} failed: HTTP {status}")
        if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
            raise RuntimeError(f"GET {path} returned an invalid collection")
        yield payload["data"]
        next_url = (payload.get("links") or {}).get("next")
        if not next_url:
            return
        if not isinstance(next_url, str) or next_url in seen:
            raise RuntimeError("ASC returned invalid or repeated pagination")
        seen.add(next_url)
        parsed = urllib.parse.urlsplit(urllib.parse.urljoin(ASC_BASE, next_url))
        if (parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com"
                or parsed.path != path or parsed.fragment):
            raise RuntimeError("ASC pagination must stay on the same App Store Connect resource")
        next_query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        for key, value in original_query.items():
            if key.startswith("filter[") and next_query.get(key, value) != str(value):
                raise RuntimeError("ASC pagination changed the requested resource scope")
        query = {**original_query, **next_query}
    raise RuntimeError("ASC pagination exceeded its bounded page limit")


def list_resources(token: str, path: str, kind: str, *, query=None) -> list[dict]:
    return [require_resource(item, kind)
            for page in collection_pages(token, path, query=query) for item in page]


def group_build_ids(token: str, group_id: str) -> set[str]:
    """The documented relationship returns build identities, not full resources."""
    path = "/v1/betaGroups/" + urllib.parse.quote(group_id, safe="") + "/relationships/builds"
    identifiers = set()
    for page in collection_pages(token, path, query={"limit": 200}):
        for item in page:
            if (not isinstance(item, dict) or item.get("type") != "builds"
                    or not isinstance(item.get("id"), str) or not item["id"].strip()):
                raise RuntimeError("ASC returned an invalid group build identity")
            identifiers.add(item["id"])
    return identifiers


def find_build(token: str, app_id: str, build_number: str,
               marketing_version: str) -> dict | None:
    status, payload = asc_request(
        "GET",
        "/v1/builds",
        token,
        query={
            "filter[app]": app_id,
            "filter[version]": build_number,
            "filter[preReleaseVersion.version]": marketing_version,
            "limit": 5,
            "include": "app,preReleaseVersion",
        },
    )
    if status != 200:
        raise RuntimeError(f"GET /v1/builds failed: HTTP {status}")
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise RuntimeError("ASC returned an invalid builds collection")
    items = payload["data"]
    if not items:
        return None
    if len(items) != 1 or not isinstance(payload.get("included"), list):
        raise RuntimeError("ASC returned an ambiguous or incomplete build identity")
    return validate_build(items[0], payload["included"], app_id, build_number, marketing_version)


def wait_for_processed_build(token_factory, app_id: str, build_number: str,
                             marketing_version: str, max_wait: int,
                             poll_interval: int) -> dict:
    deadline = time.time() + max_wait
    last_state: str | None = None
    while True:
        token = token_factory()
        build = find_build(token, app_id, build_number, marketing_version)
        if build is None:
            state_msg = "build not yet visible in ASC"
        else:
            state = build.get("attributes", {}).get("processingState")
            last_state = state
            if state == "VALID":
                return build
            if state in {"INVALID", "FAILED"}:
                raise RuntimeError(
                    f"Build {marketing_version}({build_number}) processing ended in {state}"
                )
            state_msg = f"processingState={state}"
        remaining = int(deadline - time.time())
        if remaining <= 0:
            raise TimeoutError(
                f"Timed out after {max_wait}s waiting for build "
                f"{marketing_version}({build_number}) to reach VALID "
                f"(last seen: {last_state or 'not found'})"
            )
        print(f"  {state_msg}; sleeping {poll_interval}s ({remaining}s left)")
        time.sleep(poll_interval)


def upsert_localization(token: str, build_id: str, locale: str,
                        whats_new: str) -> None:
    localizations = list_resources(token, f"/v1/builds/{urllib.parse.quote(build_id, safe='')}/betaBuildLocalizations",
                                   "betaBuildLocalizations", query={"limit": 200})
    matching = [item for item in localizations if item["attributes"].get("locale") == locale]
    if len(matching) > 1:
        raise RuntimeError("ASC returned more than one localization for the requested locale")
    existing = matching[0] if matching else None

    if existing:
        loc_id = existing["id"]
        body = {
            "data": {
                "type": "betaBuildLocalizations",
                "id": loc_id,
                "attributes": {"whatsNew": whats_new},
            }
        }
        status, payload = asc_request("PATCH",
                                      f"/v1/betaBuildLocalizations/{urllib.parse.quote(loc_id, safe='')}",
                                      token, body=body)
        if status not in (200, 204):
            raise RuntimeError(
                f"PATCH betaBuildLocalization failed: HTTP {status}"
            )
        print(f"Updated existing betaBuildLocalization {loc_id} (locale={locale})")
    else:
        body = {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": whats_new},
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        }
        status, payload = asc_request("POST", "/v1/betaBuildLocalizations",
                                      token, body=body)
        if status not in (200, 201):
            raise RuntimeError(
                f"POST betaBuildLocalizations failed: HTTP {status}"
            )
        print(f"Created betaBuildLocalization (locale={locale})")


def release_readback(token: str, app: dict, build_id: str, build_number: str,
                     marketing_version: str, locale: str, whats_new: str,
                     source_sha: str, release_tag: str) -> dict:
    path = "/v1/builds/" + urllib.parse.quote(build_id, safe="")
    build, included = get_resource(token, path, "builds", query={"include": "app,preReleaseVersion"})
    validate_build(build, included, app["id"], build_number, marketing_version, build_id=build_id)
    detail, _ = get_resource(token, path + "/buildBetaDetail", "buildBetaDetails",
                             query={"fields[buildBetaDetails]": "internalBuildState,externalBuildState"})
    # ASC rejects filter[builds] on the group collection despite listing it in
    # documentation. Read this app's groups and verify exact build membership.
    groups = list_resources(token, "/v1/apps/" + urllib.parse.quote(app["id"], safe="") + "/betaGroups",
                            "betaGroups", query={"limit": 200, "fields[betaGroups]": "name,isInternalGroup"})
    safe_groups = []
    for group in groups:
        if build_id not in group_build_ids(token, group["id"]):
            continue
        attributes = group["attributes"]
        if not isinstance(attributes.get("name"), str) or not isinstance(attributes.get("isInternalGroup"), bool):
            raise RuntimeError("ASC returned incomplete beta group metadata")
        safe_groups.append({"id": group["id"], "name": attributes["name"],
                            "isInternalGroup": attributes["isInternalGroup"]})
    localizations = list_resources(token, path + "/betaBuildLocalizations", "betaBuildLocalizations",
                                   query={"limit": 200})
    matching = [item for item in localizations if item["attributes"].get("locale") == locale]
    if len(matching) != 1 or matching[0]["attributes"].get("whatsNew") != whats_new:
        raise RuntimeError("ASC did not return the exact updated What to Test text")

    attributes = build["attributes"]
    expiry = attributes.get("expirationDate")
    expiration = None
    if expiry is not None:
        try:
            expiration = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
            if expiration.tzinfo is None:
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise RuntimeError("ASC returned an invalid build expiration date") from None
    internal = detail["attributes"].get("internalBuildState")
    external = detail["attributes"].get("externalBuildState")
    if not isinstance(internal, str) or not isinstance(external, str):
        raise RuntimeError("ASC returned incomplete testing state")
    ready = (attributes.get("processingState") == "VALID" and attributes.get("expired") is False
             and expiration is not None and expiration > datetime.now(timezone.utc)
             and internal == "IN_BETA_TESTING")
    return {
        "appId": app["id"], "bundleId": app["attributes"]["bundleId"],
        "marketingVersion": marketing_version, "buildNumber": build_number, "buildId": build_id,
        "processingState": attributes["processingState"], "expired": attributes.get("expired"),
        "expirationDate": expiry, "internalBuildState": internal, "externalBuildState": external,
        "betaGroups": safe_groups, "ready": ready, "sourceSha": source_sha, "releaseTag": release_tag,
        "notesLocale": locale, "notesVerified": True,
    }


def write_receipt(path: Path, receipt: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".testflight-receipt-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(receipt, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    key_id = env("APP_STORE_CONNECT_API_KEY_ID")
    issuer_id = env("APP_STORE_CONNECT_ISSUER_ID")
    key_pem = env("APP_STORE_CONNECT_API_KEY_CONTENT")
    app_id = env("ASC_APP_ID")
    build_number = env("BUILD_NUMBER")
    marketing_version = env("MARKETING_VERSION")
    changelog_path = env("CHANGELOG_FILE")
    locale = env("LOCALE", "en-US", required=False)
    max_wait = int(env("MAX_WAIT_SECONDS", "1800", required=False))
    poll_interval = int(env("POLL_INTERVAL_SECONDS", "30", required=False))
    expected_bundle = env("EXPECTED_BUNDLE_ID", "com.daypage.app")
    receipt_file = env("RELEASE_RECEIPT_FILE", required=False)
    receipt_path = Path(receipt_file) if receipt_file else None
    if receipt_path is not None:
        if receipt_path.is_symlink():
            raise RuntimeError("Release receipt path must not be a symbolic link")
        # A failed retry must not leave a previous success receipt behind.
        receipt_path.unlink(missing_ok=True)

    changelog_text = Path(changelog_path).read_text(encoding="utf-8").strip()
    if not changelog_text:
        print("ERROR: changelog file is empty", file=sys.stderr)
        return 2

    # ASC caps "What to Test" at 4000 chars; deploy step already trims to 3800
    # but be defensive in case this script is invoked with a different source.
    if len(changelog_text) > 4000:
        changelog_text = changelog_text[:4000]

    print(f"Updating changelog for build {marketing_version} ({build_number}), locale={locale}")
    print(f"  app_id={app_id}, max_wait={max_wait}s, poll_interval={poll_interval}s")
    print(f"  changelog: {len(changelog_text)} chars")

    def token_factory() -> str:
        return make_jwt(key_id, issuer_id, key_pem)

    app = verify_app(token_factory(), app_id, expected_bundle)
    print("Verified app bundle identity. Waiting for build to reach processingState=VALID...")
    build = wait_for_processed_build(
        token_factory, app_id, build_number, marketing_version,
        max_wait, poll_interval,
    )
    build_id = build["id"]
    print(f"Build is VALID: id={build_id}")

    upsert_localization(token_factory(), build_id, locale, changelog_text)
    receipt = release_readback(token_factory(), app, build_id, build_number, marketing_version,
                               locale, changelog_text, env("RELEASE_SOURCE_SHA", required=False),
                               env("RELEASE_TAG", required=False))
    if receipt_path is not None:
        write_receipt(receipt_path, receipt)
    print("Changelog update verified by Apple readback.")
    print(f"Internal testing state: {receipt['internalBuildState']}; ready={receipt['ready']}; "
          f"existing beta groups={len(receipt['betaGroups'])}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, TimeoutError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
