#!/usr/bin/env bash
# Manual GitHub-hosted CI only. All notes, keys and attachments are synthetic.
set -euo pipefail

if [[ "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true ]]; then
  echo "This native matrix runs only in GitHub Actions." >&2
  exit 2
fi
daypage_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$PWD" != "$daypage_repo_root" || -z "${RUNNER_TEMP:-}" || ! -d "$RUNNER_TEMP" ]]; then
  echo "Run from the repository root with the runner's temporary directory." >&2
  exit 2
fi
daypage_evidence="${DAYPAGE_NATIVE_CI_OUTPUT_DIR:-$RUNNER_TEMP/daypage-native-ui/evidence}"
daypage_evidence="$(python3 - "$RUNNER_TEMP" "$daypage_evidence" <<'PY'
import pathlib, sys
temporary, output = (pathlib.Path(value).resolve() for value in sys.argv[1:])
if output == temporary or temporary not in output.parents:
    raise SystemExit('Native evidence must be a dedicated runner temporary subdirectory')
if output.exists() and any(output.iterdir()):
    raise SystemExit('Refusing to mix this run with existing native evidence')
print(output)
PY
)"
mkdir -p "$daypage_evidence"
daypage_native_root="$(mktemp -d "$RUNNER_TEMP/daypage-native-ci.XXXXXX")"
daypage_fixture_pid=""
cleanup() {
  local daypage_exit_code=$?
  trap - EXIT INT TERM
  if [[ -n "$daypage_fixture_pid" ]]; then
    if kill -0 "$daypage_fixture_pid" 2>/dev/null; then kill "$daypage_fixture_pid" 2>/dev/null || true; fi
    wait "$daypage_fixture_pid" 2>/dev/null || true
  fi
  exit "$daypage_exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_logged() {
  local daypage_log="$1"
  shift
  echo "Running $(basename "$daypage_log")"
  if "$@" > "$daypage_log" 2>&1; then return 0; else
    local daypage_command_exit=$?
    tail -n 60 "$daypage_log" >&2
    # Preserve the actual failing assertions even when the final suite tail
    # contains only teardown. Test traffic and keys are synthetic in this job.
    rg -n '(error:|Test Case.*failed|AssertionError)' "$daypage_log" >&2 || true
    return "$daypage_command_exit"
  fi
}

python3 - "$daypage_evidence/provenance.json" <<'PY'
import json, os, pathlib, subprocess, sys
receipt = {
    'sourceSHA': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'runId': os.environ.get('GITHUB_RUN_ID'),
    'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
    'runnerImage': os.environ.get('ImageVersion'),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'simulatorSDK': subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip(),
    'bundleId': 'com.daypage.app.localqa',
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(receipt, indent=2) + '\n')
PY
xcrun simctl list devices available --json > "$daypage_evidence/runner-simulators.json"
daypage_destination="$(python3 scripts/ci/select_simulator.py --input "$daypage_evidence/runner-simulators.json" --format destination)"
printf '%s\n' "$daypage_destination" > "$daypage_evidence/destination.log"

# Own the fixture process; never borrow an existing service on this port.
python3 -u scripts/qa/local_notebook_ai_fixture.py > "$daypage_evidence/fixture.log" 2>&1 &
daypage_fixture_pid=$!
daypage_fixture_ready=false
for _ in {1..30}; do
  if ! kill -0 "$daypage_fixture_pid" 2>/dev/null; then
    echo "The task-owned loopback fixture could not start." >&2
    exit 1
  fi
  daypage_listener="$(lsof -nP -iTCP:18763 -sTCP:LISTEN -t 2>/dev/null || true)"
  if [[ "$daypage_listener" == "$daypage_fixture_pid" ]] && \
    [[ "$(curl --noproxy '*' --silent --fail --max-time 2 http://127.0.0.1:18763/health 2>/dev/null || true)" == GET-326-local-fixture ]]; then
    daypage_fixture_ready=true
    break
  fi
  sleep 1
done
if [[ "$daypage_fixture_ready" != true ]]; then
  echo "The owned loopback fixture did not become ready." >&2
  exit 1
fi

daypage_project=DayPageLocal/DayPageLocal.xcodeproj
daypage_common=(-project "$daypage_project" -scheme DayPage -configuration Debug
  -destination "$daypage_destination" -jobs 2 -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1)
daypage_negative="$daypage_native_root/NegativeDerivedData"
daypage_signed="$daypage_native_root/SignedDerivedData"

# First prove the genuine unavailable-Keychain UI; a positive branch is not
# accepted as negative evidence merely because XCTest itself returned success.
run_logged "$daypage_evidence/negative-build.log" xcodebuild build-for-testing \
  "${daypage_common[@]}" -derivedDataPath "$daypage_negative" CODE_SIGNING_ALLOWED=NO
daypage_negative_exit=0
run_logged "$daypage_evidence/negative-ui.log" xcodebuild test-without-building \
  "${daypage_common[@]}" -derivedDataPath "$daypage_negative" CODE_SIGNING_ALLOWED=NO \
  -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testAISetupKeepsQuestionAndEmptyNotebookExplainsScope \
  -resultBundlePath "$daypage_evidence/negative-keychain.xcresult" || daypage_negative_exit=$?
daypage_negative_export_exit=0
run_logged "$daypage_evidence/negative-export.log" xcrun xcresulttool export attachments \
  --path "$daypage_evidence/negative-keychain.xcresult" --output-path "$daypage_evidence/negative-attachments" || daypage_negative_export_exit=$?
daypage_negative_summary_exit=0
run_logged "$daypage_evidence/negative-summary.log" xcrun xcresulttool get test-results summary \
  --path "$daypage_evidence/negative-keychain.xcresult" --compact || daypage_negative_summary_exit=$?
if ((daypage_negative_exit != 0)); then exit "$daypage_negative_exit"; fi
if ((daypage_negative_export_exit != 0)); then exit "$daypage_negative_export_exit"; fi
if ((daypage_negative_summary_exit != 0)); then exit "$daypage_negative_summary_exit"; fi
python3 - "$daypage_evidence" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
summary = json.loads((root / 'negative-summary.log').read_text())
assert summary['result'] == 'Passed' and summary['failedTests'] == 0 and summary['skippedTests'] == 0 and summary['passedTests'] == 1 and summary['totalTestCount'] == 1
records = json.loads((root / 'negative-attachments/manifest.json').read_text())
assert any('ai-key-unavailable-inline' in attachment.get('suggestedHumanReadableName', '')
           for record in records for attachment in record.get('attachments', [])), 'The denied-Keychain recovery branch did not execute'
(root / 'negative-receipt.json').write_text(json.dumps({'verified': True, 'tests': summary,
    'requiredAttachment': 'ai-key-unavailable-inline'}, indent=2) + '\n')
PY

# Let Xcode generate simulated Mach-O entitlements and the local ad hoc
# signature. This never accesses a Developer ID key or changes release signing.
daypage_signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES)
run_logged "$daypage_evidence/signed-build.log" xcodebuild build-for-testing \
  "${daypage_common[@]}" -derivedDataPath "$daypage_signed" "${daypage_signing[@]}"
daypage_app="$daypage_signed/Build/Products/Debug-iphonesimulator/DayPage.app"
python3 - "$daypage_signed" "$daypage_evidence" <<'PY'
import json, pathlib, plistlib, sys
derived, output = map(pathlib.Path, sys.argv[1:])
app = derived / 'Build/Products/Debug-iphonesimulator/DayPage.app'
bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
assert bundle == 'com.daypage.app.localqa', 'Only the isolated Debug QA app may run'
folder = derived / 'Build/Intermediates.noindex/DayPageLocal.build/Debug-iphonesimulator/DayPage.build'
receipts = []
for path in folder.rglob('*.xcent*'):
    try: value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException): continue
    app_id = value.get('application-identifier')
    if not isinstance(app_id, str) or not (app_id == bundle or app_id.endswith('.' + bundle)): continue
    # Apple uses the application identifier as the private default when there
    # are no explicit Keychain groups. Xcode's simulated variant may therefore
    # contain only application-identifier; that is not a shared-group grant.
    # https://developer.apple.com/documentation/security/ksecattraccessgroup
    groups = value.get('keychain-access-groups', [])
    assert isinstance(groups, list) and all(group == app_id for group in groups), 'Unexpected production or foreign Keychain group'
    assert value.get('com.apple.security.application-groups', []) == [], 'Shared app groups are not allowed in this QA identity'
    effective_groups = list(dict.fromkeys([*groups, app_id]))
    receipts.append({'generatedFile': str(path.relative_to(derived)), 'applicationIdentifier': app_id,
                     'explicitKeychainAccessGroups': groups, 'keychainAccessGroups': effective_groups})
assert receipts, 'Xcode did not generate the QA Simulator Keychain entitlements'
(output / 'simulator-entitlements.json').write_text(json.dumps(receipts, indent=2) + '\n')
PY
run_logged "$daypage_evidence/signature.log" codesign -dv --verbose=2 "$daypage_app"
run_logged "$daypage_evidence/signature-verification.log" codesign --verify --deep --strict "$daypage_app"
run_logged "$daypage_evidence/macho.log" otool -l "$daypage_app/DayPage"
if ! grep -q 'sectname __entitlements' "$daypage_evidence/macho.log"; then
  echo "The QA executable is missing its simulated Mach-O entitlements." >&2
  exit 1
fi
daypage_signed_exit=0
run_logged "$daypage_evidence/signed-ui.log" xcodebuild test-without-building \
  "${daypage_common[@]}" -derivedDataPath "$daypage_signed" "${daypage_signing[@]}" \
  -resultBundlePath "$daypage_evidence/signed-full-ui.xcresult" || daypage_signed_exit=$?
daypage_signed_summary_exit=0
run_logged "$daypage_evidence/signed-summary.log" xcrun xcresulttool get test-results summary \
  --path "$daypage_evidence/signed-full-ui.xcresult" --compact || daypage_signed_summary_exit=$?
daypage_signed_export_exit=0
run_logged "$daypage_evidence/signed-export.log" xcrun xcresulttool export attachments \
  --path "$daypage_evidence/signed-full-ui.xcresult" --output-path "$daypage_evidence/signed-attachments" || daypage_signed_export_exit=$?
if ((daypage_signed_exit != 0)); then exit "$daypage_signed_exit"; fi
if ((daypage_signed_summary_exit != 0)); then exit "$daypage_signed_summary_exit"; fi
if ((daypage_signed_export_exit != 0)); then exit "$daypage_signed_export_exit"; fi
python3 - "$daypage_evidence" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
summary = json.loads((root / 'signed-summary.log').read_text())
assert summary['result'] == 'Passed' and summary['failedTests'] == 0 and summary['skippedTests'] == 0, 'Every native UI test must execute and pass'
assert summary['passedTests'] == summary['totalTestCount'] and summary['passedTests'] >= 41, 'The complete current UI suite did not execute'
receipt = {'passed': True, 'source': json.loads((root / 'provenance.json').read_text()),
           'negative': json.loads((root / 'negative-receipt.json').read_text()), 'positive': summary}
(root / 'native-acceptance.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
echo "Verified the denied-Keychain recovery branch and the complete signed native UI suite."
