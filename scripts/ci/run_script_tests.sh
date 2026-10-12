#!/usr/bin/env bash
#
# Run standalone Swift, Python and shell regressions without failing fast. Pass
# one or more paths to select a subset, or --list to print the discovered set.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
LIST_ONLY=0
declare -a TEST_FILES=()

while (($#)); do
    case "$1" in
        --list)
            LIST_ONLY=1
            ;;
        --)
            shift
            TEST_FILES+=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *)
            TEST_FILES+=("$1")
            ;;
    esac
    shift
done

if ((${#TEST_FILES[@]} == 0)); then
    while IFS= read -r path; do
        TEST_FILES+=("$path")
    done < <({
        find "${REPO_ROOT}/scripts/tests" -maxdepth 1 -type f \
            \( -name 'test_*.swift' -o -name 'test_*.sh' -o -name 'test_*.py' \)
        find "${REPO_ROOT}/scripts/ci/tests" -maxdepth 1 -type f -name 'test_*.sh'
        find "${REPO_ROOT}/tests" -maxdepth 1 -type f -name 'test_*.py'
    } 2>/dev/null | LC_ALL=C sort)
fi

if ((${#TEST_FILES[@]} == 0)); then
    echo "No standalone script tests found." >&2
    exit 1
fi

if ((LIST_ONLY)); then
    printf '%s\n' "${TEST_FILES[@]}"
    exit 0
fi

resolve_swift_command() {
    if [[ -n "${SWIFT_COMMAND+x}" ]]; then
        return 0
    fi
    if [[ -n "${DAYPAGE_SWIFT_BIN:-}" ]]; then
        SWIFT_COMMAND=("${DAYPAGE_SWIFT_BIN}")
    elif command -v xcrun >/dev/null 2>&1; then
        SWIFT_COMMAND=(xcrun swift)
    elif command -v swift >/dev/null 2>&1; then
        SWIFT_COMMAND=(swift)
    else
        return 127
    fi
    return 0
}

overall=0
for file in "${TEST_FILES[@]}"; do
    if [[ "${file}" != /* ]]; then
        file="${REPO_ROOT}/${file}"
    fi
    case "${file}" in
        *.swift)
            if ! resolve_swift_command; then
                echo "Neither xcrun nor swift is available for ${file#${REPO_ROOT}/}." >&2
                overall=1
                continue
            fi
            TEST_COMMAND=("${SWIFT_COMMAND[@]}" "${file}")
            ;;
        *.sh) TEST_COMMAND=(bash "${file}") ;;
        *.py) TEST_COMMAND=("${PYTHON}" "${file}") ;;
        *)
            echo "Unsupported standalone test type: ${file}" >&2
            overall=1
            continue
            ;;
    esac
    echo "::group::Standalone script test: ${file#${REPO_ROOT}/}"
    if "${TEST_COMMAND[@]}"; then
        echo "PASS: ${file#${REPO_ROOT}/}"
    else
        status=$?
        echo "FAIL: ${file#${REPO_ROOT}/} (exit ${status})" >&2
        overall=1
    fi
    echo "::endgroup::"
done

exit "${overall}"
