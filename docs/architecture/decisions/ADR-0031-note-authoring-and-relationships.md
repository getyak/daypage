# ADR-0031: Reviewed note actions and confirmed relationships

Status: Accepted for GET-388 within the November 4 direct implementation request and the user's explicit choice to confirm suggested relationships.

Extend ADR-0030's six read-only tools with bounded discovery and proposals for note authoring and confirmed relationships. The model-facing executor returns pending typed proposals; only a native confirmation invokes durable apply. Model output never serves as a successful file-write receipt. Stable operation identities, exact raw-record revisions and persistent receipts provide retry/restart recovery and conflict-checked undo.

Keep raw daily Markdown unchanged. Store versioned action and relationship metadata under the existing local .daypage boundary; use full namespace/day/UUID identities and validate file containment. Relationship reads require both endpoints in current host scope, include direction/evidence, and expose stale/missing endpoints truthfully. Suggested relations remain distinct from confirmed persisted edges.

Use local bounded lexical/Chinese-bigram candidate retrieval with the existing chat model for interpretation/query expansion. This is not an embedding service or guaranteed semantic recall. Adding such an index requires retrieval evidence and a later decision. No dependency, database, external service or automatic background processing is introduced.

Rollback disables the extended tools and native review controls while preserving action receipts, relationship files and raw notes. Unknown metadata versions fail closed rather than overwrite prior data. Synthetic file-level, provider and native UI evidence is required; live provider and physical-device acceptance remain separate.
