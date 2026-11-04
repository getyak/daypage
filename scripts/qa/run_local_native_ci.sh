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
    grep -En '(error:|Test Case.*failed|AssertionError)' "$daypage_log" >&2 || true
    return "$daypage_command_exit"
  fi
}

python3 - "$daypage_evidence/provenance.json" <<'PY'
import json, os, pathlib, platform, subprocess, sys
receipt = {
    'sourceSHA': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'runId': os.environ.get('GITHUB_RUN_ID'),
    'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
    'runnerImage': os.environ.get('ImageVersion'),
    'hostArchitecture': platform.machine(),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'simulatorSDK': subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip(),
    'bundleId': 'com.daypage.app.localqa',
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(receipt, indent=2) + '\n')
PY
xcrun simctl list devices available --json > "$daypage_evidence/runner-simulators.json"
daypage_destination="$(python3 scripts/ci/select_simulator.py --input "$daypage_evidence/runner-simulators.json" --format destination)"
daypage_simulator="$(python3 scripts/ci/select_simulator.py --input "$daypage_evidence/runner-simulators.json" --format udid)"
printf '%s\n' "$daypage_destination" > "$daypage_evidence/destination.log"

probe_fixture_listener() {
  local daypage_listener_prefix="$1"
  daypage_listener=""
  if lsof -nP -iTCP:18763 -sTCP:LISTEN -Fp \
    > "$daypage_evidence/$daypage_listener_prefix-fields.log" 2> "$daypage_evidence/$daypage_listener_prefix-errors.log"; then
    daypage_listener_exit=0
    # Field output includes implicit file-descriptor records as well as PIDs.
    # Reject malformed records and keep every distinct process owner.
    daypage_listener="$(awk '
      /^p[1-9][0-9]*$/ { owners[substr($0, 2)] = 1; next }
      /^f[0-9]+$/ { next }
      { invalid = 1 }
      END { if (invalid) exit 1; for (owner in owners) print owner }
    ' "$daypage_evidence/$daypage_listener_prefix-fields.log" || true)"
  else
    daypage_listener_exit=$?
  fi
}

probe_fixture_health() {
  if curl --noproxy '*' --silent --fail --max-time 2 --max-filesize 1024 \
    --output "$daypage_native_root/fixture-health.body" \
    --write-out '%{http_code}' http://127.0.0.1:18763/health \
    > "$daypage_native_root/fixture-health.status" 2> "$daypage_native_root/fixture-health.error"; then
    daypage_health_exit=0
  else
    daypage_health_exit=$?
  fi
  if python3 - "$daypage_native_root" "$daypage_health_exit" <<'PY' > "$daypage_evidence/fixture-health.log"
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
body_path, status_path, error_path = (root / ('fixture-health.' + suffix) for suffix in ('body', 'status', 'error'))
result = {'curlExit': int(sys.argv[2]), 'httpCode': None, 'expectedMarkerMatches': False}
try:
    with body_path.open('rb') as response:
        body = response.read(1025)
    with status_path.open('rb') as response:
        status = response.read(4).decode('ascii', errors='replace')
    result.update({'httpCode': status if re.fullmatch(r'[0-9]{3}', status) else None,
        'bodyBytesRead': len(body), 'bodyTruncated': len(body) > 1024,
        'expectedMarkerMatches': body == b'GET-326-local-fixture'})
except OSError as error:
    result['probeFileError'] = error.errno
finally:
    for path in (body_path, status_path, error_path):
        path.unlink(missing_ok=True)
result['healthVerified'] = result['curlExit'] == 0 and result['httpCode'] == '200' and result['expectedMarkerMatches']
print(json.dumps(result))
raise SystemExit(0 if result['healthVerified'] else 1)
PY
  then
    daypage_health_matches=true
  else
    daypage_health_matches=false
  fi
}

# Own the fixture process; never borrow an existing service on this port.
python3 -u scripts/qa/local_notebook_ai_fixture.py > "$daypage_evidence/fixture.log" 2>&1 &
daypage_fixture_pid=$!
daypage_fixture_ready=false
for daypage_probe in {1..30}; do
  if ! kill -0 "$daypage_fixture_pid" 2>/dev/null; then
    echo "The task-owned loopback fixture could not start." >&2
    exit 1
  fi
  probe_fixture_listener fixture-listener-before-health
  daypage_before_listener="$daypage_listener"
  daypage_before_exit="$daypage_listener_exit"
  printf 'attempt=%s phase=before-health fields_exit=%s listener=%q\n' "$daypage_probe" "$daypage_before_exit" "$daypage_before_listener" \
    >> "$daypage_evidence/fixture-listener-probes.log"
  # Always sample HTTP, even when the initial owner lookup is empty. A first
  # visible owner after GET is diagnostic only; the next round must reverify.
  probe_fixture_health
  probe_fixture_listener fixture-listener
  printf 'attempt=%s phase=after-health fields_exit=%s listener=%q health_exit=%s health_verified=%s\n' \
    "$daypage_probe" "$daypage_listener_exit" "$daypage_listener" "$daypage_health_exit" "$daypage_health_matches" \
    >> "$daypage_evidence/fixture-listener-probes.log"
  if [[ "$daypage_before_exit" == 0 && "$daypage_listener_exit" == 0 && \
    "$daypage_before_listener" == "$daypage_fixture_pid" && "$daypage_listener" == "$daypage_fixture_pid" && \
    "$daypage_health_matches" == true ]]; then
    # Compare the old terse lookup in this same successful probe. It is only
    # diagnostic; it cannot replace the exact machine-field ownership check.
    if lsof -nP -iTCP:18763 -sTCP:LISTEN -t \
      > "$daypage_evidence/fixture-listener-terse.log" 2> "$daypage_evidence/fixture-listener-terse-errors.log"; then
      daypage_terse_exit=0
    else
      daypage_terse_exit=$?
    fi
    printf 'terse_exit=%s\n' "$daypage_terse_exit" >> "$daypage_evidence/fixture-listener-probes.log"
    printf 'accepted_attempt=%s\n' "$daypage_probe" >> "$daypage_evidence/fixture-listener-probes.log"
    daypage_fixture_ready=true
    break
  fi
  sleep 1
done
if [[ "$daypage_fixture_ready" != true ]]; then
  # Preserve process metadata alongside the final round's independent HTTP
  # result. Neither an earlier response nor a later owner can grant readiness.
  # Only process metadata and a bounded health summary enter evidence. The
  # unknown listener's headers, response body and curl errors are not uploaded.
  {
    printf 'fixture_pid=%s\nlast_listener=%s\n' "$daypage_fixture_pid" "$daypage_listener"
    command -v python3 || true
    command -v lsof || true
    python3 -c 'import sys; print("python_executable=" + sys.executable); print(sys.version)' || true
    ps -p "$daypage_fixture_pid" -o pid=,ppid=,comm= || true
    daypage_fixture_children="$(pgrep -P "$daypage_fixture_pid" 2>/dev/null || true)"
    for daypage_fixture_child in $daypage_fixture_children; do
      ps -p "$daypage_fixture_child" -o pid=,ppid=,comm= || true
    done
    if lsof -nP -iTCP:18763 -sTCP:LISTEN > "$daypage_evidence/fixture-listeners.log" 2>&1; then
      printf 'listener_exit=0\n'
    else
      printf 'listener_exit=%s\n' "$?"
    fi
    printf 'health_exit=%s\n' "$daypage_health_exit"
  } > "$daypage_evidence/fixture-readiness.log" 2>&1
  echo "The owned loopback fixture did not become ready." >&2
  exit 1
fi

daypage_project=DayPageLocal/DayPageLocal.xcodeproj
daypage_common=(-project "$daypage_project" -scheme DayPage -configuration Debug
  -destination "$daypage_destination" -jobs 2 -parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1)
daypage_negative="$daypage_native_root/NegativeDerivedData"
# The negative receipt is finalized before rebuilding with signing enabled.
# Reuse compiled sources/macros; Xcode must regenerate and verify the signed
# executable's actual entitlements below, then run every positive UI journey.
daypage_signed="$daypage_negative"
daypage_ui_suite="${DAYPAGE_NATIVE_UI_SUITE:-full}"
case "$daypage_ui_suite" in
  full|card_tools_speech|diary_navigation) ;;
  *) echo "Unknown native UI suite." >&2; exit 2 ;;
esac
daypage_negative_exit=0
daypage_negative_export_exit=0
daypage_negative_summary_exit=0
daypage_negative_receipt_exit=0

# First prove the genuine unavailable-Keychain UI; a positive branch is not
# accepted as negative evidence merely because XCTest itself returned success.
if [[ "$daypage_ui_suite" != diary_navigation ]]; then
run_logged "$daypage_evidence/negative-build.log" xcodebuild build-for-testing \
  "${daypage_common[@]}" -derivedDataPath "$daypage_negative" CODE_SIGNING_ALLOWED=NO
fi
# Start only this disposable runner's selected device and wait for SpringBoard
# readiness before asking XCTest to launch the unsigned app for the first time.
run_logged "$daypage_evidence/simulator-boot.log" python3 - "$daypage_simulator" <<'PY'
import subprocess, sys
subprocess.run(['xcrun', 'simctl', 'bootstatus', sys.argv[1], '-b'], check=True, timeout=180)
PY
if [[ "$daypage_ui_suite" != diary_navigation ]]; then
run_logged "$daypage_evidence/negative-ui.log" xcodebuild test-without-building \
  "${daypage_common[@]}" -derivedDataPath "$daypage_negative" CODE_SIGNING_ALLOWED=NO \
  -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testAISetupKeepsQuestionAndEmptyNotebookExplainsScope \
  -only-testing:DayPageLocalUITests/CardToolsSpeechUITests/testAnonymousSpeechWorksWithoutKeychain \
  -resultBundlePath "$daypage_evidence/negative-keychain.xcresult" || daypage_negative_exit=$?
run_logged "$daypage_evidence/negative-export.log" xcrun xcresulttool export attachments \
  --path "$daypage_evidence/negative-keychain.xcresult" --output-path "$daypage_evidence/negative-attachments" || daypage_negative_export_exit=$?
run_logged "$daypage_evidence/negative-summary.log" xcrun xcresulttool get test-results summary \
  --path "$daypage_evidence/negative-keychain.xcresult" --compact || daypage_negative_summary_exit=$?
# Preserve unsigned evidence before re-signing, but collect the independent
# signed journeys too. Any unsigned failure still denies final acceptance.
if ((daypage_negative_exit == 0 && daypage_negative_export_exit == 0 && daypage_negative_summary_exit == 0)); then
run_logged "$daypage_evidence/negative-receipt.log" python3 - "$daypage_evidence" <<'PY' || daypage_negative_receipt_exit=$?
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
summary = json.loads((root / 'negative-summary.log').read_text())
assert summary['result'] == 'Passed' and summary['failedTests'] == 0 and summary['skippedTests'] == 0 and summary['passedTests'] == 2 and summary['totalTestCount'] == 2
records = json.loads((root / 'negative-attachments/manifest.json').read_text())
assert any('ai-key-unavailable-inline' in attachment.get('suggestedHumanReadableName', '')
           for record in records for attachment in record.get('attachments', [])), 'The denied-Keychain recovery branch did not execute'
assert any('speech-anonymous-no-keychain' in attachment.get('suggestedHumanReadableName', '')
           for record in records for attachment in record.get('attachments', [])), 'Anonymous speech did not execute without Keychain access'
(root / 'negative-receipt.json').write_text(json.dumps({'verified': True, 'tests': summary,
    'requiredAttachment': 'ai-key-unavailable-inline',
    'anonymousSpeechAttachment': 'speech-anonymous-no-keychain'}, indent=2) + '\n')
PY
fi
shasum -a 256 "$daypage_negative/Build/Products/Debug-iphonesimulator/DayPage.app/DayPage" \
  > "$daypage_evidence/negative-executable.sha256"
fi

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
daypage_test_selection=()
case "${DAYPAGE_NATIVE_UI_SUITE:-full}" in
  full) ;;
  card_tools_speech)
    daypage_test_selection=(-only-testing:DayPageLocalUITests/CardToolsSpeechUITests
      -only-testing:DayPageLocalUITests/ChatExperienceUITests)
    ;;
  diary_navigation)
    daypage_test_selection=(-only-testing:DayPageLocalUITests/DiaryUITests
      -only-testing:DayPageLocalUITests/CalendarUITests
      -only-testing:DayPageLocalUITests/LocalNotebookUITests
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testArchiveIsBrowseAndSearchReturnsToItsOrigin
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testNoSearchMatchesHasClearRecovery
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testLargeArchiveFindsOlderNotesWithoutLeakingItsSearchFilter
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testChineseArchiveCalendarAndShareUseTheSameDesignLanguage
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testCardHeaderContainsFullDateAndMenuAboveTheReadingSurface
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testChineseCardHeaderAtLargeTextInDarkMode
      -only-testing:DayPageLocalUITests/LaunchExperienceUITests/testCaptureFromHistoricalDateReturnsToTheSavedNoteToday)
    ;;
  *) echo "Unknown native UI suite." >&2; exit 2 ;;
esac
run_logged "$daypage_evidence/signed-ui.log" xcodebuild test-without-building \
  "${daypage_common[@]}" -derivedDataPath "$daypage_signed" "${daypage_signing[@]}" \
  ${daypage_test_selection[@]+"${daypage_test_selection[@]}"} \
  -resultBundlePath "$daypage_evidence/signed-full-ui.xcresult" || daypage_signed_exit=$?
daypage_signed_summary_exit=0
run_logged "$daypage_evidence/signed-summary.log" xcrun xcresulttool get test-results summary \
  --path "$daypage_evidence/signed-full-ui.xcresult" --compact || daypage_signed_summary_exit=$?
daypage_signed_export_exit=0
run_logged "$daypage_evidence/signed-export.log" xcrun xcresulttool export attachments \
  --path "$daypage_evidence/signed-full-ui.xcresult" --output-path "$daypage_evidence/signed-attachments" || daypage_signed_export_exit=$?
if ((daypage_negative_exit != 0)); then exit "$daypage_negative_exit"; fi
if ((daypage_negative_export_exit != 0)); then exit "$daypage_negative_export_exit"; fi
if ((daypage_negative_summary_exit != 0)); then exit "$daypage_negative_summary_exit"; fi
if ((daypage_negative_receipt_exit != 0)); then exit "$daypage_negative_receipt_exit"; fi
if ((daypage_signed_exit != 0)); then exit "$daypage_signed_exit"; fi
if ((daypage_signed_summary_exit != 0)); then exit "$daypage_signed_summary_exit"; fi
if ((daypage_signed_export_exit != 0)); then exit "$daypage_signed_export_exit"; fi
python3 - "$daypage_evidence" <<'PY'
import json, os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
summary = json.loads((root / 'signed-summary.log').read_text())
assert summary['result'] == 'Passed' and summary['failedTests'] == 0 and summary['skippedTests'] == 0, 'Every native UI test must execute and pass'
suite = os.environ.get('DAYPAGE_NATIVE_UI_SUITE', 'full')
files = list(pathlib.Path('DayPageLocalUITests').glob('*.swift'))
if suite == 'card_tools_speech':
    files = [p for p in files if p.stem in {'CardToolsSpeechUITests', 'ChatExperienceUITests'}]
if suite == 'diary_navigation':
    files = [p for p in files if p.stem in {'DiaryUITests', 'CalendarUITests', 'LocalNotebookUITests'}]
    selected = {'testArchiveIsBrowseAndSearchReturnsToItsOrigin', 'testNoSearchMatchesHasClearRecovery',
                'testLargeArchiveFindsOlderNotesWithoutLeakingItsSearchFilter',
                'testChineseArchiveCalendarAndShareUseTheSameDesignLanguage',
                'testCardHeaderContainsFullDateAndMenuAboveTheReadingSurface',
                'testChineseCardHeaderAtLargeTextInDarkMode',
                'testCaptureFromHistoricalDateReturnsToTheSavedNoteToday'}
    declared = set(re.findall(r'^[ \t]+func (test\w+)\(',
        pathlib.Path('DayPageLocalUITests/LaunchExperienceUITests.swift').read_text(), re.M))
    assert selected <= declared, 'A required diary integration test is missing'
    expected = len(selected) + sum(len(re.findall(r'^[ \t]+func test\w+\(', p.read_text(), re.M)) for p in files)
    assert expected >= 28 and summary['totalTestCount'] == expected, 'Every selected diary and integration test must execute'
else:
    expected = sum(len(re.findall(r'^[ \t]+func test\w+\(', p.read_text(), re.M)) for p in files)
    assert expected >= 11, 'The selected native suite is unexpectedly empty'
assert summary['passedTests'] == summary['totalTestCount'] and summary['passedTests'] >= expected, 'The complete selected UI suite did not execute'
records = json.loads((root / 'signed-attachments/manifest.json').read_text())
names = [attachment.get('suggestedHumanReadableName', '') for record in records
         for attachment in record.get('attachments', [])]
required_chat = ['chat-dedicated-model-page', 'chat-compact-composer', 'chat-saved-history',
                 'chat-character-library', 'chat-streamed-markdown', 'chat-accessibility-size'] if suite != 'diary_navigation' else []
assert all(any(required in name for name in names) for required in required_chat), 'A required chat journey did not produce its native evidence'
required_diary = ['diary-home-today', 'diary-earlier-days', 'diary-sidebar-en',
                  'diary-sidebar-zh-normal', 'diary-sidebar-zh-dark-large-text',
                  'diary-month-position', 'diary-rediscovered-note'] if suite in {'full', 'diary_navigation'} else []
assert all(any(required in name for name in names) for required in required_diary), 'A required diary journey did not produce its native evidence'
negative = {'executed': False, 'reason': 'Outside diary_navigation scope; full retains unsigned recovery checks'} if suite == 'diary_navigation' else json.loads((root / 'negative-receipt.json').read_text())
receipt = {'passed': True, 'suite': suite, 'expectedMinimumTests': expected, 'source': json.loads((root / 'provenance.json').read_text()),
           'negative': negative, 'positive': summary,
           'requiredChatAttachments': required_chat, 'requiredDiaryAttachments': required_diary}
(root / 'native-acceptance.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
echo "Verified the selected signed native UI suite; see the receipt for its explicit recovery scope."
