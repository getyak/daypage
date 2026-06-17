#!/usr/bin/env bash
# Audit hardcoded font sizes (`.font(.system(size: N))`) across the DayPage
# iOS sources. Use DSType tokens (DesignSystem/Typography.swift) instead —
# they respect Dynamic Type, while `.system(size:)` is a fixed point size
# that ignores the user's accessibility text-scale setting.
#
# Output: file:line snippet, sorted by file. Pipe to `wc -l` for the count.
# Intended for CI as a non-blocking lint guide (Goal C, accessibility pass).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/DayPage"

if [[ ! -d "$SRC" ]]; then
  echo "audit_font_hardcoded: cannot find $SRC" >&2
  exit 2
fi

grep -rn --include='*.swift' '\.font(\.system(size:' "$SRC" | sort
