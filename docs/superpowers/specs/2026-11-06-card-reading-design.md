# Card reading and optional capture location

Scope: GET-418, current DayPageLocal iOS app, iOS 16.1+. The user's four concrete changes are the acceptance criteria; routine implementation choices below are agent decisions.

## Behavior

The diary prioritizes cards: remove visible day/Today headings and counts outside the cards, retaining invisible scrolling anchors and accessible navigation. Keep each card's own timestamp. Card text defaults to 15 instead of 17; Settings offers serif (existing), system, rounded and monospaced styles plus a bounded size range and preview. Respect system Dynamic Type and persist preferences in the notebook's injected defaults.

Leading swipe first offers Chat, then Pin. Trailing swipe first offers Share, then Trash. Full swipes invoke the first action using native SwiftUI. Trash retains its confirmation. Existing menus and accessibility actions remain.

Write a note starts without location. Only Add location requests When In Use permission and one current fix. No continuous/background collection or reverse-geocoding request. A compact coordinate label can be removed before saving. Denial/failure leaves writing usable; collapsing/backgrounding cancels acquisition and cannot modify a new draft later. Added location survives draft reopen/relaunch, attachment changes and note save; a subsequent new note again starts without location.

## Approach

Use native List swipeActions rather than a custom drag recognizer; this preserves vertical scrolling and system accessibility. Use the existing Memo.location YAML shape rather than changing raw format or embedding coordinates in note body. Add an optional location field to internal version-1 draft snapshots/body sidecars with decodeIfPresent; older drafts remain readable without migration. Location and text share a revision/identity boundary. The full existing draft transaction tests must remain green.

Do not add a global location-on switch: per-note intent is the user's requested default. Do not request Always permission, background modes, a map SDK or any external dependency. Display selected location only within its card/editor/detail. Existing note edits preserve their current location.

## Verification and risks

Test default nil, old draft decoding, body-sidecar/asset round trips, removal, stale draft identity, commit/discard and read-only recovery. Independently review late callbacks, saving during acquisition, preference normalization and anonymous location behavior. Verify real native full swipes, settings persistence and note location save/reopen on an isolated Simulator account/container. Synthetic location fixtures establish UI/persistence evidence only; real Core Location permission/denial is a separate native check.
