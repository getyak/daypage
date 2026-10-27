# Historical design explorations

These files preserve product and interaction explorations from July and August 2026.
They are review artifacts, not current requirements, accepted architecture decisions,
or implementation plans. The examples are anonymized and illustrative; they do not
contain or read a user vault.

Current documents live alongside them:

- `capture-first-entry.md`: GET-255 capture hierarchy, existing platform voice
  boundaries, explicit organization and verification contract.

- `figma-reading-implementation.md`: the October 15 native reading implementation,
  source Figma nodes, deliberate refinements, verification scope and limits.

- `flomo-native-refinement.md`: design, acceptance mapping, explicit current limits
  and verification commands for the user-requested native refinement (swipe
  insight/related actions, memo-anchored insight chat, sidebar/archive/search
  refinement). It describes shipped local behavior in this branch, not a proposal.

- `testflight-fidelity.md`: source-of-truth order for making the editable Daypage
  Core Flows Refined Figma file faithful to the shipped TestFlight UI (v0.4.97), plus
  the inventory, mapping, protected live paths, and limitations of the
  behavior-preserving design-system cleanup under issue #332.

- `architecture-review.html`: capture/compile separation, skill pipelines, derived
  indexing, and feed hypotheses. SQLite and runtime choices remain proposals.
- `interaction-mockups.html`: mobile interaction sketches for capture, explicit
  commands, compilation, entity views, and conversational entry points.
- `raw-feed-refined.html`: comparison study for transcript density, grouping, and
  inline compiled-day presentation.
- `receipt-artifacts.html`: three proposed presentation levels for outbound-effect
  receipts.
- `backend-first-agent-data-plane.md`: accepted 2026-08-28 design for local-first
  capture plus a backend-first Agent data plane, covering versioned skills,
  automations, tools, structured run artifacts, approvals, and migration. The
  durable decision is recorded in
  [`ADR-0018`](../architecture/decisions/ADR-0018-backend-first-agent-data-plane.md).

Current documentation is routed from [`docs/README.md`](../README.md). Any proposal
selected for implementation requires a scoped GitHub issue; durable architecture
changes also require an ADR under `docs/architecture/decisions/`.

The interactive decision-memory prototype lives at `web/src/app/memory-demo/` and is
tracked by GitHub issue #871. It uses local component state and sample content only; it
does not implement persistence, retrieval, AI compilation, or analytics.
