"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { FileText } from "lucide-react";
import Link from "next/link";
import type { Memo } from "./CompileQueue";

interface MemosResponse {
  items: Memo[];
}

function wordCount(text: string): number {
  return text.trim().split(/\s+/).filter(Boolean).length;
}

function relativeTime(date: Date): string {
  const diff = Date.now() - date.getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

async function fetchDoneMemos(): Promise<MemosResponse> {
  const res = await fetch("/api/memos?compile_status=done&limit=8");
  if (!res.ok) throw new Error("Failed to fetch");
  return res.json() as Promise<MemosResponse>;
}

export function RecentlyCompiled({ initialMemos }: { initialMemos: Memo[] }) {
  const queryClient = useQueryClient();

  const { data } = useQuery<MemosResponse>({
    queryKey: ["memos", "done"],
    queryFn: fetchDoneMemos,
    initialData: { items: initialMemos },
    refetchInterval: 15_000,
  });

  // Expose invalidation so CompileQueue can trigger a refresh on done events
  void queryClient;

  const items = data?.items ?? [];

  if (items.length === 0) {
    return (
      <div className="empty-card">
        <FileText size={20} className="empty-card__icon" />
        <div className="empty-card__title">Nothing compiled yet</div>
        <div className="empty-card__hint">Finished items will appear here.</div>
      </div>
    );
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "0" }}>
      {items.map((memo, i) => {
        const title =
          memo.body.slice(0, 90) + (memo.body.length > 90 ? "…" : "");
        const wc = wordCount(memo.body);
        const time = relativeTime(new Date(memo.created_at));
        return (
          <Link
            key={memo.id}
            href={`/memos/${memo.id}`}
            aria-label={`View memo: ${title}`}
            onKeyDown={(e) => {
              if (e.key === " ") {
                e.preventDefault();
                e.currentTarget.click();
              }
            }}
            style={{
              display: "flex",
              alignItems: "center",
              gap: "0.75rem",
              padding: "0.625rem 0",
              borderBottom:
                i < items.length - 1
                  ? "1px solid var(--surface-border, var(--accent-border))"
                  : "none",
              cursor: "pointer",
              textDecoration: "none",
              color: "inherit",
            }}
            className="recently-compiled-item"
          >
            <FileText
              size={14}
              style={{ color: "var(--fg-subtle)", flexShrink: 0 }}
            />
            <div style={{ flex: 1, minWidth: 0 }}>
              <p
                style={{
                  margin: 0,
                  fontSize: "0.875rem",
                  color: "var(--fg-primary)",
                  whiteSpace: "nowrap",
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                }}
              >
                {title}
              </p>
              <p
                style={{
                  margin: "0.125rem 0 0",
                  fontSize: "0.75rem",
                  color: "var(--fg-subtle)",
                }}
              >
                {memo.type} · {wc} words · {time}
              </p>
            </div>
            {/* v9 semantic pill — light=success (quick pass), full=accent
                (deep dive). Uses shared .chip--success/.chip--accent tokens
                so dark mode + accessibility stay in one place. */}
            <span
              className={
                memo.ingest_mode === "full"
                  ? "chip chip--accent ds-add-mode-pill"
                  : "chip chip--success ds-add-mode-pill"
              }
              data-mode={memo.ingest_mode}
              style={{
                fontSize: "0.6875rem",
                flexShrink: 0,
                textTransform: "uppercase",
                letterSpacing: "0.08em",
                fontFamily: "var(--font-mono, monospace)",
                fontWeight: 600,
              }}
            >
              {memo.ingest_mode}
            </span>
            <span
              style={{
                fontSize: "0.75rem",
                color: "var(--fg-subtle)",
                flexShrink: 0,
                whiteSpace: "nowrap",
              }}
            >
              {time}
            </span>
          </Link>
        );
      })}
    </div>
  );
}
