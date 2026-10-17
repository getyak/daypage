#!/usr/bin/env python3
"""Verify native password auth rules with a focused Foundation host harness.

Compiles and executes a host harness against the ACTUAL source:

  - DayPageKit/Sources/DayPageServices/NativeAuthFlow.swift

plus a minimal Foundation/CryptoKit/Security test entry. There is NO mirrored
rule implementation: every check executes the real callback, nonce, email,
password-preservation and QA session-namespace code. Real networking and
Keychain access are denied by construction — the harness never touches
URLSession, Supabase, KeychainLocalStorage or any Keychain API (the only
Security call exercised is SecRandomCopyBytes inside the real nonce helper).

Coverage: platform callbacks and callback validation, nonce shape/hashing
boundaries, the existing app email normalization/validation rules with
boundary shapes, exact-as-typed password preservation (empty rejected,
whitespace-only preserved), and the pure QA Keychain service-name resolver
(normal / unknown / nil / main QA IDs, unit and numbered suffixes, Release
fallback to the SDK default).

All fixtures and the harness binary live under the registered artifact root
passed via --artifact-root. Each run removes its disposable fixture/build
children afterwards and retains aggregate evidence (results + source SHA-256
hashes + swiftc -frontend -parse syntax-only receipts for changed Apple files).
The parse step is explicitly NOT a full app/Xcode/SwiftPM build. Live login,
UI flows, real Keychain isolation and full app builds remain unexecuted gates
owned by the parent.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

BASE_COMMIT = "56736224e7f493d58739a29ba1fad8367bf643b0"

REPO_RELATIVE_SOURCES = [
    "DayPageKit/Sources/DayPageServices/NativeAuthFlow.swift",
]

HARNESS_MAIN = r'''
// Foundation/CryptoKit/Security host harness — executes the ACTUAL
// NativeAuthFlow.swift source compiled into this binary. Pure rules only:
// no networking, no Supabase SDK and no Keychain calls ever happen here.
import Foundation

// MARK: - Minimal check runner

struct Harness {
    static var results: [(name: String, ok: Bool, detail: String)] = []

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok, detail))
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " :: \(detail)")")
    }
}

// MARK: - Callback rules (actual NativeAuthFlow)

func runCallbacks() {
    Harness.check(
        "callback.iOSStable",
        (try? NativeAuthFlow.callbackURL(for: .iOS))?.absoluteString == "daypage://auth-callback"
    )
    Harness.check(
        "callback.macOSStable",
        (try? NativeAuthFlow.callbackURL(for: .macOS))?.absoluteString == "daypagemac://auth-callback"
    )

    let valid = URL(string: "daypagemac://auth-callback?code=pkce-code")!
    let validFragment = URL(string: "daypagemac://auth-callback/#access_token=token")!
    let wrongScheme = URL(string: "daypage://auth-callback?code=pkce-code")!
    let wrongHost = URL(string: "daypagemac://record?code=pkce-code")!
    let wrongPath = URL(string: "daypagemac://auth-callback/other?code=pkce-code")!
    let userInfo = URL(string: "daypagemac://user@auth-callback?code=x")!
    Harness.check("callback.acceptsQuery", NativeAuthFlow.isCallback(valid, for: .macOS))
    Harness.check("callback.acceptsFragment", NativeAuthFlow.isCallback(validFragment, for: .macOS))
    Harness.check("callback.rejectsWrongScheme", !NativeAuthFlow.isCallback(wrongScheme, for: .macOS))
    Harness.check("callback.rejectsWrongHost", !NativeAuthFlow.isCallback(wrongHost, for: .macOS))
    Harness.check("callback.rejectsUnexpectedPath", !NativeAuthFlow.isCallback(wrongPath, for: .macOS))
    Harness.check("callback.rejectsUserInfo", !NativeAuthFlow.isCallback(userInfo, for: .macOS))
}

// MARK: - Nonce rules (actual NativeAuthFlow; SecRandomCopyBytes only)

func runNonce() {
    let first = (try? NativeAuthFlow.randomNonce()) ?? ""
    let second = (try? NativeAuthFlow.randomNonce()) ?? ""
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    Harness.check("nonce.shape", first.count == 43 && first.unicodeScalars.allSatisfy(allowed.contains))
    Harness.check("nonce.unique", !first.isEmpty && first != second)
    Harness.check(
        "nonce.hashSHA256",
        NativeAuthFlow.sha256("abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    do {
        _ = try NativeAuthFlow.randomNonce(byteCount: 0)
        Harness.check("nonce.rejectsEmptyByteCount", false, "no error thrown")
    } catch let error as NativeAuthFlow.Error {
        Harness.check("nonce.rejectsEmptyByteCount", error == .invalidByteCount, "got \(error)")
    } catch {
        Harness.check("nonce.rejectsEmptyByteCount", false, "unexpected error \(error)")
    }
}

// MARK: - Email rules (actual NativeAuthFlow)

func runEmail() {
    Harness.check(
        "email.normalizeTrimAndLowercase",
        NativeAuthFlow.normalizedEmail("  User.Name+tag@Example.COM \n") == "user.name+tag@example.com"
    )
    Harness.check(
        "email.normalizeKeepsInterior",
        NativeAuthFlow.normalizedEmail("first.last@sub.example.co.uk") == "first.last@sub.example.co.uk"
            && NativeAuthFlow.normalizedEmail("") == ""
    )

    let valid = [
        "user@example.com",
        "user.name+tag@sub.example.co.uk",
        "  padded@example.com  ",
        "USER@EXAMPLE.COM",
    ]
    for candidate in valid {
        Harness.check(
            "email.accepts[\(candidate)]",
            NativeAuthFlow.isValidEmail(candidate),
            "expected valid"
        )
    }

    let invalid = [
        "",
        "   ",
        "user",
        "user@localhost",
        "user@",
        "@example.com",
        "user@@example.com",
        "user name@example.com",
        "user@exam ple.com",
        "user@example.",
    ]
    for candidate in invalid {
        Harness.check(
            "email.rejects[\(candidate)]",
            !NativeAuthFlow.isValidEmail(candidate),
            "expected invalid"
        )
    }

    // The app's existing pattern accepts a leading-dot domain label. This
    // batch must not impose stricter email policy than the app already had,
    // so the quirk is pinned as behavior, not "fixed" here.
    Harness.check(
        "email.existingPatternQuirkAccepted",
        NativeAuthFlow.isValidEmail("user@.example.com"),
        "leading-dot domain stays accepted by the existing rule"
    )
}

// MARK: - Password preservation (actual NativeAuthFlow)

func runPassword() {
    let raw = "  p@ss word \n"
    Harness.check("password.preservesWhitespaceExactly", NativeAuthFlow.passwordSubmission(from: raw) == raw)
    let unicode = "密码🔑Ünicode"
    Harness.check("password.preservesUnicodeExactly", NativeAuthFlow.passwordSubmission(from: unicode) == unicode)
    Harness.check("password.preservesSingleChar", NativeAuthFlow.passwordSubmission(from: "x") == "x")
    Harness.check("password.rejectsEmptyAsMissing", NativeAuthFlow.passwordSubmission(from: "") == nil)
    Harness.check(
        "password.whitespaceOnlyPreserved",
        NativeAuthFlow.passwordSubmission(from: " ") == " "
            && NativeAuthFlow.passwordSubmission(from: "\t\n") == "\t\n"
    )
}

// MARK: - QA session namespace resolver (actual NativeAuthFlow)

func runQANamespace() {
    func service(_ identity: String?, debug: Bool = true) -> String? {
        NativeAuthFlow.qaSessionStorageServiceName(
            bundleIdentifier: identity,
            isDebugBuild: debug
        )
    }

    Harness.check("qa.normalIDKeepsDefault", service("com.daypage.app") == nil)
    Harness.check("qa.macIDKeepsDefault", service("com.daypage.mac") == nil)
    Harness.check("qa.unknownIDKeepsDefault", service("org.example.other") == nil)
    Harness.check("qa.nilIDKeepsDefault", service(nil) == nil)
    Harness.check("qa.emptyIDKeepsDefault", service("") == nil)
    Harness.check("qa.nearMissPrefixKeepsDefault", service("com.daypage.app.qa") == nil)
    Harness.check("qa.nearMissQAXKeepsDefault", service("com.daypage.app.qax-unit") == nil)
    Harness.check(
        "qa.unknownQAIsolated",
        service("com.daypage.app.qa-mystery") == "com.daypage.app.qa-mystery.supabase.gotrue.swift"
    )

    Harness.check(
        "qa.unitIsolated",
        service("com.daypage.app.qa-unit") == "com.daypage.app.qa-unit.supabase.gotrue.swift"
    )
    Harness.check(
        "qa.mainIsolated",
        service("com.daypage.app.qa-ui") == "com.daypage.app.qa-ui.supabase.gotrue.swift"
    )
    let first = service("com.daypage.app.qa-ui-928")
    let second = service("com.daypage.app.qa-ui-929")
    Harness.check(
        "qa.numberedSuffixIsolated",
        first == "com.daypage.app.qa-ui-928.supabase.gotrue.swift"
            && second == "com.daypage.app.qa-ui-929.supabase.gotrue.swift"
            && first != second
    )

    for identity in [
        "com.daypage.app",
        "com.daypage.app.qa-unit",
        "com.daypage.app.qa-ui-928",
        "com.daypage.app.qa-mystery",
    ] {
        Harness.check(
            "qa.releaseKeepsDefault[\(identity)]",
            service(identity, debug: false) == nil,
            "expected default service in Release"
        )
    }
}

runCallbacks()
runNonce()
runEmail()
runPassword()
runQANamespace()

let failed = Harness.results.filter { !$0.ok }
print("HARNESS_SUMMARY passed=\(Harness.results.count - failed.count) failed=\(failed.count)")
if !failed.isEmpty {
    exit(1)
}
'''


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_command(command: list[str], cwd: pathlib.Path, env: dict | None = None):
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=1800,
    )
    return completed


def changed_swift_files(repo_root: pathlib.Path) -> list[str]:
    names: set[str] = set()
    diff = run_command(
        ["git", "diff", "--name-only", BASE_COMMIT, "--", "*.swift"], repo_root
    )
    if diff.returncode == 0:
        names.update(line for line in diff.stdout.splitlines() if line.strip())
    untracked = run_command(
        ["git", "ls-files", "--others", "--exclude-standard", "--", "*.swift"], repo_root
    )
    if untracked.returncode == 0:
        names.update(line for line in untracked.stdout.splitlines() if line.strip())
    apple_prefixes = (
        "DayPage/",
        "DayPageMac/",
        "DayPageKit/",
        "DayPageTests/",
        "DayPageWatch/",
        "DayPageWidget/",
    )
    return sorted(name for name in names if name.startswith(apple_prefixes))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact-root",
        required=True,
        help="Registered artifact root for fixtures, binaries and evidence",
    )
    args = parser.parse_args()

    repo_root = pathlib.Path(__file__).resolve().parents[2]
    artifact_root = pathlib.Path(args.artifact_root).resolve()
    if not pathlib.Path(args.artifact_root).is_absolute():
        print("ERROR --artifact-root must be an absolute path", file=sys.stderr)
        return 2
    if artifact_root in (pathlib.Path("/"), pathlib.Path.home()):
        print("ERROR refusing suspicious artifact root", file=sys.stderr)
        return 2
    artifact_root.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = artifact_root / "work" / f"run-{timestamp}-{os.getpid()}"
    fixtures_dir = run_dir / "fixtures"
    bin_dir = run_dir / "bin"
    for directory in (fixtures_dir, bin_dir):
        directory.mkdir(parents=True, exist_ok=True)

    def under_root(path: pathlib.Path) -> bool:
        try:
            path.resolve().relative_to(artifact_root)
            return True
        except ValueError:
            return False

    # ---- gather actual sources + hashes -----------------------------------
    source_paths: list[pathlib.Path] = []
    source_hashes: dict[str, str] = {}
    for relative in REPO_RELATIVE_SOURCES:
        path = repo_root / relative
        if not path.is_file():
            print(f"ERROR missing required source {relative}", file=sys.stderr)
            return 2
        source_paths.append(path)
        source_hashes[relative] = sha256_file(path)

    # Top-level executable code requires the file to be named main.swift.
    harness_main_path = run_dir / "main.swift"
    harness_main_path.write_text(HARNESS_MAIN, encoding="utf-8")
    source_hashes["<generated>/host_harness_main.swift"] = sha256_file(harness_main_path)

    # ---- compile the focused Foundation host harness ---------------------
    binary_path = bin_dir / "native_password_host_harness"
    compile_command = [
        "swiftc",
        "-swift-version", "5",
        "-o", str(binary_path),
        *[str(path) for path in source_paths],
        str(harness_main_path),
    ]
    compiled = run_command(compile_command, repo_root)
    if compiled.returncode != 0 or not binary_path.is_file():
        print("ERROR harness compilation failed", file=sys.stderr)
        print(compiled.stdout, file=sys.stderr)
        print(compiled.stderr, file=sys.stderr)
        shutil.rmtree(run_dir, ignore_errors=True)
        return 2
    if not under_root(binary_path):
        print("ERROR harness binary escaped the artifact root", file=sys.stderr)
        return 2

    # ---- execute the harness --------------------------------------------
    env = dict(os.environ)
    env["DAYPAGE_HARNESS_FIXTURE_ROOT"] = str(fixtures_dir)
    executed = run_command([str(binary_path)], run_dir, env=env)
    harness_output = executed.stdout + executed.stderr
    print(harness_output.strip())

    harness_results = []
    for line in harness_output.splitlines():
        if line.startswith(("PASS ", "FAIL ")):
            status, _, rest = line.partition(" ")
            name, _, detail = rest.partition(" :: ")
            harness_results.append(
                {"name": name, "status": "pass" if status == "PASS" else "fail", "detail": detail}
            )
    summary_line = next(
        (line for line in harness_output.splitlines() if line.startswith("HARNESS_SUMMARY")), ""
    )
    harness_ok = executed.returncode == 0 and "failed=0" in summary_line and bool(harness_results)

    # ---- syntax-only parse receipts for changed Apple files --------------
    parse_results = []
    parse_ok = True
    for relative in changed_swift_files(repo_root):
        parsed = run_command(["swiftc", "-frontend", "-parse", relative], repo_root)
        entry_ok = parsed.returncode == 0
        parse_ok = parse_ok and entry_ok
        parse_results.append({"file": relative, "status": "ok" if entry_ok else "failed"})
    parse_results.append(
        {
            "file": "<note>",
            "status": "syntax-only",
            "detail": "swiftc -frontend -parse is not a full app/Xcode/SwiftPM build",
        }
    )

    # ---- aggregate evidence (retained) + disposable cleanup --------------
    evidence_dir = artifact_root / "evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    evidence_path = evidence_dir / "native-password-host-evidence.json"
    evidence = {"aggregate": "native-password-host", "runs": []}
    if evidence_path.is_file():
        try:
            existing = json.loads(evidence_path.read_text(encoding="utf-8"))
            if isinstance(existing.get("runs"), list):
                evidence = existing
        except (ValueError, OSError):
            pass

    compiler = run_command(["swiftc", "--version"], repo_root)
    evidence["runs"].append(
        {
            "timestamp": timestamp,
            "artifact_root": str(artifact_root),
            "compiler": compiler.stdout.strip().splitlines()[0] if compiler.stdout.strip() else "unknown",
            "source_sha256": source_hashes,
            "harness": {
                "compiled": True,
                "exit_code": executed.returncode,
                "summary": summary_line,
                "results": harness_results,
            },
            "parse_syntax_only": parse_results,
            "result": "pass" if (harness_ok and parse_ok) else "fail",
        }
    )
    evidence_path.write_text(json.dumps(evidence, indent=1, sort_keys=True), encoding="utf-8")

    # Disposable fixture/build children of THIS run are removed; aggregate
    # evidence and source hashes are retained above.
    shutil.rmtree(run_dir, ignore_errors=True)

    print(f"EVIDENCE {evidence_path}")
    print(f"RESULT {'pass' if (harness_ok and parse_ok) else 'fail'}")
    if not harness_ok:
        print("ERROR harness checks failed", file=sys.stderr)
        return 1
    if not parse_ok:
        print("ERROR syntax-only parse failed for changed Apple files", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
