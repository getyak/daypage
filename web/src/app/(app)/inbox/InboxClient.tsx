"use client";

import { useState, useCallback, useRef } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Inbox } from "lucide-react";
import { Btn } from "@/components/ui";
import type { InboxItem } from "@/lib/db/schema";

type Kind = "contradiction" | "schema" | "orphan" | "compiled" | "gap";

interface InboxClientProps {
  items: InboxItem[];
  counts: Record<Kind | "all", number>;
}

const KIND_CHIPS: { key: Kind | "all"; label: string }[] = [
  { key: "all", label: "All" },
  { key: "contradiction", label: "Contradictions" },
  { key: "schema", label: "Schema" },
  { key: "orphan", label: "Orphans" },
  { key: "gap", label: "Gaps" },
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
    gap: { label: "Gap", cls: "chip chip--accent" },
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

interface GapClusterPayload {
  page_ids?: string[];
  titles?: string[];
}

interface GapPayload {
  question?: string;
  similarity?: number;
  cluster_a?: GapClusterPayload;
  cluster_b?: GapClusterPayload;
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
  const [busy, setBusy] = useState(false);

  const resolve = useCallback(
    async (action: string) => {
      if (busy) return;
      setBusy(true);
      const ok = await postAction(item.id, "resolve", { action });
      setBusy(false);
      if (ok) onAction(item.id);
    },
    [busy, item.id, onAction]
  );

  return (
    <div className="card inbox-card">
      <div className="inbox-card__head">
        <KindChip kind="contradiction" />
        <span className="inbox-card__time">{formatRelative(item.created_at)}</span>
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>
      <div className="inbox-card__title">{item.title}</div>
      {item.body && <div className="inbox-card__body">{item.body}</div>}

      {/* Side-by-side old/new compare */}
      {(payload.old_text || payload.new_text) && (
        <div className="inbox-conflict">
          <div className="conflict-pane">
            <div className="conflict-pane__lbl">Old</div>
            <div>{payload.old_text ?? "—"}</div>
          </div>
          <div className="conflict-pane conflict-pane--new">
            <div className="conflict-pane__lbl">New</div>
            <div>{payload.new_text ?? "—"}</div>
          </div>
        </div>
      )}

      <div
        className="inbox-card__actions"
        aria-busy={busy}
        style={busy ? { opacity: 0.5, cursor: "not-allowed", pointerEvents: "none" } : undefined}
      >
        <button className="btn btn--soft btn--sm" disabled={busy} onClick={() => resolve("keep_both")}>
          Keep both
        </button>
        <button className="btn btn--primary btn--sm" disabled={busy} onClick={() => resolve("use_new")}>
          Use new
        </button>
        <button className="btn btn--secondary btn--sm" disabled={busy} onClick={() => resolve("keep_mine")}>
          Keep mine
        </button>
        {payload.page_id && (
          <a
            href={`/wiki?id=${payload.page_id}`}
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
  const [busy, setBusy] = useState(false);

  const resolve = useCallback(
    async (action: string) => {
      if (busy) return;
      setBusy(true);
      const ok = await postAction(item.id, "resolve", { action });
      setBusy(false);
      if (ok) onAction(item.id);
    },
    [busy, item.id, onAction]
  );

  return (
    <div className="card inbox-card">
      <div className="inbox-card__head">
        <KindChip kind="schema" />
        <span className="inbox-card__time">{formatRelative(item.created_at)}</span>
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>
      <div className="inbox-card__title">{item.title}</div>
      {item.body && <div className="inbox-card__body">{item.body}</div>}

      {/* Domain name + color preview */}
      {payload.suggested_name && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.75rem",
            padding: "0.75rem",
            marginTop: "0.75rem",
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

      <div
        className="inbox-card__actions"
        aria-busy={busy}
        style={busy ? { opacity: 0.5, cursor: "not-allowed", pointerEvents: "none" } : undefined}
      >
        <button
          className="btn btn--primary btn--sm"
          disabled={busy}
          onClick={() => resolve("create_domain")}
        >
          Create domain
        </button>
        <button
          className="btn btn--secondary btn--sm"
          disabled={busy}
          onClick={() => resolve("suggest_different_name")}
        >
          Suggest different name
        </button>
        <button className="btn btn--ghost btn--sm" disabled={busy} onClick={() => resolve("not_yet")}>
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
    <div className="card inbox-card">
      <div className="inbox-card__head">
        <KindChip kind="orphan" />
        {payload.days_idle !== undefined && (
          <span className="chip chip--warning">
            {payload.days_idle} days idle
          </span>
        )}
        <span className="inbox-card__time">{formatRelative(item.created_at)}</span>
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>
      <div className="inbox-card__title">{item.title}</div>
      {item.body && <div className="inbox-card__body">{item.body}</div>}

      <div className="inbox-card__actions">
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
            href={`/wiki?id=${payload.page_id}`}
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

function ClusterPills({ titles }: { titles?: string[] }) {
  if (!titles || titles.length === 0) return <span style={{ color: "var(--fg-subtle)" }}>—</span>;
  const shown = titles.slice(0, 4);
  const extra = titles.length - shown.length;
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: "0.25rem" }}>
      {shown.map((t, i) => (
        <span key={i} className="chip chip--default" style={{ fontSize: "0.6875rem" }}>
          {t}
        </span>
      ))}
      {extra > 0 && (
        <span className="ds-mono-11" style={{ color: "var(--fg-subtle)", alignSelf: "center" }}>
          +{extra} more
        </span>
      )}
    </div>
  );
}

function GapCard({
  item,
  onAction,
}: {
  item: InboxItem;
  onAction: (id: string) => void;
}) {
  const payload = (item.payload ?? {}) as GapPayload;
  const [busy, setBusy] = useState(false);

  const resolve = useCallback(
    async (action: string) => {
      if (busy) return;
      setBusy(true);
      const ok = await postAction(item.id, "resolve", { action });
      setBusy(false);
      if (ok) onAction(item.id);
    },
    [busy, item.id, onAction]
  );

  return (
    <div className="card inbox-card">
      <div className="inbox-card__head">
        <KindChip kind="gap" />
        <span className="inbox-card__time">{formatRelative(item.created_at)}</span>
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>
      <div className="inbox-card__title">{item.title}</div>
      {item.body && <div className="inbox-card__body">{item.body}</div>}

      {/* Two unconnected clusters */}
      {(payload.cluster_a || payload.cluster_b) && (
        <div
          style={{
            display: "flex",
            alignItems: "stretch",
            gap: "0.5rem",
            marginTop: "0.75rem",
          }}
        >
          <div
            style={{
              flex: 1,
              padding: "0.625rem",
              background: "var(--surface-sunken)",
              borderRadius: "var(--radius-sm)",
            }}
          >
            <div className="ds-mono-11" style={{ color: "var(--fg-subtle)", marginBottom: "0.375rem" }}>
              Cluster A
            </div>
            <ClusterPills titles={payload.cluster_a?.titles} />
          </div>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              color: "var(--accent)",
              fontWeight: 700,
              fontSize: "1.125rem",
            }}
            aria-hidden
          >
            ⇄
          </div>
          <div
            style={{
              flex: 1,
              padding: "0.625rem",
              background: "var(--surface-sunken)",
              borderRadius: "var(--radius-sm)",
            }}
          >
            <div className="ds-mono-11" style={{ color: "var(--fg-subtle)", marginBottom: "0.375rem" }}>
              Cluster B
            </div>
            <ClusterPills titles={payload.cluster_b?.titles} />
          </div>
        </div>
      )}

      <div
        className="inbox-card__actions"
        aria-busy={busy}
        style={busy ? { opacity: 0.5, cursor: "not-allowed", pointerEvents: "none" } : undefined}
      >
        <button
          className="btn btn--primary btn--sm"
          disabled={busy}
          onClick={() => resolve("reflect")}
        >
          Reflect on this
        </button>
        <button className="btn btn--ghost btn--sm" disabled={busy} onClick={() => resolve("ignore")}>
          Ignore
        </button>
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
    <div className="card inbox-card">
      <div className="inbox-card__head">
        <KindChip kind="compiled" />
        <span className="inbox-card__time">{formatRelative(item.created_at)}</span>
        <SnoozeMenu itemId={item.id} onAction={onAction} />
      </div>
      <div className="inbox-card__title">{item.title}</div>
      {item.body && <div className="inbox-card__body">{item.body}</div>}

      <div className="inbox-card__actions">
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
    case "gap":
      return <GapCard item={item} onAction={onAction} />;
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
          Decisions I&apos;d like you to weigh in on.
        </h1>
        <p
          className="ds-body-md"
          style={{ color: "var(--fg-muted)", marginTop: 8, maxWidth: "42em" }}
        >
          Contradictions, structural suggestions, and finished work. The wiki keeps
          moving while you&apos;re away — but anything that would change{" "}
          <em>what you believe</em> waits here for you.
        </p>
      </div>

      {/* Filter chips */}
      <div className="inbox-filters">
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
          className="empty-card"
          style={{ padding: "48px 32px", maxWidth: 560, margin: "0 auto" }}
        >
          <Inbox size={24} className="empty-card__icon" />
          <div className="empty-card__title" style={{ fontSize: 16 }}>
            Nothing waiting on you — yet.
          </div>
          <div className="empty-card__hint">
            When I find a contradiction in your sources, propose a new domain, or
            finish compiling a page, it&apos;ll land here.
          </div>
          <div className="flex gap-12" style={{ marginTop: 16 }}>
            <Link href="/add">
              <Btn kind="primary" size="sm">
                Add a memo
              </Btn>
            </Link>
            <Link href="/wiki">
              <Btn kind="ghost" size="sm">
                Browse wiki
              </Btn>
            </Link>
          </div>
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
