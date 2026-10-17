# Native Figma reading implementation

Frozen base: `56736224e7f493d58739a29ba1fad8367bf643b0` (`github/main`).
Issue: #332. Current design and scope: [implementation document](../../design/figma-reading-implementation.md).
The user authorized direct implementation and refinement. No release or remote
repository mutation is included.

- [x] Inspect the current source, instructions and fresh Figma references.
- [x] Preserve unrelated changes and use an isolated task branch/worktree.
- [x] Implement measured long-form card reading and native control hit routing.
- [x] Apply the reading system to Today, detail, search and memo source context.
- [x] Add focused layout/fidelity tests and run localization/token/static gates.
- [x] Complete affected native build/tests and Primary iPhone interaction checks.
- [x] Close confirmed independent review findings and save formal evidence.
- [x] Verify narrow-screen reading and attachment touch regression on Compact iPhone.
- [x] Remove owned rebuildable test artifacts and release the test session.

The implementation preserves the canonical file vault, services and dependency
versions. Archive/calendar/sidebar retain their structures and reuse shared rows.
Only synthetic fixtures in a fresh QA app container are used for runtime checks.
