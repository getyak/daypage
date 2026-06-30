#!/usr/bin/env bash
# scripts/m0-publicize.sh — M0 batch publicize pass for DayPageKit
#
# Adds `public` to top-level type declarations and 4-space-indented type
# members in DayPageStorage and DayPageServices targets, plus injects
# `import DayPageModels` into files that reference Models types but lack
# the import.
#
# Safe-by-omission: never touches declarations that already have an access
# modifier (public/private/internal/fileprivate/open). Skips declarations
# inside protocol bodies (protocol requirements implicitly inherit the
# protocol's access level — `public` on them is a compile error).
#
# Idempotent: re-running on already-publicized code is a no-op.
#
# Usage:
#   scripts/m0-publicize.sh              # process Storage + Services
#   scripts/m0-publicize.sh Storage      # only Storage
#   scripts/m0-publicize.sh Services     # only Services

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS=("Storage" "Services")
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
fi

# Files in DayPageStorage that reference Models types and need the import.
MODELS_USING_FILES=(
  "ConflictMerger.swift"
  "MemoSyncUploader.swift"
  "RawStorage.swift"
  "SyncQueueService.swift"
  "VaultInitializer.swift"
)

inject_import() {
  local file="$1"
  if grep -q '^import DayPageModels' "$file"; then
    return 0
  fi
  local last_import_line
  last_import_line=$(grep -n '^import ' "$file" | tail -1 | cut -d: -f1)
  if [ -z "$last_import_line" ]; then
    return 0
  fi
  sed -i.bak "${last_import_line}a\\
import DayPageModels
" "$file"
  rm -f "${file}.bak"
  echo "  + import DayPageModels → $(basename "$file")"
}

# AWK pass:
#   - Tracks brace depth.
#   - Tracks whether we're currently inside a protocol body (no `public` for
#     protocol requirements).
#   - At column 0: add `public ` to type-level decls (struct/class/enum/
#     protocol/extension/actor, optionally prefixed with `final`).
#     Skip if line already starts with public/private/internal/fileprivate/open.
#   - At exactly 4-space indent AND not inside a protocol body: add `public `
#     to member decls (func/init/var/let/subscript/typealias/struct/class/
#     enum/actor, optionally prefixed with final/static/class/override).
#     Skip if `public|private|internal|fileprivate|open` already present
#     after the 4-space prefix.
#
# Single-pass, deterministic, idempotent.
publicize_file() {
  local file="$1"
  local tmp
  tmp=$(mktemp)

  awk '
    BEGIN { depth = 0; proto_depths_count = 0 }

    # Helper: are we currently inside a protocol body?
    function in_protocol() {
      for (i = 0; i < proto_depths_count; i++) {
        if (proto_depths[i] == depth) return 1
      }
      return 0
    }

    {
      line = $0
      out = line

      # Top-level (column 0) type decl — but only when we are at brace depth 0
      # (so nested types declared at col 0 by accident are not in scope; SwiftFmt
      # would normally indent them).
      #
      # Special-case: skip `extension X: Protocol {}` — Swift forbids `public`
      # on extensions that declare protocol conformance (the conformance gets
      # the protocol's own access level automatically).
      if (depth == 0 && match(line, /^(public|private|internal|fileprivate|open)[[:space:]]/) == 0) {
        if (match(line, /^(final[[:space:]]+)?(struct|class|enum|protocol|extension|actor)[[:space:]]/) > 0) {
          is_protocol_conf_ext = (match(line, /^extension[[:space:]]+[A-Za-z0-9_.]+[[:space:]]*:/) > 0)
          if (!is_protocol_conf_ext) {
            out = "public " line
          }
        }
      }

      # 4-space indented member — only when not inside a protocol body.
      else if (depth > 0 && !in_protocol() && match(line, /^    (public|private|internal|fileprivate|open)[[:space:]]/) == 0) {
        if (match(line, /^    ((final|static|class|override)[[:space:]]+)*(func|init|var|let|subscript|typealias|struct|class|enum|actor)[[:space:]]/) > 0) {
          out = "    public " substr(line, 5)
        }
      }

      # Detect protocol-body entry on the CURRENT line BEFORE updating depth.
      # We want to remember "the next depth increase is from a protocol".
      pending_protocol_open = 0
      if (match(line, /^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|internal[[:space:]]+|fileprivate[[:space:]]+|open[[:space:]]+)?protocol[[:space:]]/) > 0) {
        pending_protocol_open = 1
      }

      # Print first (so out reflects this lines transformation).
      print out

      # Now update brace depth from THIS line.
      n_open = gsub(/\{/, "{", line)
      n_close = gsub(/\}/, "}", line)
      depth_after = depth + n_open - n_close

      # If this line opened a protocol body (saw `{` after `protocol X ... {`),
      # mark all the new depths in (depth, depth_after] as protocol depths.
      if (pending_protocol_open && n_open > 0) {
        proto_depths[proto_depths_count++] = depth + 1
      }

      # If we are leaving a protocol depth (depth dropped past a recorded
      # protocol depth), pop it.
      if (proto_depths_count > 0) {
        new_count = 0
        for (i = 0; i < proto_depths_count; i++) {
          if (proto_depths[i] <= depth_after) {
            proto_depths[new_count++] = proto_depths[i]
          }
        }
        proto_depths_count = new_count
      }

      depth = depth_after
    }
  ' "$file" > "$tmp"

  if ! cmp -s "$file" "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

for target in "${TARGETS[@]}"; do
  dir="$ROOT/DayPageKit/Sources/DayPage${target}"
  if [ ! -d "$dir" ]; then
    echo "skip: $dir not found"
    continue
  fi
  echo "== publicize: DayPage${target} =="

  if [ "$target" = "Storage" ]; then
    for fname in "${MODELS_USING_FILES[@]}"; do
      if [ -f "$dir/$fname" ]; then
        inject_import "$dir/$fname"
      fi
    done
  fi

  for f in "$dir"/*.swift; do
    [ -f "$f" ] || continue
    echo "  publicize $(basename "$f")"
    publicize_file "$f"
  done
done

echo "done."
