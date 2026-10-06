# Synthetic bulk QA data

`scripts/qa/batch_dataset.py` is a test tool, not a production seeder. Use
`scripts/qa/batch_dataset.py` with Python 3 and Pillow. Generated notes contain
synthetic Chinese/English text, long paragraphs, Markdown, quotes, emoji, stable
UUIDs and exact-search tokens. Never point it at a personal vault.

```sh
python3 scripts/qa/batch_dataset.py generate --output /absolute/new/dataset \
  --count 5000 --days 20 --end-date 2026-10-05 --seed 20261005 --images 24
python3 scripts/qa/batch_dataset.py validate /absolute/new/dataset
python3 scripts/qa/batch_dataset.py import-vault /absolute/new/dataset \
  --target /absolute/new/qa-vault
```

Generate and import require nonexistent destinations. The manifest records all
hashes, counts, dimensions, orientation, owning-day UUIDs and expected query
matches. Import copies `raw/` and `wiki/daily/`; a corrupt JPEG fixture stays
outside the imported vault. Each dataset has one 4096px image, landscape and
portrait images, and EXIF orientation cases. Symlink roots/parents and traversal
paths are refused; macOS standard `/var` and `/tmp` aliases are allowed.

## Actual HTTP upload

DayPage Web `/api/upload` uses a Supabase session Cookie, not an iOS bearer token.
Supply an authorized **test** session through an environment variable (never put
its value in a checked-in command or evidence file):

```sh
python3 scripts/qa/batch_dataset.py upload-images /absolute/new/dataset \
  --endpoint http://127.0.0.1:13000/api/upload --cookie-env DAYPAGE_QA_COOKIE \
  --report /absolute/new/upload-receipt.json
```

The CLI sends multipart `file` bytes and requires the actual 201 response fields
`url`, `filename`, `original_filename`, `size`, `mime_type`. It downloads each
returned image with the same session Cookie (or configured test-server Bearer
token) and checks exact bytes, then writes hashes to the receipt. Only validated
same-origin `/uploads/<filename>` responses reach this authenticated download. Failed
HTTP requests, malformed success bodies and mismatched downloads fail the run.
The receipt contains no authentication header. Redirects are refused. Remote
endpoints require `--allow-remote-host` and HTTPS; URLs containing credentials,
queries or fragments are refused. `--token-env` supports explicitly configured
custom test servers; DayPage Web expects `--cookie-env`. No endpoint or test
session is fabricated. Local contract-server tests are not cloud acceptance.

## Simulator verification

Use the allowlisted `Primary iPhone`. Use Compact only for a recorded small-screen
layout/keyboard reason. Run storage audit first and enter `dev-ios-session run`
for the entire native session. All output goes into a registered
`dev-storage-guard new-artifact` directory. Do not create or erase devices.

Install the already verified dedicated `com.daypage.app.qa-ui` Debug bundle into
an empty test application container. Verify bundle identity and that the target
vault does not exist before importing. Keep iCloud disabled with
`-qaForceLocalVault YES`, and avoid real account credentials. Compare raw-file
hashes before/after UI actions. Import image fixtures with `simctl addmedia` in
the same owned session; this prepares Photos, it does not prove picker saving.

For 100/1000/5000 scale runs, create separate dataset directories. Report which
scale was actually installed. Search known `qa-token-NNNN` values and compare
results with the manifest. Verify cancel/save/reopen/remove through visible UI
and disk readback five times. Inspect long text, image previews and keyboard
visibility on the screen, not only the accessibility tree.

Record build/configuration, device/runtime, scenario, exact run count, RSS/CPU
sample scope and command outcomes. Automation action-to-observation time includes
tool overhead; it is not pure app latency or FPS. A failed profiler attachment
must remain failed. Save formal synthetic evidence before removing task artifacts;
keep existing QA data and other tasks' artifacts unchanged.

```sh
python3 -m unittest discover -s scripts/qa -p test_batch_dataset.py
```
