# Manual day/week reviews and explicit file exchange

GET-442 / #978 implements the owner's local-first choice. The architecture is
[ADR-0034](../architecture/decisions/ADR-0034-manual-reviews-explicit-file-exchange.md).

## Local iOS

Open Settings → Day and week reviews (also available in Archive). Select Day or
Week and a date; inspect the displayed time zone and source text. Weeks start
Monday. Choose up to 12 notes, enable this request and press Generate. Only that
selected text goes to the configured AI service. Generation never starts by
opening the view. Over-limit selections fail without truncation. Cancel/revoke
the request to reject late replies. If sources change, reload and preview them
again. Review/edit the response, then Save review page. Pages stay separate from
raw notes; historical source links show when a source changed or is unavailable.
Open a saved page to export its Markdown explicitly.

Settings → Exchange notebook files offers All/Day/Week export. Preview the exact
included text, attachment counts and byte total, then choose an export destination
in Files. Only selected canonical raw notes, referenced assets and matching saved
manual pages are included. The existing Export full Vault backup remains a
separate full backup operation.

To import, select an exchange or fully downloaded older Vault folder. Selection
creates a **pending copy** only. Read the preview, then Confirm import into a new
notebook namespace. Existing notes and source files stay untouched. An already
enabled iCloud setting can replicate the imported notes as it does other notes.
An interrupted copy remains under Pending imports: select the same source to
resume or explicitly discard only that pending copy. No retry overwrites another
namespace. Invalid/incomplete files stay outside the live notebook until fixed
and reverified.

## Mac and Web boundary

An exchange is a folder containing a manifest, typed records, canonical raw
Markdown and original referenced assets. A Mac user can transfer/store this
folder and inspect its Markdown using file tools, then select it in Local iOS.
Core codecs/import services also target macOS 13 and have host-test coverage.
The existing Mac App has no new exchange picker/preview adapter in this change;
do not describe file readability or codec tests as Mac App acceptance.

GET-443 / #979 owns the Web explicit upload/preview/confirmation consumer. Its
authenticated owner and current backend contract are independent of source UUIDs.
The checked-in text-attachment fixture is format evidence, not proof that Web's
supported MIME types or user import flow passed.

## Acceptance still requiring a host/device

- Verify Files folder selection, destination choice, cancel and re-open with an
  isolated synthetic Vault; source and existing local raw bytes must remain exact.
- Exercise no request before Generate, explicit consent off/on, source/config
  changes, late reply after cancel, editable result and explicit Save with a
  synthetic transport before any real provider acceptance.
- Exercise day/week boundaries, large selections, empty-body attachment notes,
  malformed files, interrupted copy/relaunch/resume/discard and receipt retry.
- Verify compact iPhone/iPad, VoiceOver/dynamic type and source links. Hosted CI
  is distinct from these device interactions and from a real BYOK request.
