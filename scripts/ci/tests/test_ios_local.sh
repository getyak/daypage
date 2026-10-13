#!/usr/bin/env bash
#
# Behavioral tests for scripts/ci/ios-local.sh using a fake shared session
# helper, fake xcrun, and fake xcodebuild. No real simulator is booted or
# selected and no real Xcode build runs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/daypage-ios-local.XXXXXX")"
trap 'rm -rf "${TMP:?}"' EXIT

FAKE_REPO="${TMP}/repo"
FAKE_BIN="${TMP}/bin"
LOG_DIR="${TMP}/logs"
HOME_DIR="${TMP}/home"
mkdir -p "${FAKE_REPO}/scripts/ci" "${FAKE_REPO}/DayPage/Config" "${FAKE_BIN}" "${LOG_DIR}" "${HOME_DIR}"

cp "${REPO_ROOT}/scripts/ci/ios-local.sh" "${FAKE_REPO}/scripts/ci/ios-local.sh"
cp "${REPO_ROOT}/scripts/ci/select_simulator.py" "${FAKE_REPO}/scripts/ci/select_simulator.py"
cp "${REPO_ROOT}/scripts/ci/write_placeholder_secrets.sh" "${FAKE_REPO}/scripts/ci/write_placeholder_secrets.sh"
printf '// pre-existing test placeholder\n' > "${FAKE_REPO}/DayPage/Config/GeneratedSecrets.swift"

ORIGINAL_PATH="${PATH}"
WRAPPER_STATUS=0

reset_logs() {
    : > "${LOG_DIR}/helper.log"
    : > "${LOG_DIR}/xcrun.log"
    : > "${LOG_DIR}/xcodebuild.log"
    : > "${TMP}/stdout"
    : > "${TMP}/stderr"
}

make_fakes() {
    cat > "${FAKE_BIN}/dev-ios-session" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_LOG_DIR}/helper.log"
case "${1:-}" in
    is-owner)
        [[ "${FAKE_IN_SESSION:-0}" == "1" ]] && exit 0 || exit 1
        ;;
    run)
        shift
        [[ "${1:-}" == "--" ]] && shift
        export FAKE_IN_SESSION=1
        export IOS_SIMULATOR_ID="${FAKE_SIMULATOR_ID:-IPHONE-SESSION-UDID}"
        exec "$@"
        ;;
    *)
        exit 2
        ;;
esac
HELPER
    chmod +x "${FAKE_BIN}/dev-ios-session"

    cat > "${FAKE_BIN}/xcrun" <<'XCRUN'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do printf '%s\n' "${arg}" >> "${FAKE_LOG_DIR}/xcrun.log"; done
printf -- '----\n' >> "${FAKE_LOG_DIR}/xcrun.log"
if [[ "${1:-}" == "simctl" && "${2:-}" == "list" ]]; then
    cat <<'JSON'
{"devices":{
 "com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
   {"name":"iPhone SE (3rd generation)","udid":"SE-UDID","isAvailable":true,"state":"Shutdown"},
   {"name":"iPhone 17 Pro","udid":"IPHONE-17-UDID","isAvailable":true,"state":"Shutdown"},
   {"name":"iPhone 16 Pro","udid":"IPHONE-SESSION-UDID","isAvailable":true,"state":"Shutdown"},
   {"name":"iPad Pro 13-inch (M4)","udid":"IPAD-UDID","isAvailable":true,"state":"Booted"}
 ],
 "com.apple.CoreSimulator.SimRuntime.iOS-18-5":[
   {"name":"iPhone 16","udid":"IPHONE-16-UDID","isAvailable":true,"state":"Shutdown"}
 ]}}
JSON
    exit 0
fi
exit 1
XCRUN
    chmod +x "${FAKE_BIN}/xcrun"

    cat > "${FAKE_BIN}/xcodebuild" <<'XCODEBUILD'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do printf '%s\n' "${arg}" >> "${FAKE_LOG_DIR}/xcodebuild.log"; done
printf -- '----\n' >> "${FAKE_LOG_DIR}/xcodebuild.log"
exit "${FAKE_XCODEBUILD_EXIT:-0}"
XCODEBUILD
    chmod +x "${FAKE_BIN}/xcodebuild"

    cat > "${FAKE_BIN}/uname" <<'UNAME'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' "${FAKE_UNAME:-Linux}" ;;
    *) printf '%s\n' "${FAKE_UNAME:-Linux}" ;;
esac
UNAME
    chmod +x "${FAKE_BIN}/uname"
}

run_wrapper() {
    local action="$1"
    shift
    reset_logs
    set +e
    env -i \
        PATH="${FAKE_BIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="${HOME_DIR}" \
        FAKE_LOG_DIR="${LOG_DIR}" \
        DEV_IOS_SESSION_BIN="${TEST_DEV_IOS_SESSION_BIN:-}" \
        FAKE_SIMULATOR_ID="${TEST_FAKE_SIMULATOR_ID:-IPHONE-SESSION-UDID}" \
        FAKE_IN_SESSION="${TEST_FAKE_IN_SESSION:-0}" \
        FAKE_XCODEBUILD_EXIT="${TEST_XCODEBUILD_EXIT:-0}" \
        CI="${TEST_CI:-}" \
        DEV_IOS_SESSION_PID="${TEST_DEV_IOS_SESSION_PID:-}" \
        DEV_IOS_PROFILE="${TEST_DEV_IOS_PROFILE:-}" \
        DEV_IOS_REASON="${TEST_DEV_IOS_REASON:-}" \
        FAKE_UNAME="${TEST_FAKE_UNAME:-Linux}" \
        IOS_SIMULATOR_ID="${TEST_IOS_SIMULATOR_ID:-}" \
        IOS_ONLY_TESTING="${TEST_IOS_ONLY_TESTING:-}" \
        IOS_RESULT_BUNDLE_PATH="${TEST_IOS_RESULT_BUNDLE_PATH:-}" \
        DERIVED_DATA="${TEST_DERIVED_DATA:-build/DD}" \
        PYTHON="$(command -v python3)" \
        bash "${FAKE_REPO}/scripts/ci/ios-local.sh" "${action}" "$@" >"${TMP}/stdout" 2>"${TMP}/stderr"
    WRAPPER_STATUS=$?
    set -e
    return 0
}

fail() {
    echo "FAIL: $*" >&2
    echo "--- status: ${WRAPPER_STATUS}" >&2
    echo "--- stdout ---" >&2
    cat "${TMP}/stdout" >&2 || true
    echo "--- stderr ---" >&2
    cat "${TMP}/stderr" >&2 || true
    echo "--- xcodebuild.log ---" >&2
    cat "${LOG_DIR}/xcodebuild.log" >&2 || true
    echo "--- helper.log ---" >&2
    cat "${LOG_DIR}/helper.log" >&2 || true
    exit 1
}

assert_status() {
    [[ "${WRAPPER_STATUS}" -eq "$1" ]] || fail "expected status $1, got ${WRAPPER_STATUS}"
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
    if grep -Fq -- "$2" "$1"; then
        fail "did not expect '$2' in $1"
    fi
}

assert_line() {
    grep -Fxq -- "$2" "$1" || fail "expected line '$2' in $1"
}

assert_log_empty() {
    [[ ! -s "$1" ]] || fail "expected $1 to be empty"
}

make_fakes

# ---------------------------------------------------------------------------
# 1. Helper present and not owner: wrapper re-enters through `run`, then uses
#    the helper-provided explicit UDID and never boots a simulator.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN="${FAKE_BIN}/dev-ios-session"
TEST_FAKE_IN_SESSION=0
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_contains "${LOG_DIR}/helper.log" "is-owner"
assert_contains "${LOG_DIR}/helper.log" "run -- bash"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-SESSION-UDID"
assert_not_contains "${LOG_DIR}/xcodebuild.log" "generic/platform"
assert_contains "${LOG_DIR}/xcodebuild.log" "-parallel-testing-enabled"
assert_line "${LOG_DIR}/xcodebuild.log" "NO"
assert_contains "${LOG_DIR}/xcodebuild.log" "-maximum-concurrent-test-simulator-destinations"
assert_line "${LOG_DIR}/xcodebuild.log" "1"
assert_not_contains "${LOG_DIR}/xcrun.log" "boot"
assert_not_contains "${LOG_DIR}/xcodebuild.log" "-resultBundlePath"

# ---------------------------------------------------------------------------
# 2. No helper: select the newest numbered iPhone from simctl (SE and booted
#    iPad ignored), run once, and still never boot explicitly.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN=""
TEST_FAKE_IN_SESSION=0
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_contains "${LOG_DIR}/xcrun.log" "list"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-17-UDID"
assert_not_contains "${LOG_DIR}/xcodebuild.log" "id=SE-UDID"
assert_not_contains "${LOG_DIR}/xcodebuild.log" "id=IPAD-UDID"
assert_not_contains "${LOG_DIR}/xcrun.log" "boot"

# ---------------------------------------------------------------------------
# 3. CI=true must not depend on the helper even when it is installed.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN="${FAKE_BIN}/dev-ios-session"
TEST_CI="true"
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_log_empty "${LOG_DIR}/helper.log"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-17-UDID"

# ---------------------------------------------------------------------------
# 4. Mere session environment variables must not suppress nesting; `is-owner`
#    alone decides.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN="${FAKE_BIN}/dev-ios-session"
TEST_CI=""
TEST_FAKE_IN_SESSION=0
TEST_DEV_IOS_SESSION_PID="424242"
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_contains "${LOG_DIR}/helper.log" "run -- bash"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-SESSION-UDID"

# ---------------------------------------------------------------------------
# 5. Owner session without IOS_SIMULATOR_ID is rejected instead of guessing.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN="${FAKE_BIN}/dev-ios-session"
TEST_DEV_IOS_SESSION_PID=""
TEST_FAKE_IN_SESSION=1
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 1
assert_log_empty "${LOG_DIR}/xcodebuild.log"

# ---------------------------------------------------------------------------
# 6. Explicit UDID that is not present fails closed without running xcodebuild.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN=""
TEST_FAKE_IN_SESSION=0
TEST_IOS_SIMULATOR_ID="NOT-A-REAL-UDID"
run_wrapper check
[[ "${WRAPPER_STATUS}" -ne 0 ]] || fail "expected failure for unknown explicit UDID"
assert_log_empty "${LOG_DIR}/xcodebuild.log"

# ---------------------------------------------------------------------------
# 7. Explicit iPad requires the ipad profile; with it, the id is honored.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN=""
TEST_IOS_SIMULATOR_ID="IPAD-UDID"
TEST_DEV_IOS_PROFILE="ipad"
run_wrapper check
assert_status 0
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPAD-UDID"

TEST_DEV_IOS_PROFILE="primary"
run_wrapper check
[[ "${WRAPPER_STATUS}" -ne 0 ]] || fail "expected primary profile to reject explicit iPad"

# ---------------------------------------------------------------------------
# 8. build never selects or boots a simulator and uses generic destination.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN=""
TEST_DEV_IOS_PROFILE=""
TEST_IOS_SIMULATOR_ID=""
run_wrapper build
assert_status 0
assert_contains "${LOG_DIR}/xcodebuild.log" "generic/platform=iOS Simulator"
assert_contains "${LOG_DIR}/xcodebuild.log" "build"
assert_log_empty "${LOG_DIR}/xcrun.log"

# ---------------------------------------------------------------------------
# 9. build also wraps through the shared helper when it is present.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN="${FAKE_BIN}/dev-ios-session"
TEST_FAKE_IN_SESSION=0
run_wrapper build
assert_status 0
assert_contains "${LOG_DIR}/helper.log" "run -- bash"
assert_contains "${LOG_DIR}/xcodebuild.log" "generic/platform=iOS Simulator"
assert_log_empty "${LOG_DIR}/xcrun.log"

# ---------------------------------------------------------------------------
# 10. One explicit XCTest selector plus paths that contain spaces survive.
# ---------------------------------------------------------------------------
TEST_DEV_IOS_SESSION_BIN=""
TEST_FAKE_IN_SESSION=0
TEST_IOS_ONLY_TESTING="DayPageTests/FocusedTests/testExample"
TEST_IOS_RESULT_BUNDLE_PATH="/tmp/result bundle.xcresult"
TEST_DERIVED_DATA="/tmp/derived data"
run_wrapper check
assert_status 0
assert_contains "${LOG_DIR}/xcodebuild.log" "-only-testing:DayPageTests/FocusedTests/testExample"
assert_contains "${LOG_DIR}/xcodebuild.log" "/tmp/result bundle.xcresult"
assert_contains "${LOG_DIR}/xcodebuild.log" "/tmp/derived data"

# ---------------------------------------------------------------------------
# 11. Failure exit codes propagate for both actions.
# ---------------------------------------------------------------------------
TEST_IOS_ONLY_TESTING=""
TEST_IOS_RESULT_BUNDLE_PATH=""
TEST_DERIVED_DATA="build/DD"
TEST_XCODEBUILD_EXIT=7
run_wrapper check
assert_status 7

TEST_XCODEBUILD_EXIT=9
run_wrapper build
assert_status 9

# ---------------------------------------------------------------------------
# 12. Explicit DEV_IOS_SESSION_BIN must be executable; never fall back to the
#     implicit helper or run unguarded.
# ---------------------------------------------------------------------------
TEST_XCODEBUILD_EXIT=0
BROKEN_HELPER="${TMP}/broken-dev-ios-session"
printf '#!/usr/bin/env bash\nexit 0\n' > "${BROKEN_HELPER}"
chmod 600 "${BROKEN_HELPER}"
install_implicit_helper() {
    mkdir -p "${HOME_DIR}/.local/bin"
    cp "${FAKE_BIN}/dev-ios-session" "${HOME_DIR}/.local/bin/dev-ios-session"
    chmod +x "${HOME_DIR}/.local/bin/dev-ios-session"
}
remove_implicit_helper() {
    rm -rf "${HOME_DIR}/.local"
}
install_implicit_helper
TEST_DEV_IOS_SESSION_BIN="${BROKEN_HELPER}"
TEST_DEV_IOS_PROFILE=""
TEST_IOS_SIMULATOR_ID=""
TEST_FAKE_UNAME="Darwin"
run_wrapper check
assert_status 1
assert_log_empty "${LOG_DIR}/helper.log"
assert_log_empty "${LOG_DIR}/xcodebuild.log"
remove_implicit_helper

# ---------------------------------------------------------------------------
# 13. Implicit helper discovery requires Darwin.
# ---------------------------------------------------------------------------
install_implicit_helper
TEST_DEV_IOS_SESSION_BIN=""
TEST_FAKE_UNAME="Linux"
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_log_empty "${LOG_DIR}/helper.log"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-17-UDID"
remove_implicit_helper

# ---------------------------------------------------------------------------
# 14. On Darwin the implicit ~/.local/bin helper is used and wrapped.
# ---------------------------------------------------------------------------
install_implicit_helper
TEST_DEV_IOS_SESSION_BIN=""
TEST_FAKE_UNAME="Darwin"
TEST_FAKE_IN_SESSION=0
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_contains "${LOG_DIR}/helper.log" "is-owner"
assert_contains "${LOG_DIR}/helper.log" "run -- bash"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-SESSION-UDID"
remove_implicit_helper

# ---------------------------------------------------------------------------
# 15. CI=true is exempt from host helper dependency, including a broken
#     explicit helper.
# ---------------------------------------------------------------------------
install_implicit_helper
TEST_CI="true"
TEST_DEV_IOS_SESSION_BIN="${BROKEN_HELPER}"
TEST_FAKE_UNAME="Darwin"
TEST_IOS_SIMULATOR_ID=""
run_wrapper check
assert_status 0
assert_log_empty "${LOG_DIR}/helper.log"
assert_contains "${LOG_DIR}/xcodebuild.log" "id=IPHONE-17-UDID"
remove_implicit_helper
TEST_CI=""

# ---------------------------------------------------------------------------
# 16. The Makefile exports gate inputs as process environment data. Shell
#     metacharacters in DEV_IOS_REASON/PROJECT must arrive verbatim and never
#     execute as commands.
# ---------------------------------------------------------------------------
MAKE_DIR="${TMP}/maketest"
mkdir -p "${MAKE_DIR}"
MAKE_ENV_LOG="${TMP}/make_env.log"
MARKER_BASE="${TMP}/pwned"
rm -f "${MARKER_BASE}".*
cat > "${FAKE_BIN}/bash" <<'FAKEBASH'
#!/bin/bash
{
    printf 'DEV_IOS_REASON=<%s>\n' "${DEV_IOS_REASON-}"
    printf 'PROJECT=<%s>\n' "${PROJECT-}"
    printf 'SCHEME=<%s>\n' "${SCHEME-}"
    printf 'DERIVED_DATA=<%s>\n' "${DERIVED_DATA-}"
    printf 'PYTHON=<%s>\n' "${PYTHON-}"
    printf 'SIMULATOR_FALLBACK=<%s>\n' "${SIMULATOR_FALLBACK-}"
    printf 'DEV_IOS_PROFILE=<%s>\n' "${DEV_IOS_PROFILE-}"
    printf 'IOS_ONLY_TESTING=<%s>\n' "${IOS_ONLY_TESTING-}"
    printf 'IOS_RESULT_BUNDLE_PATH=<%s>\n' "${IOS_RESULT_BUNDLE_PATH-}"
} > "${MAKE_ENV_LOG}"
FAKEBASH
chmod +x "${FAKE_BIN}/bash"

REASON="bk\`touch ${MARKER_BASE}.1\` \$(touch ${MARKER_BASE}.2) \"dq\" 'sq' \${HOME}"
EXPECTED_REASON="${REASON}"
PROJECT_VALUE="Proj \$\$(touch ${MARKER_BASE}.3) \`touch ${MARKER_BASE}.4\` spaces"
EXPECTED_PROJECT="Proj \$(touch ${MARKER_BASE}.3) \`touch ${MARKER_BASE}.4\` spaces"
: > "${MAKE_ENV_LOG}"
set +e
env -i PATH="${FAKE_BIN}:${ORIGINAL_PATH}" HOME="${HOME_DIR}" MAKE_ENV_LOG="${MAKE_ENV_LOG}" \
    make -C "${MAKE_DIR}" -f "${REPO_ROOT}/Makefile" check-ios \
        "DEV_IOS_REASON=${REASON}" \
        "PROJECT=${PROJECT_VALUE}" \
        >"${TMP}/make_stdout" 2>"${TMP}/make_stderr"
MAKE_STATUS=$?
set -e
[[ "${MAKE_STATUS}" -eq 0 ]] || fail "make check-ios exited ${MAKE_STATUS}"
assert_line "${MAKE_ENV_LOG}" "DEV_IOS_REASON=<${EXPECTED_REASON}>"
assert_line "${MAKE_ENV_LOG}" "PROJECT=<${EXPECTED_PROJECT}>"
assert_line "${MAKE_ENV_LOG}" "SIMULATOR_FALLBACK=<iPhone 16>"
env -i PATH="${FAKE_BIN}:${ORIGINAL_PATH}" HOME="${HOME_DIR}" MAKE_ENV_LOG="${MAKE_ENV_LOG}" \
    DEV_IOS_REASON="${REASON}" \
    make -C "${MAKE_DIR}" -f "${REPO_ROOT}/Makefile" check-ios \
        >"${TMP}/make_env_stdout" 2>"${TMP}/make_env_stderr"
assert_line "${MAKE_ENV_LOG}" "DEV_IOS_REASON=<${EXPECTED_REASON}>"
for suffix in 1 2 3 4; do
    [[ ! -e "${MARKER_BASE}.${suffix}" ]] || fail "shell metacharacter executed: ${MARKER_BASE}.${suffix}"
done
rm -f "${FAKE_BIN}/bash"

echo "PASS: ios-local.sh selector/session wrapper behavior"
