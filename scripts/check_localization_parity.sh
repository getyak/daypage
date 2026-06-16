#!/usr/bin/env bash
# check_localization_parity.sh
#
# Verifies that en.lproj and zh-Hans.lproj Localizable.strings declare the
# SAME set of keys. A key present in one locale but missing in the other makes
# the missing locale fall back to rendering the raw key string in the UI
# (e.g. the timeline showed `today.section.earlier` instead of "EARLIER").
#
# Exit codes:
#   0 — both locales declare an identical key set
#   1 — drift detected (missing keys are printed per side)
#   2 — a strings file is missing or unreadable
#
# Usage: scripts/check_localization_parity.sh
# Run from the repository root (the script resolves paths relative to itself).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EN="$REPO_ROOT/DayPage/Resources/en.lproj/Localizable.strings"
ZH="$REPO_ROOT/DayPage/Resources/zh-Hans.lproj/Localizable.strings"

for f in "$EN" "$ZH"; do
  if [ ! -r "$f" ]; then
    echo "::error::Localizable.strings not found or unreadable: $f"
    exit 2
  fi
done

# Extract the quoted key at the start of each `"key" = "value";` line.
# Matches the same convention the rest of the repo uses (see ci.yml secrets-audit).
extract_keys() {
  grep -oE '^"[^"]+"' "$1" | sort -u
}

EN_KEYS="$(extract_keys "$EN")"
ZH_KEYS="$(extract_keys "$ZH")"

MISSING_IN_EN="$(comm -13 <(echo "$EN_KEYS") <(echo "$ZH_KEYS"))"
MISSING_IN_ZH="$(comm -23 <(echo "$EN_KEYS") <(echo "$ZH_KEYS"))"

FAIL=0

if [ -n "$MISSING_IN_EN" ]; then
  echo "::error::Keys present in zh-Hans but MISSING in en.lproj (English UI will show raw keys):"
  echo "$MISSING_IN_EN" | sed 's/^/  - /'
  FAIL=1
fi

if [ -n "$MISSING_IN_ZH" ]; then
  echo "::error::Keys present in en but MISSING in zh-Hans.lproj (Chinese UI will show raw keys):"
  echo "$MISSING_IN_ZH" | sed 's/^/  - /'
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Localization parity check FAILED. Add the missing keys to reach parity."
  exit 1
fi

EN_COUNT="$(echo "$EN_KEYS" | grep -c '^"' || true)"
echo "✅ Localization parity OK — en and zh-Hans both declare $EN_COUNT keys."
