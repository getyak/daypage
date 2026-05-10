"use client";

import { useState } from "react";
import type { InboxItem } from "@/lib/db/schema";

type Kind = "contradiction" | "schema" | "orphan" | "compiled";

interface InboxClientProps {
  items: InboxItem[];
  counts: Record<Kind | "all", number>;
}

const KIND_CHIPS: { key: Kind | "all"; label: string }[] = [
  { key: "all", label: "All" },
  { key: "contradiction", label: "Contradictions" },
  { key: "schema", label: "Schema" },
  { key: "orphan", label: "Orphans" },
  { key: "compiled", label: "Compiled" },
];

function formatRelative(date: Date): string {
  const diff = Date.now() - date.getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

function KindChip({ kind }: { kind: Kind }) {
  const map: Record<Kind, { label: string; cls: string }> = {
    contradiction: { label: "Contradiction", cls: "chip chip--error" },
    schema: { label: "Schema", cls: "chip chip--accent" },
    orphan: { label: "Orphan", cls: "chip chip--warning" },
    compiled: { label: "Compiled", cls: "chip chip--success" },
  };
  const { label, cls } = map[kind];
  return <span className={cls}>{label}</span>;
}

interface ContradictionPayload {
  old_text?: string;
  new_text?: string;
  page_id?: string;
  memo_id?: string;
}

interface SchemaPayload {
  suggested_name?: string;
  suggested_color?: string;
  cluster_memo_ids?: string[];
}

interface OrphanPayload {
  page_id?: string;
  page_title?: string;
  days_idle?: number;
}

function ContradictionCard({ item }: { item: InboxItem }) {
  const payload = (item.payload ?? {}) as ContradictionPayload;
  return (
    <div
      className="card"
      style={{
        padding: "1.25rem",
        display: "flex",
        flexDirection: "column",
        gap: "1rem",
        borderLeft: "3px solid var(--error)",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "flex-start",
          justifyContent: "space-between",
          gap: "1rem",
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <KindChip kind="contradiction" />
            <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
              {formatRelative(item.created_at)}
            </span>
          </div>
          <h3
            className="ds-body-md"
            style={{ margin: 0, fontWeight: 600, color: "var(--fg-primary)" }}
          >
            {item.title}
          </h3>
          {item.body && (
            <p
              className="ds-body-md"
              style={{ margin: 0, color: "var(--fg-muted)", fontSize: "0.8125rem" }}
            >
              {item.body}
            </p>
          )}
        </div>
      </div>

      {/* Side-by-side old/new compare */}
      {(payload.old_text || payload.new_text) && (
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "0.75rem" }}>
          <div
            style={{
              background: "var(--error-soft)",
              borderRadius: "var(--radius-sm)",
              padding: "0.75rem",
            }}
          >
            <p
              className="ds-section-label"
              style={{ color: "var(--error)", marginBottom: "0.375rem" }}
            >
              Old
            </p>
            <p
              className="ds-body-md"
              style={{
                margin: 0,
                fontSize: "0.8125rem",
                color: "var(--fg-primary)",
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
              }}
            >
              {payload.old_text ?? "—"}
            </p>
          </div>
          <div
            style={{
              background: "var(--success-soft)",
              borderRadius: "var(--radius-sm)",
              padding: "0.75rem",
            }}
          >
            <p
              className="ds-section-label"
              style={{ color: "var(--success)", marginBottom: "0.375rem" }}
            >
              New
            </p>
            <p
              className="ds-body-md"
              style={{
                margin: 0,
                fontSize: "0.8125rem",
                color: "var(--fg-primary)",
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
              }}
            >
              {payload.new_text ?? "—"}
            </p>
          </div>
        </div>
      )}

      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        <button className="btn btn--soft btn--sm">Keep both</button>
        <button className="btn btn--primary btn--sm">Use new</button>
        <button className="btn btn--secondary btn--sm">Keep mine</button>
        {payload.page_id && (
          <a
            href={`/wiki/${payload.page_id}`}
            className="btn btn--ghost btn--sm"
            style={{ textDecoration: "none" }}
          >
            Open page
          </a>
        )}
      </div>
    </div>
  );
}

function SchemaCard({ item }: { item: InboxItem }) {
  const payload = (item.payload ?? {}) as SchemaPayload;
  return (
    <div
      className="card"
      style={{
        padding: "1.25rem",
        display: "flex",
        flexDirection: "column",
        gap: "1rem",
        borderLeft: "3px solid var(--accent)",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <KindChip kind="schema" />
          <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
            {formatRelative(item.created_at)}
          </span>
        </div>
        <h3
          className="ds-body-md"
          style={{ margin: 0, fontWeight: 600, color: "var(--fg-primary)" }}
        >
          {item.title}
        </h3>
        {item.body && (
          <p
            className="ds-body-md"
            style={{ margin: 0, color: "var(--fg-muted)", fontSize: "0.8125rem" }}
          >
            {item.body}
          </p>
        )}
      </div>

      {/* Domain name + color preview */}
      {payload.suggested_name && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.75rem",
            padding: "0.75rem",
            background: "var(--accent-soft)",
            borderRadius: "var(--radius-sm)",
          }}
        >
          {payload.suggested_color && (
            <span
              style={{
                width: "12px",
                height: "12px",
                borderRadius: "50%",
                background: payload.suggested_color,
                flexShrink: 0,
              }}
            />
          )}
          <span
            className="ds-body-md"
            style={{ fontWeight: 600, color: "var(--accent)" }}
          >
            {payload.suggested_name}
          </span>
          {payload.cluster_memo_ids && (
            <span
              className="ds-mono-11"
              style={{ color: "var(--fg-subtle)", marginLeft: "auto" }}
            >
              {payload.cluster_memo_ids.length} memos
            </span>
          )}
        </div>
      )}

      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        <button className="btn btn--primary btn--sm">Create domain</button>
        <button className="btn btn--secondary btn--sm">Suggest different name</button>
        <button className="btn btn--ghost btn--sm">Not yet</button>
      </div>
    </div>
  );
}

function OrphanCard({ item }: { item: InboxItem }) {
  const payload = (item.payload ?? {}) as OrphanPayload;
  return (
    <div
      className="card"
      style={{
        padding: "1.25rem",
        display: "flex",
        flexDirection: "column",
        gap: "1rem",
        borderLeft: "3px solid var(--warning)",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <KindChip kind="orphan" />
          <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
            {formatRelative(item.created_at)}
          </span>
          {payload.days_idle !== undefined && (
            <span className="chip chip--warning" style={{ marginLeft: "auto" }}>
              {payload.days_idle} days idle
            </span>
          )}
        </div>
        <h3
          className="ds-body-md"
          style={{ margin: 0, fontWeight: 600, color: "var(--fg-primary)" }}
        >
          {item.title}
        </h3>
        {item.body && (
          <p
            className="ds-body-md"
            style={{ margin: 0, color: "var(--fg-muted)", fontSize: "0.8125rem" }}
          >
            {item.body}
          </p>
        )}
      </div>

      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        <button className="btn btn--soft btn--sm">Cold-archive</button>
        <button className="btn btn--ghost btn--sm">Keep</button>
        {payload.page_id && (
          <a
            href={`/wiki/${payload.page_id}`}
            className="btn btn--secondary btn--sm"
            style={{ textDecoration: "none" }}
          >
            Open page
          </a>
        )}
      </div>
    </div>
  );
}

function CompiledCard({ item }: { item: InboxItem }) {
  return (
    <div
      className="card"
      style={{
        padding: "1.25rem",
        display: "flex",
        flexDirection: "column",
        gap: "1rem",
        borderLeft: "3px solid var(--success)",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <KindChip kind="compiled" />
          <span className="ds-mono-11" style={{ color: "var(--fg-subtle)" }}>
            {formatRelative(item.created_at)}
          </span>
        </div>
        <h3
          className="ds-body-md"
          style={{ margin: 0, fontWeight: 600, color: "var(--fg-primary)" }}
        >
          {item.title}
        </h3>
        {item.body && (
          <p
            className="ds-body-md"
            style={{ margin: 0, color: "var(--fg-muted)", fontSize: "0.8125rem" }}
          >
            {item.body}
          </p>
        )}
      </div>

      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        <button className="btn btn--soft btn--sm">View changes</button>
        <button className="btn btn--ghost btn--sm">Dismiss</button>
      </div>
    </div>
  );
}

function InboxCard({ item }: { item: InboxItem }) {
  switch (item.kind) {
    case "contradiction":
      return <ContradictionCard item={item} />;
    case "schema":
      return <SchemaCard item={item} />;
    case "orphan":
      return <OrphanCard item={item} />;
    case "compiled":
      return <CompiledCard item={item} />;
    default:
      return null;
  }
}

export function InboxClient({ items, counts }: InboxClientProps) {
  const [activeFilter, setActiveFilter] = useState<Kind | "all">("all");

  const filtered =
    activeFilter === "all" ? items : items.filter((i) => i.kind === activeFilter);
  const totalCount = counts.all;

  return (
    <div
      style={{
        maxWidth: "760px",
        margin: "0 auto",
        padding: "2rem 1.5rem",
        display: "flex",
        flexDirection: "column",
        gap: "1.5rem",
      }}
    >
      {/* Hero block */}
      <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem" }}>
        <p className="ds-section-label">Inbox</p>
        <h1 className="ds-h1" style={{ margin: 0 }}>
          Inbox · {totalCount} {totalCount === 1 ? "item" : "items"}
        </h1>
        <p className="ds-body-md" style={{ color: "var(--fg-muted)", margin: 0 }}>
          AI suggestions, detected contradictions, and schema proposals.
        </p>
      </div>

      {/* Filter chips */}
      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        {KIND_CHIPS.map(({ key, label }) => {
          const count = counts[key] ?? 0;
          const isActive = activeFilter === key;
          return (
            <button
              key={key}
              onClick={() => setActiveFilter(key)}
              className={`chip chip--interactive ${isActive ? "chip--accent" : "chip--default"}`}
              style={{ fontWeight: isActive ? 600 : 400 }}
            >
              {label}
              {count > 0 && (
                <span
                  style={{
                    marginLeft: "0.375rem",
                    background: isActive
                      ? "var(--accent)"
                      : "var(--fg-subtle)",
                    color: "#fff",
                    borderRadius: "999px",
                    fontSize: "0.625rem",
                    fontWeight: 600,
                    padding: "0.0625rem 0.3125rem",
                    lineHeight: 1.5,
                  }}
                >
                  {count}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {/* Item list */}
      {filtered.length === 0 ? (
        <div
          style={{
            padding: "3rem 2rem",
            textAlign: "center",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: "0.75rem",
          }}
        >
          <div
            style={{
              width: "48px",
              height: "48px",
              borderRadius: "var(--radius-md)",
              background: "var(--surface-sunken)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: "1.5rem",
            }}
          >
            ✓
          </div>
          <p className="ds-body-md" style={{ color: "var(--fg-muted)", margin: 0 }}>
            {activeFilter === "all"
              ? "All caught up — no open items."
              : `No open ${activeFilter} items.`}
          </p>
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: "0.875rem" }}>
          {filtered.map((item) => (
            <InboxCard key={item.id} item={item} />
          ))}
        </div>
      )}
    </div>
  );
}
