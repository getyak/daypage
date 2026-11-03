# Diary navigation

Scope: [GET-371](https://linear.app/getyak/issue/GET-371/refine-the-sidebar-and-let-the-home-diary-flow-through-past-days), [GitHub #963](https://github.com/getyak/daypage/issues/963).

The user asked for a deeper sidebar refinement, a home that can scroll into past diaries, and interactions with a small sense of discovery. The user delegated routine design and implementation decisions. The following choices are the implementer's proposal carried out under that authorization.

## Direction

Keep the established warm paper, serif reading type and quiet capture dock. Make the drawer feel like a notebook's contents page: a small bookmark motif, honest note/day totals, a clear Diary/Archive pair, month positions and lower-priority Feedback/Settings. Month navigation expands beyond the latest four months. The drawer scrolls at large text sizes, hides the background from accessibility and restores focus on dismissal.

At accessibility sizes, supplementary counts use semantic headline/caption sizes and only the decorative wordmark has a size ceiling. Navigation and reading content retain full Dynamic Type. Dark verification uses the app's existing appearance preference, rather than assuming a system launch-style argument changes the product setting.

Home opens at Today, then continues through all recorded days, newest first. A calendar or month choice changes the reading position, preserving the surrounding diary. Empty dates have a short placeholder at their correct position. Pins stay within their day; imported records keep their full identity. Returning to Today works even when the selected date has not changed. Saving a new note still reveals its exact local record once.

Discovery lives in one explicit action: open a randomly chosen existing note from before today. It does not fabricate a memory, edit content or contact AI. A short spring for the drawer, pressed-state feedback and a selection haptic support deliberate actions; Reduce Motion removes spatial movement.

## Alternatives

- Keep Home date-filtered and decorate the drawer: cheaper, but does not satisfy continuous historical reading.
- Merge Home and Archive entirely: removes a destination, but complicates capture-first reading with selection and filtering controls.
- Continuous Home with Archive for deliberate filtering: chosen by the implementer. Shares the existing catalog and card controls while giving each view a clear purpose.

## Boundaries and verification

Owned paths: local iOS views/resources/project, the read-only core catalog, focused tests and this documentation. Forbidden: vault/storage formats, live user content, chat/provider behavior and legacy clients. No new dependency, migration or TestFlight publication. The sole release-workflow change broadens its existing opt-out to the whole push, so a multi-PR Merge Queue batch cannot publish a feature-only change; missing or potentially truncated commit lists also skip automatic publication. Manual release behavior and ordinary CI are unchanged.

Verify chronological grouping, empty anchors, imported identities and year/month boundaries in core tests. Verify real Simulator scrolling, month jumps, Today, rediscovery, capture from a past day, empty data, Chinese/dark/large text and existing calendar/search/card journeys. Native test data must remain within the isolated Debug QA bundle. Independent review and exact-source CI precede integration. Physical-device haptics and VoiceOver remain separately distinguishable evidence.
