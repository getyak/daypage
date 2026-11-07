# Local screenshot capture and sharing

GET-440, parent GET-439; GitHub #976. The owner requested functional migration of
old drafts, while preserving the accepted current local iOS architecture.

## Intent and chosen approach

Restore the missing shortcut/share entry points in the active app. A Shortcuts
image action opens DayPage with a pending local image. A new Share extension
accepts one image and stages it only after the person taps Add. DayPage previews
it with an optional caption; only Save note publishes the original bytes using
the existing NotebookStore transaction. Existing unsaved capture drafts stay intact.

Reusing legacy screenshot/AI/cloud coordinators would reintroduce rejected
dependencies. Copying into the ordinary capture draft creates an unnecessary
cross-process acknowledgement race and can overwrite the person's draft. Instead,
the confirmation saves a separate note with the inbox capture's stable UUID;
retry checks existing local notes and recoverable Trash before acknowledging.

## Boundaries

- Pure local inbox in an explicitly shared App Group; Debug and Release groups
  are distinct. No cloud account, database, network, OCR provider or Keychain use.
- Only PNG/JPEG/HEIC/HEIF images, validated from actual bytes; at most 25 MiB per
  image, 40 million pixels, 10 pending images and 50 MiB stored inbox data.
- UUID paths, digest validation, bounded reads, no symbolic-link traversal,
  cross-process locking and atomic folder publication. Failed save/cleanup
  preserves the staged original. Cancel prevents late provider callbacks staging.
- AppIntent only runs in the app and requests foreground execution. Share
  extension does not launch the app by private API or write the Vault.
- The person can discard a pending capture explicitly. No automatic purge or
  modification of existing Vault files is introduced.

## Verification and limits

Synthetic host fixtures cover image/type/size/path/digest/quota rejection,
publication and discard, concurrent writers, interrupted publication and stable
identity retries. Static project/privacy contracts cover target embedding,
App Group separation and the cloud dependency boundary. Root coordinates SDK
typechecks/native CI; no local Simulator, installation or signing is automatic.
Real Share-sheet/Shortcuts, device permissions and provisioning remain separate
acceptance surfaces. This slice does not restore old cloud OCR or daily compilation.

## Use and pending-image recovery

In Photos or another image app, share one image to DayPage and choose Add image.
Open DayPage and tap Review shared images. Add an optional caption, then Save note;
Later keeps the pending original, while Discard removes only that pending capture.
Nothing is sent to AI. Already enabled personal iCloud replication can include the
note after it is saved, as with ordinary notes.

For Shortcuts or an Action Button shortcut, feed an image (for example the output
of Take Screenshot) into Review an image in DayPage. The action opens DayPage;
the same review/confirmation is still required. It does not take screenshots of
other apps by itself and does not silently save a note.

An unavailable App Group must fail without falling back to an unrelated folder.
If saving fails, the pending original remains. If only cleanup fails after a note
was saved, repeating confirmation acknowledges the existing stable note identity;
it neither overwrites that note nor recreates one that is in Trash.

If the system stops sharing before publication, complete validated envelopes are
recovered on restart. Incomplete images appear in Manage interrupted images even
when the inbox is full. Recover rebuilds only validated local image metadata and
retains damaged metadata; Discard requires a separate explicit confirmation.
Nothing is silently purged. A same-UUID note is acknowledged only when its actual
photo bytes match the capture digest; a collision preserves the pending image.

Extract text on this device is a separate button in image review. It reuses the
current AttachmentTextReader Vision implementation and never calls a provider.
The result stays separate until Add to note text; failure leaves image/caption
unchanged. Cancel, Later, dismissal or another capture revokes the result lease,
so a late recognition result cannot change another review. Synthetic host OCR
and cancellation tests plus a native explicit-click/no-network flow are required.
