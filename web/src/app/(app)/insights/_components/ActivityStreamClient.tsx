"use client";

import { useState } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";

type ActivityItem = {
  id: string;
  verb: string;
  subject: string;
  target_type: string | null;
  target_id: string | null;
  created_at: string;
};

interface Props {
  initialItems: ActivityItem[];
  verbOptions: string[];
  activeVerb: string | null;
  range: string;
  initialNextCursor: string | null;
  initialHasMore: boolean;
}

function fmtRelative(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime();
  const diffMin = Math.floor(diffMs / 60_000);
  if (diffMin < 1) return "Just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffH = Math.floor(diffMin / 60);
  if (diffH < 24) return `${diffH}h ago`;
  const diffD = Math.floor(diffH / 24);
  if (diffD === 1) return "Yesterday";
  return `${diffD}d ago`;
}

function verbLabel(verb: string): string {
  return verb.replace(/_/g, " ");
}

export function ActivityStreamClient({
  initialItems,
  verbOptions,
  activeVerb,
  range,
  initialNextCursor,
  initialHasMore,
}: Props) {
  const [items, setItems] = useState(initialItems);
  const [nextCursor, setNextCursor] = useState(initialNextCursor);
  const [hasMore, setHasMore] = useState(initialHasMore);
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  function setFilter(verb: string | null) {
    const params = new URLSearchParams(searchParams.toString());
    params.set("section", "activity");
    params.set("range", range);
    if (verb) {
      params.set("type", verb);
    } else {
      params.delete("type");
    }
    router.push(`${pathname}?${params.toString()}`);
  }

  async function loadMore() {
    if (!nextCursor || loading) return;
    setLoading(true);
    try {
      const params = new URLSearchParams({ cursor: nextCursor, limit: "20" });
      if (activeVerb) params.set("type", activeVerb);
      const res = await fetch(`/api/activities?${params.toString()}`);
      if (!res.ok) return;
      const data = await res.json();
      setItems((prev) => [...prev, ...(data.items ?? [])]);
      setNextCursor(data.next_cursor ?? null);
      setHasMore(data.has_more ?? false);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div>
      {/* Filter chips */}
      {verbOptions.length > 0 && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 16 }}>
          <FilterChip
            label="All"
            active={!activeVerb}
            onClick={() => setFilter(null)}
          />
          {verbOptions.map((v) => (
            <FilterChip
              key={v}
              label={verbLabel(v)}
              active={activeVerb === v}
              onClick={() => setFilter(v)}
            />
          ))}
        </div>
      )}

      {/* Activity list */}
      {items.length === 0 ? (
        <div style={{ textAlign: "center", padding: "32px 0", color: "var(--fg-subtle)", fontSize: "0.875rem" }}>
          No activities found{activeVerb ? ` for "${verbLabel(activeVerb)}"` : ""}.
        </div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column" }}>
          {items.map((item, i) => (
            <div key={item.id}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 10, padding: "10px 0" }}>
                <span style={{
                  fontSize: "0.7rem",
                  color: "var(--fg-subtle)",
                  flexShrink: 0,
                  minWidth: 64,
                  fontVariantNumeric: "tabular-nums",
                }}>
                  {fmtRelative(item.created_at)}
                </span>
                <span style={{
                  display: "inline-flex",
                  alignItems: "center",
                  fontSize: "0.7rem",
                  fontWeight: 500,
                  padding: "2px 6px",
                  borderRadius: 4,
                  background: "var(--accent-soft)",
                  color: "var(--accent)",
                  flexShrink: 0,
                }}>
                  {verbLabel(item.verb)}
                </span>
                <span style={{ fontSize: "0.875rem", color: "var(--fg-primary)", flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                  {item.subject}
                </span>
              </div>
              {i < items.length - 1 && (
                <div style={{ height: 1, background: "var(--accent-border)", opacity: 0.5 }} />
              )}
            </div>
          ))}
        </div>
      )}

      {/* Load more */}
      {hasMore && (
        <div style={{ textAlign: "center", marginTop: 16 }}>
          <button
            onClick={loadMore}
            disabled={loading}
            style={{
              padding: "8px 20px",
              borderRadius: "var(--radius-pill)",
              border: "1px solid var(--accent-border)",
              background: "transparent",
              color: "var(--fg-muted)",
              fontSize: "0.8125rem",
              cursor: loading ? "not-allowed" : "pointer",
              opacity: loading ? 0.6 : 1,
            }}
          >
            {loading ? "Loading…" : "Load more"}
          </button>
        </div>
      )}
    </div>
  );
}

function FilterChip({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      style={{
        padding: "4px 10px",
        borderRadius: "var(--radius-pill)",
        border: `1px solid ${active ? "var(--accent)" : "var(--accent-border)"}`,
        background: active ? "var(--accent-soft)" : "transparent",
        color: active ? "var(--accent)" : "var(--fg-muted)",
        fontSize: "0.75rem",
        fontWeight: active ? 600 : 400,
        cursor: "pointer",
        transition: "all 120ms ease-out",
      }}
    >
      {label}
    </button>
  );
}
