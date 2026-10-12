# DayPage TestFlight fidelity — source order and design-system cleanup

Status: current operating document for the DayPage Figma fidelity effort and the
behavior-preserving iOS design-system cleanup performed under it. The reviewed
source was recovered and integrated for remote delivery under the
[remote recovery record](../engineering/remote-recovery.md); it is no longer
gated to a local branch. No TestFlight release is part of this task.

- Tracking issue (open): https://github.com/getyak/daypage/issues/332
- Editable Figma file: https://www.figma.com/design/el5wnKFHTBcgln16ktEztU/Daypage-Core-Flows-Refined

This document records the app source of truth, the editable Figma reconstruction,
and the inventory and verification of the legacy design-system cleanup.

## Source-of-truth order

When the editable Figma file and the app disagree, resolve in this order:

1. **Release manifest + shipped tagged SwiftUI source** — the
   [GitHub release v0.4.97](https://github.com/getyak/daypage/releases/tag/v0.4.97),
   its verified IPA identity (version 0.4.97, build 1974, `com.daypage.app`), and
   tag commit `734755b6cae9a4b9bf298a7dcfb55fc7b11dcba1`. The shipped SwiftUI
   view code is app truth; CHANGELOG has no entry for this patch release.
2. **Synthetic runtime screenshots of the release candidate** — fixture captures
   from the release verification ground the editable Figma file alongside tagged
   source. They are Simulator evidence, not screenshots from a physical device
   running the TestFlight-installed IPA.
3. **Editable Figma file** ("Daypage Core Flows Refined", link above) — the working
   design surface derived from 1 and 2. Making Figma faithful to the shipped UI
   happens here.
4. **The web product and any proposed / not-yet-matched Figma states are NOT app
   truth** — `web/` visuals and unshipped Figma proposals must not overwrite shipped
   iOS behavior or the cleanup below.

Historical design explorations under `docs/design/` and audit reports elsewhere in
`docs/` remain historical evidence and are not overridden by this document.

## Legacy design-system cleanup (behavior-preserving)

Scope: iOS design-system alias and dead-helper cleanup only (one item under issue
#332, not the whole historical issue). No resolved color value, opacity, font
size/family, glass availability/fallback, accessibility or UI behavior was changed:
every migrated call site now spells exactly the expression the removed alias
resolved to (e.g. `static let primary = amberDeep` → call sites use
`DSColor.amberDeep`; `static let onPrimary = Color.white` → `Color.white`).

### Removed: 18 legacy `DSColor` aliases (`DayPage/DesignSystem/Colors.swift`)

Canonical mapping (legacy alias → its existing target expression) with migrated
callsite counts (tracked Swift, whole repo):

| Legacy alias | Canonical expression | Migrated callsites | Files |
|---|---|---|---|
| `primary` | `DSColor.amberDeep` | 25 | 8 |
| `onPrimary` | `Color.white` | 4 | 4 |
| `onError` | `Color.white` | 3 | 1 |
| `primaryContainer` | `DSColor.amberAccent` | 1 | 1 |
| `tertiary` | `DSColor.amberAccent` | 0 | 0 |
| `secondary` | `DSColor.inkMuted` | 0 | 0 |
| `onSurfaceVariant` | `DSColor.inkMuted` | 82 | 17 |
| `surface` | `DSColor.bgWarm` | 2 | 2 |
| `background` | `DSColor.bgWarm` | 6 | 6 |
| `surfaceContainerLowest` | `DSColor.surfaceWhite` | 1 | 1 |
| `surfaceContainerLow` | `DSColor.glassLo` | 2 | 2 |
| `surfaceContainer` | `DSColor.glassStd` | 10 | 4 |
| `surfaceContainerHigh` | `DSColor.glassHi` | 25 | 8 |
| `onSurface` | `DSColor.inkPrimary` | 42 | 13 |
| `outline` | `DSColor.glassRim` | 11 | 6 |
| `outlineVariant` | `DSColor.inkFaint` | 15 | 5 |
| `error` | `DSColor.errorRed` | 14 | 9 |
| `errorContainer` | `DSColor.errorSoft` | 1 | 1 |
| **Total** | | **244** | **28 unique files** |

The v1-era alias block and its stale migration comments ("Migration map …",
"Phase B will physically delete each of these …") were removed together with the
aliases.

### Removed: dead legacy visual helpers (whole-repo audit, zero live callers)

| Symbol | File | Callers at baseline |
|---|---|---|
| `PressableCardModifier` + `View.pressableCard()` | `DayPage/DesignSystem/Interactions.swift` | none (comment-only mentions) |
| `GlassDisc` + `View.glassDisc(size:)` | `DayPage/DesignSystem/GlassSurface.swift` | none |
| `LiquidGlassPanel` + `View.liquidGlassPanel(cornerRadius:)` | `DayPage/DesignSystem/Surfaces.swift` | none |
| `View.labelStyle()` (typography shorthand) | `DayPage/DesignSystem/Typography.swift` | none (SwiftUI's `labelStyle(_:)` is a different, live overload) |

Every removed symbol is internal to the `DayPage` app target — no `public` API, no
`DayPageKit` package surface, no Apple companion (Mac/Watch/Widget) boundary — so
removal carries no platform or visibility risk.

### Protected live paths (retained deliberately)

- `SurfaceElevatedShadow` + `View.surfaceElevatedShadow()` (`Colors.swift`) — has 5
  live production callsites (`OnboardingView` ×4, `CompileFooterButton` ×1). It was a
  removal candidate but is NOT dead, so it is retained as-is.
- `GlassErrorBannerOverlayModifier` + `View.glassErrorBannerOverlay()` — callers exist
  in `#Preview` blocks of `DayPage/Components/GlassErrorBanner.swift`; previews count
  as live callsites, so retained.
- `Components.swift` `StatusBadge` / `WikilinkBodyText` — live callers; unchanged.
- All other typography view modifiers (`h1`, `h2Style`, `captionStyle`, `bodyText`,
  `captionText`, `labelText`, `headlineMDStyle`, `headlineCapsStyle`,
  `sectionLabelStyle`, `bodyMDStyle`, `bodySMStyle`, `labelSMStyle`,
  `monoLabelStyle`) have live callsites and were retained.
- v3 warm-white tokens (`backgroundWarm`, `surfaceWhite`, `surfaceSunken`,
  `onBackground*`, `accentAmber`, `amberArchival`, …) are outside the 18-alias
  contract and remain unchanged.
- `DayPageTests/AccessibilityTests.swift` keeps its negative source-scan guard string
  `".tint(DSColor.primary)"`. It is a string literal asserting absence in Settings
  sources, not a callsite; rewriting it would change what the assertion means, so it
  is intentionally left as-is.

### Out-of-scope prose references (preserved historical evidence)

Non-code references to the removed names remain, unmodified, in historical material:
`archive/`, `tasks/`, `docs/plans/`, `docs/ux-audits/`,
`docs/ux-optimization-audit-2026-06-23.md`, `docs/liquid-glass-vNext.md`, and
`scripts/ralph/archive/`. These are reports, PRDs, and explorations — not compiled
callers — and are preserved as evidence per the documentation rules.

## Verification

Run for the cleanup change:

- `git diff --check`
- `make check-tokens`
- `make check-localization`
- Whole-repo reference sweeps (`git grep`/`rg`) proving zero remaining tracked-Swift
  references to every removed symbol.

Root verification (2026-10-08):

- Production `build-for-testing`: passed. App, Widget, Watch and test target compile.
- Dedicated `.qa-unit` host build: passed; production startup disabled.
- Native AccessibilityTests, DSFontsSerifTests and SwipePolishContractTests:
  57 passed, zero failures and skips, Primary iPhone only.
- Simulator smoke on a unique `.qa-testflight-fidelity` identity: opened the
  text composer, saved a synthetic memo, opened Search, checked its date/type
  controls, and cancelled back to Today. Native Today/Search captures are saved.
  No real account, AI call, personal vault or hardware permission was used.
  The keyboard driver produced a text variant, so this smoke does not claim
  exact clipboard/input normalization; fonts, cards, controls and routing were
  the acceptance scope. The fixture was archived before removing the test app.
- Independent review: no remaining findings. One provenance P2 was corrected
  and independently rechecked.
- Mechanical source equivalence: all 28 migrated Swift files equal the baseline
  after exact alias expansion. Base app source has no diff from release tag
  `v0.4.97`; integration starts at `935917de`.
- Figwright reconstruction: eight editable core states (Today, Sidebar, Archive
  list, Calendar, Search, Memo detail, Insight chooser, Related follow-up).
  Structure audit: 173 text nodes, 126 component instances, 76 discrete image
  fills whose maximum dimensions are 24 × 24 pt; no screen-sized image fills.
- Native color variables include paired Light/Dark collections. Text uses
  Source Serif 4, Source Han Serif SC, Inter, JetBrains Mono and system SF Pro
  with PingFang SC for native Chinese UI fallback.

Formal evidence is in the project task directory
`reports/testflight-fidelity-20261008/`: build/test logs and xcresults,
`native-test-summary.json`, `mechanical-equivalence.json`, independent review,
Figma exports, node ledger and structure audit. DayPageKit host tests were not
rerun: no package source changed. This is not a new TestFlight release gate.

## Genuine limitations

- Figma represents native Liquid Glass as a static material. Its realtime
  refraction and system transitions are rendered by iOS and are not reproduced
  by static Figma frames. Eight core states are verified against source and
  synthetic fixtures; this does not claim every app route, device size, language
  or accessibility setting has a separate Figma screen.
- Historical concepts are clearly marked on `90 · 历史概念稿 / 非 TestFlight`;
  the current UI and native components have their own pages.
- Rollback is a source-only restoration of the reviewed Swift changes to the
  baseline. There is no persisted-data migration or schema change.
- Issue #332 covers more than this cleanup; this change is one behavior-preserving
  item under the open issue and does not complete it. Its recovered design-system
  delta is integrated alongside the #876 screenshot work per the
  [remote recovery record](../engineering/remote-recovery.md).
- `SurfaceElevatedShadow` remains a small legacy-style shadow helper (retained for
  its live callers); unifying it with `DSElevation` would change rendered shadows and
  needs its own explicitly reviewed change.
