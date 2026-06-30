#!/usr/bin/env python3
"""scripts/m0-inject-imports.py — M0 batch import injector for app target.

For each .swift file under DayPage/ (excluding files already moved to Kit),
this script inspects which DayPageKit types the file references and injects
`import DayPageModels` / `import DayPageStorage` / `import DayPageServices`
as needed, right after the last `import` line.

Idempotent: re-running on a file that already has the imports is a no-op.

Strategy:
1. Build the type ownership map by grep'ing public declarations in each Kit target.
2. For each candidate app file, regex-extract token-like identifiers and check
   membership against the ownership map.
3. Skip a file's existing imports (they already declare the dep).
4. Insert the missing imports after the last `import` line at the top of the file.

This is a heuristic — a token "Memo" inside a string literal would trigger an
unneeded import, but unneeded imports are harmless (no compile error). The
opposite (missing import) IS a compile error, so we err on the side of
over-importing.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KIT = ROOT / "DayPageKit" / "Sources"
APP = ROOT / "DayPage"

# Build ownership map: type_name -> module_name
OWNERSHIP = {}

def index_target(target_dir: Path, module: str):
    pat = re.compile(
        r'^public\s+(?:final\s+)?(?:struct|class|enum|protocol|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)',
        re.MULTILINE,
    )
    for f in target_dir.glob("*.swift"):
        text = f.read_text(encoding="utf-8")
        for m in pat.finditer(text):
            name = m.group(1)
            # Prefer earliest assignment (Models < Storage < Services dep order).
            if name not in OWNERSHIP:
                OWNERSHIP[name] = module

# Order matters: index Models first (lowest layer), then Storage, then Services.
index_target(KIT / "DayPageModels", "DayPageModels")
index_target(KIT / "DayPageStorage", "DayPageStorage")
index_target(KIT / "DayPageServices", "DayPageServices")

# Common extensions (e.g. `extension Notification.Name`) don't introduce new
# type names but DO mean app files referencing those .name vars need the import.
# We track them via specific name-string queries below.
EXTENSION_HINTS = {
    "DayPageStorage": [
        r"\.vaultConflictResolved\b",
        r"\.vaultConflictFailed\b",
        r"\.rawStorageDidWrite\b",
        r"\.syncQueueFlushRequested\b",
        r"\.simulateOfflineChanged\b",
    ],
    "DayPageModels": [
        r"ISO8601DateFormatter\.memo\b",
        r"ISO8601DateFormatter\.dayOnly\b",
    ],
}


def needs_import(text: str, module: str) -> bool:
    """Return True if any owned identifier of `module` appears in text."""
    for name, owner in OWNERSHIP.items():
        if owner != module:
            continue
        if re.search(rf'\b{re.escape(name)}\b', text):
            return True
    for pat in EXTENSION_HINTS.get(module, []):
        if re.search(pat, text):
            return True
    return False


def already_imports(text: str, module: str) -> bool:
    return re.search(rf'^import\s+{re.escape(module)}\b', text, re.MULTILINE) is not None


def inject_imports(file_path: Path):
    text = file_path.read_text(encoding="utf-8")
    modules_to_add = []
    for module in ("DayPageModels", "DayPageStorage", "DayPageServices"):
        if not already_imports(text, module) and needs_import(text, module):
            modules_to_add.append(module)

    if not modules_to_add:
        return None

    lines = text.splitlines(keepends=True)
    last_import_idx = -1
    for i, line in enumerate(lines):
        if re.match(r'^import\s+\S+', line):
            last_import_idx = i

    if last_import_idx == -1:
        # No existing import — insert before the first non-comment line.
        insert_at = 0
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped and not stripped.startswith("//") and not stripped.startswith("/*"):
                insert_at = i
                break
        new_lines = [f"import {m}\n" for m in modules_to_add]
        if insert_at > 0 and lines[insert_at - 1].strip() != "":
            new_lines = ["\n"] + new_lines
        lines = lines[:insert_at] + new_lines + lines[insert_at:]
    else:
        new_lines = [f"import {m}\n" for m in modules_to_add]
        lines = lines[:last_import_idx + 1] + new_lines + lines[last_import_idx + 1:]

    file_path.write_text("".join(lines), encoding="utf-8")
    return modules_to_add


def main():
    swift_files = list(APP.rglob("*.swift"))
    swift_files.sort()
    changed = 0
    for f in swift_files:
        added = inject_imports(f)
        if added:
            rel = f.relative_to(ROOT)
            print(f"  + {','.join(added)}  {rel}")
            changed += 1
    print(f"\ndone: {changed} file(s) updated, {len(swift_files) - changed} unchanged")


if __name__ == "__main__":
    main()
