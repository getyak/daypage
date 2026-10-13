#!/usr/bin/env bash
#
# ios-local.sh — shared local iOS gate for `make check-ios` / `make build-ios`.
#
# On a macOS host that has the shared device-session helper installed (either
# `$DEV_IOS_SESSION_BIN` or `~/.local/bin/dev-ios-session`), heavyweight work is
# serialized through `dev-ios-session run`. A nested invocation detects the
# existing session with `dev-ios-session is-owner` and runs the action directly
# instead of nesting another session. The decision is made by asking `is-owner`,
# never by the mere presence of session environment variables.
#
# Without the helper (CI, other hosts, CI=true) the wrapper runs the action
# with no external dependency. `check` runs the scheme's test action with a
# single worker against one selected Simulator; `build` builds for
# `generic/platform=iOS Simulator` without selecting or booting a device.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: ios-local.sh <check|build>

  check   Run the scheme's test action on one selected Simulator with a single worker.
  build   Build for generic/platform=iOS Simulator without selecting a device.

Environment (all optional):
  PROJECT / SCHEME / DERIVED_DATA / PYTHON   Xcode + toolchain overrides
  SIMULATOR_FALLBACK                         Destination name when no iPhone is listed
  IOS_ONLY_TESTING                           Single XCTest selector to run
  IOS_RESULT_BUNDLE_PATH                     xcresult bundle output path
  IOS_SIMULATOR_ID                           Explicit Simulator UDID to use
  DEV_IOS_PROFILE / DEV_IOS_REASON           Shared session profile + audit reason
EOF
}

if (($# == 0)); then
    usage
    exit 2
fi

ACTION="$1"
shift
case "${ACTION}" in
    check | build) ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/../.." && pwd)"
cd "${REPO_ROOT}"

PROJECT="${PROJECT:-DayPage.xcodeproj}"
SCHEME="${SCHEME:-DayPage}"
DERIVED_DATA="${DERIVED_DATA:-build/DD}"
PYTHON="${PYTHON:-python3}"
SIMULATOR_FALLBACK="${SIMULATOR_FALLBACK:-iPhone 16}"
IOS_ONLY_TESTING="${IOS_ONLY_TESTING:-}"
IOS_RESULT_BUNDLE_PATH="${IOS_RESULT_BUNDLE_PATH:-}"
DEV_IOS_PROFILE="${DEV_IOS_PROFILE:-primary}"

# --- shared device session helper -------------------------------------------
# CI is exempt from any host helper dependency. An explicit DEV_IOS_SESSION_BIN
# must be usable or the gate fails closed; implicit discovery only happens on
# Darwin.
SESSION_HELPER=""
if [[ "${CI:-}" != "true" && "${CI:-}" != "1" ]]; then
    if [[ -n "${DEV_IOS_SESSION_BIN:-}" ]]; then
        if [[ ! -x "${DEV_IOS_SESSION_BIN}" ]]; then
            echo "ios-local.sh: DEV_IOS_SESSION_BIN is set but not executable: ${DEV_IOS_SESSION_BIN}" >&2
            exit 1
        fi
        SESSION_HELPER="${DEV_IOS_SESSION_BIN}"
    elif [[ "$(uname -s 2>/dev/null)" == "Darwin" \
        && -n "${HOME:-}" \
        && -x "${HOME}/.local/bin/dev-ios-session" ]]; then
        SESSION_HELPER="${HOME}/.local/bin/dev-ios-session"
    fi
fi

IN_SESSION=0
if [[ -n "${SESSION_HELPER}" ]]; then
    if "${SESSION_HELPER}" is-owner >/dev/null 2>&1; then
        IN_SESSION=1
    elif [[ "${_IOS_LOCAL_SESSION_LAUNCHED:-}" == "1" ]]; then
        echo "ios-local.sh: session helper did not establish ownership; refusing to run unsynchronized" >&2
        exit 1
    else
        export _IOS_LOCAL_SESSION_LAUNCHED=1
        exec "${SESSION_HELPER}" run -- bash "${SCRIPT_PATH}" "${ACTION}" "$@"
    fi
fi

# An owned check session must advertise the selected device; otherwise the lock
# and the test destination could disagree. Builds are device-agnostic.
if [[ "${ACTION}" == "check" ]] && ((IN_SESSION)) && [[ -z "${IOS_SIMULATOR_ID:-}" ]]; then
    echo "ios-local.sh: session is active but IOS_SIMULATOR_ID is unset" >&2
    exit 1
fi

ensure_secrets() {
    if [[ ! -f DayPage/Config/GeneratedSecrets.swift ]]; then
        bash scripts/ci/write_placeholder_secrets.sh
    fi
}

resolve_destination() {
    local requested="${IOS_SIMULATOR_ID:-}"
    if [[ -n "${requested}" ]]; then
        xcrun simctl list devices available --json 2>/dev/null \
            | "${PYTHON}" scripts/ci/select_simulator.py \
                --format destination --udid "${requested}" --profile "${DEV_IOS_PROFILE}"
    else
        xcrun simctl list devices available --json 2>/dev/null \
            | "${PYTHON}" scripts/ci/select_simulator.py \
                --format destination --fallback-name "${SIMULATOR_FALLBACK}"
    fi
}

run_check() {
    ensure_secrets
    local destination
    destination="$(resolve_destination)"
    echo "Using simulator: ${destination}"

    local -a command=(
        xcodebuild test
        -project "${PROJECT}"
        -scheme "${SCHEME}"
        -destination "${destination}"
        -configuration Debug
        CODE_SIGNING_ALLOWED=NO
        -derivedDataPath "${DERIVED_DATA}"
        -parallel-testing-enabled NO
        -maximum-concurrent-test-simulator-destinations 1
    )
    if [[ -n "${IOS_ONLY_TESTING}" ]]; then
        command+=("-only-testing:${IOS_ONLY_TESTING}")
    fi
    if [[ -n "${IOS_RESULT_BUNDLE_PATH}" ]]; then
        command+=(-resultBundlePath "${IOS_RESULT_BUNDLE_PATH}")
    fi
    command+=("$@")
    "${command[@]}"
}

run_build() {
    ensure_secrets
    local -a command=(
        xcodebuild
        -project "${PROJECT}"
        -scheme "${SCHEME}"
        -destination "generic/platform=iOS Simulator"
        CODE_SIGNING_ALLOWED=NO
        COMPILER_CONTENT_PROTECTION=NO
        -derivedDataPath "${DERIVED_DATA}"
        build
    )
    command+=("$@")
    "${command[@]}"
}

case "${ACTION}" in
    check) run_check "$@" ;;
    build) run_build "$@" ;;
esac
