"use client";

import { useEffect, useState, useCallback } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  FileText,
  Loader2,
  CheckCircle2,
  AlertCircle,
  RefreshCw,
  X,
} from "lucide-react";
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

async function switchIngestMode(
  memoId: string,
  mode: "light" | "full",
): Promise<void> {
  const res = await fetch(`/api/memos/${memoId}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ingest_mode: mode }),
  });
  if (!res.ok) throw new Error("Switch failed");
  // Trigger recompile after mode switch
  await recompileMemo(memoId);
}

// --- Toast ---------------------------------------------------------------

interface Toast {
  id: number;
  message: string;
}

let toastCounter = 0;

function ToastContainer({
  toasts,
  onDismiss,
}: {
  toasts: Toast[];
  onDismiss: (id: number) => void;
}) {
  if (toasts.length === 0) return null;
  return (
    <div
      style={{
        position: "fixed",
        bottom: "1.5rem",
        right: "1.5rem",
        display: "flex",
        flexDirection: "column",
        gap: "0.5rem",
        zIndex: 9999,
      }}
    >
      {toasts.map((t) => (
        <div
          key={t.id}
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.75rem",
            padding: "0.625rem 1rem",
            background: "var(--fg-primary)",
            color: "var(--bg-warm)",
            borderRadius: "var(--radius-sm)",
            fontSize: "0.875rem",
            fontWeight: 500,
            boxShadow: "0 4px 16px rgba(0,0,0,0.14)",
            minWidth: "220px",
          }}
        >
          <span style={{ flex: 1 }}>{t.message}</span>
          <button
            onClick={() => onDismiss(t.id)}
            style={{
              background: "none",
              border: "none",
              cursor: "pointer",
              color: "inherit",
              opacity: 0.6,
              padding: 0,
              lineHeight: 1,
            }}
          >
            <X size={14} />
          </button>
        </div>
      ))}
    </div>
  );
}

// --- EmptyState -----------------------------------------------------------

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
      <p
        style={{
          margin: 0,
          fontWeight: 500,
          color: "var(--fg-muted)",
          fontSize: "0.9375rem",
        }}
      >
        No items yet
      </p>
      <p
        style={{ margin: 0, fontSize: "0.8125rem", color: "var(--fg-subtle)" }}
      >
        Submitted content will appear here while being compiled.
      </p>
    </div>
  );
}

// --- CompileQueue --------------------------------------------------------

export function CompileQueue({ initialMemos }: { initialMemos: Memo[] }) {
  const queryClient = useQueryClient();
  const progressMap = useCompileStream();

  const [removing, setRemoving] = useState<Set<string>>(new Set());
  const [toasts, setToasts] = useState<Toast[]>([]);

  const showToast = useCallback((message: string) => {
    const id = ++toastCounter;
    setToasts((prev) => [...prev, { id, message }]);
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 3000);
  }, []);

  const dismissToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

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

  const switchModeMutation = useMutation({
    mutationFn: ({
      memoId,
      mode,
    }: {
      memoId: string;
      mode: "light" | "full";
    }) => switchIngestMode(memoId, mode),
    onSuccess: (_data, variables) => {
      showToast(
        `Switched to ${variables.mode.toUpperCase()} mode — recompiling…`,
      );
      void queryClient.invalidateQueries({ queryKey: ["memos", "pending"] });
      void queryClient.invalidateQueries({ queryKey: ["memos", "done"] });
    },
    onError: () => {
      showToast("Failed to switch mode. Please try again.");
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
          void queryClient.invalidateQueries({
            queryKey: ["memos", "pending"],
          });
          void queryClient.invalidateQueries({ queryKey: ["memos", "done"] });
        }, 3000);
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [progressMap]);

  const items = data?.items ?? [];

  const visible = items.filter((m) => {
    const p = progressMap.get(m.id);
    if (p?.status === "done" && !removing.has(m.id)) return false;
    return true;
  });

  return (
    <>
      {visible.length === 0 && items.length === 0 ? (
        <EmptyState />
      ) : (
        <div
          style={{ display: "flex", flexDirection: "column", gap: "0.5rem" }}
        >
          {visible.map((memo) => (
            <MemoRow
              key={memo.id}
              memo={memo}
              progress={progressMap.get(memo.id)}
              onRetry={() => recompileMutation.mutate(memo.id)}
              isRetrying={
                recompileMutation.isPending &&
                recompileMutation.variables === memo.id
              }
              onSwitchMode={(mode) =>
                switchModeMutation.mutate({ memoId: memo.id, mode })
              }
              isSwitching={
                switchModeMutation.isPending &&
                switchModeMutation.variables?.memoId === memo.id
              }
            />
          ))}
        </div>
      )}
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </>
  );
}

// --- MemoRow -------------------------------------------------------------

function MemoRow({
  memo,
  progress,
  onRetry,
  isRetrying,
  onSwitchMode,
  isSwitching,
}: {
  memo: Memo;
  progress: MemoProgress | undefined;
  onRetry: () => void;
  isRetrying: boolean;
  onSwitchMode: (mode: "light" | "full") => void;
  isSwitching: boolean;
}) {
  const preview = memo.body.slice(0, 90) + (memo.body.length > 90 ? "…" : "");
  const date = new Date(memo.created_at).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });

  const status = progress?.status ?? memo.compile_status;
  const step = progress?.step;
  const progressPct = progress?.progress;
  const errorMsg = progress?.error;

  const isDone = status === "done";
  const isFailed = status === "failed";
  const isRunning = status === "running";

  const currentMode = memo.ingest_mode as "light" | "full";
  const nextMode: "light" | "full" = currentMode === "light" ? "full" : "light";

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
      {/* Top row: icon + text + mode chip + status chip */}
      <div
        style={{ display: "flex", alignItems: "flex-start", gap: "0.75rem" }}
      >
        {/* Status icon */}
        <div style={{ flexShrink: 0, marginTop: "0.125rem" }}>
          {isDone ? (
            <CheckCircle2
              size={16}
              style={{ color: "var(--success, #16a34a)" }}
            />
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
          <p
            style={{
              margin: "0.25rem 0 0",
              fontSize: "0.75rem",
              color: "var(--fg-subtle)",
            }}
          >
            {memo.type} · {date}
          </p>
        </div>

        {/* LIGHT/FULL mode chip — click to toggle */}
        <button
          title={`Switch to ${nextMode.toUpperCase()} mode`}
          disabled={isSwitching || isDone}
          onClick={() => onSwitchMode(nextMode)}
          className="chip"
          style={{
            fontSize: "0.6875rem",
            flexShrink: 0,
            textTransform: "uppercase",
            letterSpacing: "0.06em",
            cursor: isDone ? "default" : "pointer",
            opacity: isSwitching ? 0.5 : 1,
            background:
              currentMode === "full"
                ? "var(--accent-soft, #eff6ff)"
                : "var(--surface-sunken, #fafaf9)",
            color:
              currentMode === "full"
                ? "var(--accent, #2563eb)"
                : "var(--fg-muted)",
            border: `1px solid ${
              currentMode === "full"
                ? "var(--accent-border, #bfdbfe)"
                : "var(--surface-border, #e5e4e0)"
            }`,
            transition: "opacity 0.2s",
          }}
        >
          {isSwitching ? "…" : currentMode}
        </button>

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

      {/* Done: "Compilation complete" line */}
      {isDone && (
        <p
          style={{
            margin: 0,
            fontSize: "0.75rem",
            color: "var(--success, #16a34a)",
          }}
        >
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
            style={{
              fontSize: "0.75rem",
              padding: "0.25rem 0.625rem",
              flexShrink: 0,
            }}
          >
            <RefreshCw size={12} style={{ marginRight: "0.25rem" }} />
            {isRetrying ? "Retrying…" : "Retry"}
          </button>
        </div>
      )}
    </div>
  );
}
