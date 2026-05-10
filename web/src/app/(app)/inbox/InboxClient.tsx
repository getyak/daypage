"use client";

import { useState, useCallback, useRef } from "react";
import { useRouter } from "next/navigation";
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

// ─── Payload types ─────────────────────────────────────────────────────────────

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

// ─── Action helpers ────────────────────────────────────────────────────────────

async function postAction(
  itemId: string,
  endpoint: "resolve" | "dismiss" | "snooze",
  body?: object
): Promise<boolean> {
  try {
    const res = await fetch(`/api/inbox/${itemId}/${endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body ?? {}),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// ─── SnoozeMenu ────────────────────────────────────────────────────────────────

interface SnoozeMenuProps {
  itemId: string;
  onAction: (itemId: string) => void;
}

function SnoozeMenu({ itemId, onAction }: SnoozeMenuProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const snooze = useCallback(
    async (days: number) => {
      setOpen(false);
      const until = new Date(Date.now() + days * 86_400_000).toISOString();
      const ok = await postAction(itemId, "snooze", { until });
      if (ok) onAction(itemId);
    },
    [itemId, onAction]
  );

  const dismiss = useCallback(async () => {
    setOpen(false);
    const ok = await postAction(itemId, "dismiss");
    if (ok) onAction(itemId);
  }, [itemId, onAction]);

  return (
    <div style={{ position: "relative" }} ref={ref}>
      <button
        className="btn btn--ghost btn--sm"
        onClick={() => setOpen((v) => !v)}
        aria-label="More options"
        style={{ padding: "0 0.375rem" }}
      >
        ···
      </button>
      {open && (
        <>
          {/* backdrop */}
          <div
            style={{ position: "fixed", inset: 0, zIndex: 9 }}
            onClick={() => setOpen(false)}
          />
          <div
            style={{
              position: "absolute",
              top: "calc(100% + 4px)",
              right: 0,
              zIndex: 10,
              background: "var(--surface)",
              border: "1px solid var(--border)",
              borderRadius: "var(--radius-sm)",
              boxShadow: "0 4px 12px rgba(0,0,0,0.12)",
              minWidth: "160px",
              padding: "0.25rem",
              display: "flex",
              flexDirection: "column",
              gap: "2px",
            }}
          >
            {[
              { label: "Snooze 1 day", days: 1 },
              { label: "Snooze 1 week", days: 7 },
            ].map(({ label, days }) => (
              <button
                key={days}
                onClick={() => snooze(days)}
                style={{
                  background: "none",
                  border: "none",
                  padding: "0.4rem 0.625rem",
                  textAlign: "left",
                  borderRadius: "var(--radius-sm)",
                  cursor: "pointer",
                  fontSize: "0.8125rem",
                  color: "var(--fg-primary)",
                  width: "100%",
                }}
                onMouseEnter={(e) =>
                  ((e.currentTarget as HTMLButtonElement).style.background =
                    "var(--surface-sunken)")
                }
                onMouseLeave={(e) =>
                  ((e.currentTarget as HTMLButtonElement).style.background =
                    "none")
                }
              >
                {label}
              </button>
            ))}
            <div
              style={{
                height: "1px",
                background: "var(--border)",
                margin: "0.25rem 0",
              }}
            />
            <button
              onClick={dismiss}
              style={{
                background: "none",
                border: "none",
                padding: "0.4rem 0.625rem",
                textAlign: "left",
                borderRadius: "var(--radius-sm)",
                cursor: "pointer",
                fontSize: "0.8125rem",
                color: "var(--error)",
                width: "100%",
              }}
              onMouseEnter={(e) =>
                ((e.currentTarget as HTMLButtonElement).style.background =
                  "var(--error-soft)")
              }
              onMouseLeave={(e) =>
                ((e.currentTarget as HTMLButtonElement).style.background =
                  "none")
              }
            >
              Dismiss
            </button>
          </div>
        </>
      )}
    </div>
  );
}

// ─── Card components ───────────────────────────────────────────────────────────

function ContradictionCard({
  item,
  onAction,
}: {
  item: InboxItem;
  onAction: (id: string) => void;
}) {
  const payload = (item.payload ?? {}) as ContradictionPayload;

  const resolve = useCallback(
    async (action: string) => {
      const ok = await postAction(item.id, "resolve", { action });
      if (ok) onAction(item.id);
    },
    [item.id, onAction]
  );

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
        <SnoozeMenu itemId={item.id} onAction={onAction} />
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
        <button className="btn btn--soft btn--sm" onClick={() => resolve("keep_both")}>
          Keep both
        </button>
        <button className="btn btn--primary btn--sm" onClick={() => resolve("use_new")}>
          Use new
        </button>
        <button className="btn btn--secondary btn--sm" onClick={() => resolve("keep_mine")}>
          Keep mine
        </button>
        {payload.page_id && (
          <a
            href={`/wiki/${payload.page_id}`}
            className="btn btn--ghost btn--sm"
            style={{ textDecoration: "none" }}
          >
            Open both pages
          </a>
        )}
      </div>
    </div>
  );
}

function SchemaCard({
  item,
  onAction,
}: {
  item: InboxItem;
  onAction: (id: string) => void;
}) {
  const payload = (item.payload ?? {}) as SchemaPayload;

  const resolve = useCallback(
    async (action: string) => {
      const ok = await postAction(item.id, "resolve", { action });
      if (ok) onAction(item.id);
    },
    [item.id, onAction]
  );

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
        <SnoozeMenu itemId={item.id} onAction={onAction} />
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
        <button
          className="btn btn--primary btn--sm"
          onClick={() => resolve("create_domain")}
        >
          Create domain
        </button>
        <button
          className="btn btn--secondary btn--sm"
          onClick={() => resolve("suggest_different_name")}
        >
          Suggest different name
        </button>
        <button className="btn btn--ghost btn--sm" onClick={() => resolve("not_yet")}>
          Not yet
        </button>
      </div>
    </div>
  );
}

function OrphanCard({
  item,
  onAction,
}: {
  item: InboxItem;
  onAction: (id: string) => void;
}) {
  const payload = (item.payload ?? {}) as OrphanPayload;

  const resolve = useCallback(
    async (action: string) => {
      const ok = await postAction(item.id, "resolve", { action });
      if (ok) onAction(item.id);
    },
    [item.id, onAction]
  );

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
      <div
        style={{
          display: "flex",
          alignItems: "flex-start",
          justifyContent: "space-between",
          gap: "1rem",
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", gap: "0.375rem", flex: 1 }}>
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
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>

      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        <button
          className="btn btn--soft btn--sm"
          onClick={() => resolve("cold_archive")}
        >
          Cold-archive
        </button>
        <button className="btn btn--ghost btn--sm" onClick={() => resolve("keep")}>
          Keep
        </button>
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

function CompiledCard({
  item,
  onAction,
}: {
  item: InboxItem;
  onAction: (id: string) => void;
}) {
  const resolve = useCallback(
    async (action: string) => {
      const ok = await postAction(item.id, "resolve", { action });
      if (ok) onAction(item.id);
    },
    [item.id, onAction]
  );

  const dismiss = useCallback(async () => {
    const ok = await postAction(item.id, "dismiss");
    if (ok) onAction(item.id);
  }, [item.id, onAction]);

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
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>

      <div style={{ display: "flex", gap: "0.5rem", flexWrap: "wrap" }}>
        <button
          className="btn btn--soft btn--sm"
          onClick={() => resolve("view_changes")}
        >
          View changes
        </button>
        <button className="btn btn--ghost btn--sm" onClick={dismiss}>
          Dismiss
        </button>
      </div>
    </div>
  );
}

function InboxCard({
  item,
  onAction,
}: {
  item: InboxItem;
  onAction: (id: string) => void;
}) {
  switch (item.kind) {
    case "contradiction":
      return <ContradictionCard item={item} onAction={onAction} />;
    case "schema":
      return <SchemaCard item={item} onAction={onAction} />;
    case "orphan":
      return <OrphanCard item={item} onAction={onAction} />;
    case "compiled":
      return <CompiledCard item={item} onAction={onAction} />;
    default:
      return null;
  }
}

// ─── Animated wrapper ──────────────────────────────────────────────────────────

const FADE_MS = 300;

function AnimatedCard({
  item,
  removing,
  onAction,
}: {
  item: InboxItem;
  removing: boolean;
  onAction: (id: string) => void;
}) {
  return (
    <div
      style={{
        transition: `opacity ${FADE_MS}ms ease, transform ${FADE_MS}ms ease, max-height ${FADE_MS}ms ease`,
        opacity: removing ? 0 : 1,
        transform: removing ? "translateX(16px)" : "translateX(0)",
        maxHeight: removing ? "0" : "600px",
        overflow: "hidden",
      }}
    >
      <InboxCard item={item} onAction={onAction} />
    </div>
  );
}

// ─── Main client component ─────────────────────────────────────────────────────

export function InboxClient({ items: initialItems, counts: initialCounts }: InboxClientProps) {
  const router = useRouter();
  const [items, setItems] = useState<InboxItem[]>(initialItems);
  const [counts, setCounts] = useState(initialCounts);
  const [removing, setRemoving] = useState<Set<string>>(new Set());
  const [activeFilter, setActiveFilter] = useState<Kind | "all">("all");

  const handleAction = useCallback(
    (itemId: string) => {
      // Start fade-out
      setRemoving((prev) => new Set(prev).add(itemId));

      setTimeout(() => {
        setItems((prev) => {
          const removed = prev.find((i) => i.id === itemId);
          if (!removed) return prev;
          // Decrement counts
          setCounts((c) => ({
            ...c,
            all: Math.max(0, c.all - 1),
            [removed.kind]: Math.max(0, (c[removed.kind as Kind] ?? 0) - 1),
          }));
          return prev.filter((i) => i.id !== itemId);
        });
        setRemoving((prev) => {
          const next = new Set(prev);
          next.delete(itemId);
          return next;
        });
        // Refresh RSC (sidebar badge) after card is gone
        router.refresh();
      }, FADE_MS + 50);
    },
    [router]
  );

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
                    background: isActive ? "var(--accent)" : "var(--fg-subtle)",
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
            <AnimatedCard
              key={item.id}
              item={item}
              removing={removing.has(item.id)}
              onAction={handleAction}
            />
          ))}
        </div>
      )}
    </div>
  );
}
