# ADR-0033: Confirmed local image intake

Status: Accepted for GET-440 / GitHub #976, implementing the owner's explicit
request to migrate missing screenshot/share behavior into the active local app.

The active project gets one new image-only Share extension and an in-app
Shortcuts image action. This narrowly supersedes ADR-0027's extension exclusion;
it does not restore legacy extensions, cloud OCR, Supabase, account credentials
or the legacy screenshot runtime. The extension depends only on DayPageCapture.

The Share sheet's Add gesture stages bounded original image bytes in a protected,
backup-excluded App Group inbox. Shortcuts opens the app with the same pending
inbox. Debug and Release share different groups. The containing app shows a
review entry; the person can inspect the image, add text, save a separate note,
discard it or leave it for later. No original is sent to AI. Existing ordinary
capture drafts are never replaced by incoming shares.

The explicit Extract text on this device action reuses the current Core Vision
reader. Recognized text is only a local preview until Add to note text. Cancelling
or dismissing invalidates that extraction; a late result cannot modify a new
review. There is no cloud OCR or implicit AI request.

NotebookStore's existing local transaction publishes the note and image after
Save note. A stable capture UUID prevents duplicate publication after a crash;
recoverable Trash also consumes that identity. Inbox cleanup follows publication,
and failure is reported separately from note persistence. Already enabled personal
iCloud replication may subsequently include a saved note under ADR-0032; pending
images are outside the Vault and excluded from backup.

Before distribution, the new production/QA App Groups and extension identifiers
need normal signing/provisioning validation. Host/static tests and unsigned CI do
not establish real Share-sheet/Shortcuts, locked-device or device acceptance.
