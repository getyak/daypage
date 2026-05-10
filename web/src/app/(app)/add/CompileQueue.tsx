"use client";

import { useQuery } from "@tanstack/react-query";
import { FileText, Loader2 } from "lucide-react";

export interface Memo {
  id: string;
  body: string;
  type: string;
  compile_status: string;
  ingest_mode: string;
  created_at: string;
}

interface MemosResponse {
  items: Memo[];
}

async function fetchPendingMemos(): Promise<MemosResponse> {
  const res = await fetch("/api/memos?compile_status=pending&limit=20");
  if (!res.ok) throw new Error("Failed to fetch");
  return res.json() as Promise<MemosResponse>;
}

function EmptyState({
  icon,
  message,
  sub,
}: {
  icon: React.ReactNode;
  message: string;
  sub: string;
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: "0.5rem",
        padding: "2rem 1rem",
        textAlign: "center",
      }}
    >
      {icon}
      <p
        style={{
          margin: 0,
          fontWeight: 500,
          color: "var(--fg-muted)",
          fontSize: "0.9375rem",
        }}
      >
        {message}
      </p>
      <p style={{ margin: 0, fontSize: "0.8125rem", color: "var(--fg-subtle)" }}>
        {sub}
      </p>
    </div>
  );
}

export function CompileQueue({ initialMemos }: { initialMemos: Memo[] }) {
  const { data } = useQuery<MemosResponse>({
    queryKey: ["memos", "pending"],
    queryFn: fetchPendingMemos,
    initialData: { items: initialMemos },
    refetchInterval: 5_000,
  });

  const items = data?.items ?? [];

  if (items.length === 0) {
    return (
      <EmptyState
        icon={<FileText size={20} style={{ color: "var(--fg-subtle)" }} />}
        message="No items yet"
        sub="Submitted content will appear here while being compiled."
      />
    );
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "0.5rem" }}>
      {items.map((memo) => (
        <MemoRow key={memo.id} memo={memo} />
      ))}
    </div>
  );
}

function MemoRow({ memo }: { memo: Memo }) {
  const preview = memo.body.slice(0, 90) + (memo.body.length > 90 ? "…" : "");
  const date = new Date(memo.created_at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });

  return (
    <div
      style={{
        display: "flex",
        alignItems: "flex-start",
        gap: "0.75rem",
        padding: "0.75rem",
        borderRadius: "var(--radius-sm)",
        background: "var(--surface-sunken)",
        border: "1px solid var(--surface-border, var(--accent-border))",
      }}
    >
      <Loader2
        size={16}
        style={{
          color: "var(--accent)",
          flexShrink: 0,
          marginTop: "0.125rem",
          animation: "spin 1s linear infinite",
        }}
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
          {preview}
        </p>
        <p
          style={{
            margin: "0.25rem 0 0",
            fontSize: "0.75rem",
            color: "var(--fg-subtle)",
          }}
        >
          {memo.type} · {memo.ingest_mode} · {date}
        </p>
      </div>
      <span
        className="chip"
        style={{ fontSize: "0.75rem", flexShrink: 0 }}
      >
        pending
      </span>
    </div>
  );
}
