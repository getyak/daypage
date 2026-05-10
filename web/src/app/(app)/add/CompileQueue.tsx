"use client";

import { useEffect, useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { FileText, Loader2, CheckCircle2, AlertCircle, RefreshCw } from "lucide-react";
import { useCompileStream, type MemoProgress } from "@/hooks/useCompileStream";

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

async function recompileMemo(memoId: string): Promise<void> {
  const res = await fetch(`/api/memos/${memoId}/recompile`, { method: "POST" });
  if (!res.ok) throw new Error("Recompile failed");
}

function EmptyState() {
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
      <FileText size={20} style={{ color: "var(--fg-subtle)" }} />
      <p style={{ margin: 0, fontWeight: 500, color: "var(--fg-muted)", fontSize: "0.9375rem" }}>
        No items yet
      </p>
      <p style={{ margin: 0, fontSize: "0.8125rem", color: "var(--fg-subtle)" }}>
        Submitted content will appear here while being compiled.
      </p>
    </div>
  );
}

export function CompileQueue({ initialMemos }: { initialMemos: Memo[] }) {
  const queryClient = useQueryClient();
  const progressMap = useCompileStream();

  // IDs that finished (done) and are staged for auto-removal after 3s
  const [removing, setRemoving] = useState<Set<string>>(new Set());

  const { data } = useQuery<MemosResponse>({
    queryKey: ["memos", "pending"],
    queryFn: fetchPendingMemos,
    initialData: { items: initialMemos },
    refetchInterval: 10_000,
  });

  const recompileMutation = useMutation({
    mutationFn: recompileMemo,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["memos", "pending"] });
    },
  });

  // When SSE reports a memo is "done", schedule removal after 3s
  useEffect(() => {
    for (const [memoId, progress] of progressMap.entries()) {
      if (progress.status === "done" && !removing.has(memoId)) {
        setRemoving((prev) => new Set([...prev, memoId]));
        setTimeout(() => {
          setRemoving((prev) => {
            const next = new Set(prev);
            next.delete(memoId);
            return next;
          });
          void queryClient.invalidateQueries({ queryKey: ["memos", "pending"] });
        }, 3000);
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [progressMap]);

  const items = data?.items ?? [];

  // Filter out items that have been done and removed
  const visible = items.filter((m) => {
    const p = progressMap.get(m.id);
    if (p?.status === "done" && !removing.has(m.id)) return false;
    return true;
  });

  if (visible.length === 0 && items.length === 0) {
    return <EmptyState />;
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "0.5rem" }}>
      {visible.map((memo) => (
        <MemoRow
          key={memo.id}
          memo={memo}
          progress={progressMap.get(memo.id)}
          onRetry={() => recompileMutation.mutate(memo.id)}
          isRetrying={recompileMutation.isPending && recompileMutation.variables === memo.id}
        />
      ))}
    </div>
  );
}

function MemoRow({
  memo,
  progress,
  onRetry,
  isRetrying,
}: {
  memo: Memo;
  progress: MemoProgress | undefined;
  onRetry: () => void;
  isRetrying: boolean;
}) {
  const preview = memo.body.slice(0, 90) + (memo.body.length > 90 ? "…" : "");
  const date = new Date(memo.created_at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });

  // Derive effective status from SSE progress or fall back to memo's DB status
  const status = progress?.status ?? memo.compile_status;
  const step = progress?.step;
  const progressPct = progress?.progress;
  const errorMsg = progress?.error;

  const isDone = status === "done";
  const isFailed = status === "failed";
  const isRunning = status === "running";

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        gap: "0.5rem",
        padding: "0.75rem",
        borderRadius: "var(--radius-sm)",
        background: isDone
          ? "var(--success-soft, #f0fdf4)"
          : isFailed
          ? "var(--error-soft, #fff1f2)"
          : "var(--surface-sunken)",
        border: `1px solid ${
          isDone
            ? "var(--success-border, #bbf7d0)"
            : isFailed
            ? "var(--error-border, #fecdd3)"
            : "var(--surface-border, var(--accent-border))"
        }`,
        transition: "background 0.3s, border-color 0.3s",
      }}
    >
      {/* Top row: icon + text + status badge */}
      <div style={{ display: "flex", alignItems: "flex-start", gap: "0.75rem" }}>
        {/* Status icon */}
        <div style={{ flexShrink: 0, marginTop: "0.125rem" }}>
          {isDone ? (
            <CheckCircle2 size={16} style={{ color: "var(--success, #16a34a)" }} />
          ) : isFailed ? (
            <AlertCircle size={16} style={{ color: "var(--error, #dc2626)" }} />
          ) : (
            <Loader2
              size={16}
              style={{
                color: "var(--accent)",
                animation: isRunning ? "spin 1s linear infinite" : "none",
              }}
            />
          )}
        </div>

        {/* Body preview */}
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
          <p style={{ margin: "0.25rem 0 0", fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
            {memo.type} · {memo.ingest_mode} · {date}
          </p>
        </div>

        {/* Status chip */}
        {isDone ? (
          <span
            className="chip"
            style={{
              fontSize: "0.75rem",
              flexShrink: 0,
              background: "var(--success-soft, #dcfce7)",
              color: "var(--success, #16a34a)",
              border: "1px solid var(--success-border, #bbf7d0)",
            }}
          >
            Done
          </span>
        ) : isFailed ? (
          <span
            className="chip"
            style={{
              fontSize: "0.75rem",
              flexShrink: 0,
              background: "var(--error-soft, #fff1f2)",
              color: "var(--error, #dc2626)",
              border: "1px solid var(--error-border, #fecdd3)",
            }}
          >
            {step ?? "Failed"}
          </span>
        ) : (
          <span className="chip" style={{ fontSize: "0.75rem", flexShrink: 0 }}>
            {step ?? status}
          </span>
        )}
      </div>

      {/* Progress bar (shown when running or pending) */}
      {!isDone && !isFailed && (
        <div
          style={{
            height: "3px",
            borderRadius: "2px",
            background: "var(--accent-border)",
            overflow: "hidden",
          }}
        >
          <div
            style={{
              height: "100%",
              width: `${progressPct ?? 0}%`,
              background: "var(--accent)",
              transition: "width 0.4s ease-out",
              borderRadius: "2px",
            }}
          />
        </div>
      )}

      {/* Done: "X pages updated" line */}
      {isDone && (
        <p style={{ margin: 0, fontSize: "0.75rem", color: "var(--success, #16a34a)" }}>
          Compilation complete
        </p>
      )}

      {/* Failed: error + Retry button */}
      {isFailed && (
        <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          {errorMsg && (
            <p
              style={{
                margin: 0,
                fontSize: "0.75rem",
                color: "var(--error, #dc2626)",
                flex: 1,
                whiteSpace: "nowrap",
                overflow: "hidden",
                textOverflow: "ellipsis",
              }}
            >
              {errorMsg}
            </p>
          )}
          <button
            onClick={onRetry}
            disabled={isRetrying}
            className="btn btn--secondary"
            style={{ fontSize: "0.75rem", padding: "0.25rem 0.625rem", flexShrink: 0 }}
          >
            <RefreshCw size={12} style={{ marginRight: "0.25rem" }} />
            {isRetrying ? "Retrying…" : "Retry"}
          </button>
        </div>
      )}
    </div>
  );
}
