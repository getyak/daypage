# Figma native reading implementation

This document describes the local iOS implementation of the October 15, 2026
reading design. It is associated with issue #332. Release and TestFlight delivery
are separate from this implementation.

## Design source

The editable [Daypage Core Flows Refined file](https://www.figma.com/design/el5wnKFHTBcgln16ktEztU/?node-id=364-1618)
is the source for this scope. Fresh Figma context and screenshots were read for
Today (`364:1641`), detail (`364:1790`), search (`364:1819`), insight
(`364:2219`), and related records (`364:2333`). Archive, calendar and sidebar
retain their existing structure; their memo rows inherit the shared card changes.
Further cloud reads for those three surfaces reached the Figma account quota.

## Implemented behavior

- Today has a compact navigation header, a warm paper canvas, white 16-point
  cards, 17-point serif prose, 12-point metadata and quieter spacing. Narrow
  layouts reduce margins before reducing the text area. Actual photo attachments
  appear as bounded thumbnails after prose; the existing original viewer remains.
- `MemoReadingText` retains the complete attributed document and uses UIKit text
  layout to determine overflow. Normal previews use six visual lines; text areas
  below 290 points use five. Paragraphs, list numbering, Unicode and links remain
  intact when expanded. Changes in content, width and Dynamic Type invalidate
  measurements. Semantic document inputs are cached so repeated updates do not
  rebuild the attributed document or re-emit identical overflow state. Measurement
  labels never enter the accessibility hierarchy.
- Expand and collapse are explicit 44-point controls. The native horizontal pan
  bridge covers prose and metadata; attachment, audio and disclosure controls
  receive their own touches. Selection and an open swipe drawer take priority.
  Expansion respects Reduce Motion.
- Voice transcripts appear once above real playback controls. Playback, download
  recovery and explicit retranscription remain available. The waveform accepts
  horizontal scrubbing and deliberate tap-to-seek; vertical touches remain list
  scrolling and do not start playback. All bars and their progress mask use the
  same available lane width, keeping duration and menu clear on narrow screens.
  The preview does not
  create an AI result or invoke transcription.
- Detail renders the complete original with 18-point selectable prose and a
  bounded reading width. Editing remains available through its existing menu and
  named accessibility action. A reading tap no longer immediately starts editing.
- Search retains its real retrieval, match highlighting, filtering and navigation.
  Results have a serif preview, date footer and explicit read affordance.
- Memo conversations show a three-line source card near the header. View original
  presents the complete selectable source and closes back to the same conversation.
  The source footer uses 48-point control labels so the system nested-sheet
  scale still leaves at least a 44-point visible target. Entity links route through
  the existing entity navigation. Consent, strategy
  selection and sending behavior remain explicit and unchanged.

## Deliberate refinements

Existing semantic colors, registered serif fonts, SF Symbols and real attachments
are reused. No decorative bitmap assets or fabricated photographs were added.
Dark mode uses adaptive surfaces and an accessible warm reading accent. Large text
can grow the layout beyond the default Figma dimensions. Detail editing is an
explicit action so that selecting and reading prose remain predictable.

## Verification and limits

Affected native tests cover real UILabel overflow, width changes, Dynamic Type,
paragraph/list fidelity and mixed Unicode. Existing serif-font, accessibility and
swipe contracts are included in the native gate. Runtime verification uses a
separate QA bundle, a local synthetic vault and repository-owned test media;
personal data and production AI services are not used.

Local verification on October 15 passed 70 affected native tests. Primary iPhone
runtime checks passed all ten flows: inline expansion/collapse, original detail,
real search/navigation, dark reading, composer clearance, Dynamic Type, source
reader return, photo/audio controls, horizontal drawer priority and multiselection
priority. The source-footer height correction was followed by its own successful
UI build and targeted runtime rerun. Compact iPhone (SE, 375 points) also passed
three targeted flows: long-form disclosure, source-reader return and photo/audio
touch routing, using the same native app build. Earlier failed checks are retained in the
task evidence. The 70-test native run is v9; later source-footer and waveform
layout corrections have separate successful native UI builds (v10/v11) and
targeted real-touch reruns. No v11 full-native-test rerun is claimed. This is
Simulator verification, not a physical-device release gate.

The task evidence records the exact commands, source hashes, build/test results,
runtime screenshots and independent review. Successful gates must be read from
those receipts; this document alone is not a passing test or release claim.
Web, Android, storage, schema, services, authentication and release configuration
are outside this change.
