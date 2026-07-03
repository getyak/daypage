"use client";

import { useEffect, useState, useCallback } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Loader2,
  CheckCircle2,
  AlertCircle,
  RefreshCw,
  X,
  Inbox,
} from "lucide-react";
import Link from "next/link";
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

interface CompileStatusResponse {
  connected: boolean;
}

async function fetchCompileServiceStatus(): Promise<CompileStatusResponse> {
  const res = await fetch("/api/compile/status");
  if (!res.ok) throw new Error("Failed to fetch compile status");
  return res.json() as Promise<CompileStatusResponse>;
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
    <div className="empty-card">
      <Inbox size={20} className="empty-card__icon" />
      <div className="empty-card__title">Nothing in the queue</div>
      <div className="empty-card__hint">
        Paste a URL above or press <kbd>⌘N</kbd> from anywhere to add something.
      </div>
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

  // Whether the compile pipeline (Inngest) is actually reachable. In local dev
  // without INNGEST_EVENT_KEY, sendEvent() no-ops, so pending memos never move.
  const { data: serviceStatus } = useQuery<CompileStatusResponse>({
    queryKey: ["compile", "service-status"],
    queryFn: fetchCompileServiceStatus,
    staleTime: 60_000,
  });
  const serviceConnected = serviceStatus?.connected ?? true;

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
        // eslint-disable-next-line react-hooks/set-state-in-effect
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
        <div>
          {visible.map((memo) => (
            <MemoRow
              key={memo.id}
              memo={memo}
              progress={progressMap.get(memo.id)}
              serviceConnected={serviceConnected}
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
  serviceConnected,
  onRetry,
  isRetrying,
  onSwitchMode,
  isSwitching,
}: {
  memo: Memo;
  progress: MemoProgress | undefined;
  serviceConnected: boolean;
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
  const isPending = status === "pending";
  // In local dev without Inngest, a "pending" memo never actually moves — say so
  // instead of showing a deceptive QUEUED badge.
  const showDisconnected = isPending && !serviceConnected;

  const currentMode = memo.ingest_mode as "light" | "full";
  const nextMode: "light" | "full" = currentMode === "light" ? "full" : "light";

  const iconClass = isRunning ? "queue-item__icon is-fetching" : "queue-item__icon";
  const showWarnIcon = isFailed || showDisconnected;

  return (
    <Link
      href={`/memos/${memo.id}`}
      className="queue-item"
      aria-label={`View memo: ${preview}`}
      onKeyDown={(e) => {
        if (e.key === " ") {
          e.preventDefault();
          e.currentTarget.click();
        }
      }}
    >
      {/* Status icon */}
      <div className={iconClass}>
        {isDone ? (
          <CheckCircle2 size={16} />
        ) : showWarnIcon ? (
          <AlertCircle size={16} />
        ) : (
          <Loader2
            size={16}
            style={{ animation: isRunning ? "spin 1s linear infinite" : "none" }}
          />
        )}
      </div>

      {/* Title + subtitle */}
      <div className="queue-item__main">
        <div className="queue-item__title">
          {preview}
          {isPending && !showDisconnected && (
            <span
              className="ds-mono-11"
              style={{
                marginLeft: "0.5rem",
                padding: "0.1rem 0.35rem",
                background: "var(--surface-3, #ececec)",
                borderRadius: "var(--radius-sm)",
                color: "var(--fg-subtle)",
                letterSpacing: "0.06em",
                verticalAlign: "middle",
              }}
            >
              QUEUED
            </span>
          )}
        </div>
        {/* v9 refactor: no more per-row "编译服务未连接" — a single banner
            at the top of /add carries that signal (see
            CompileServiceBanner). Rows here keep only the concrete state:
            failure message when failed, live step when running, or a
            terse "等待编译" fallback while pipeline is down. */}
        <div className="queue-item__sub">
          {memo.type} · {date}
          {showDisconnected ? " · 等待编译" : ""}
          {isFailed && errorMsg ? ` · ${errorMsg}` : ""}
          {isDone ? " · Compilation complete" : ""}
          {!isDone && !isFailed && !showDisconnected && step ? ` · ${step}` : ""}
        </div>
      </div>

      {/* Progress bar (always reserves the column; full=done, 0=failed/disconnected) */}
      <div className="queue-progress" aria-hidden={isDone || isFailed || showDisconnected}>
        <div
          className="queue-progress__bar"
          style={{
            width:
              isDone
                ? "100%"
                : isFailed || showDisconnected
                  ? "0%"
                  : `${progressPct ?? 0}%`,
          }}
        />
      </div>

      {/* Right rail: mode chip + (failed → Retry) */}
      <div
        style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* v9 semantic pill — same tokens as RecentlyCompiled (light=success,
            full=accent) so the queue -> compiled transition doesn't jump
            visual language. chip--interactive still carries the switch UX. */}
        <button
          type="button"
          title={`Switch to ${nextMode.toUpperCase()} mode`}
          disabled={isSwitching || isDone}
          onClick={(e) => {
            e.stopPropagation();
            e.preventDefault();
            onSwitchMode(nextMode);
          }}
          data-mode={currentMode}
          className={
            currentMode === "full"
              ? "chip chip--accent chip--interactive ds-add-mode-pill"
              : "chip chip--success chip--interactive ds-add-mode-pill"
          }
          style={{
            textTransform: "uppercase",
            letterSpacing: "0.08em",
            fontFamily: "var(--font-mono, monospace)",
            fontWeight: 600,
            cursor: isDone ? "default" : "pointer",
            opacity: isSwitching ? 0.5 : 1,
          }}
        >
          {isSwitching ? "…" : currentMode.toUpperCase()}
        </button>
        {isFailed && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              e.preventDefault();
              onRetry();
            }}
            disabled={isRetrying}
            className="btn btn--secondary btn--sm"
          >
            <RefreshCw size={12} style={{ marginRight: "0.25rem" }} />
            {isRetrying ? "Retrying…" : "Retry"}
          </button>
        )}
      </div>
    </Link>
  );
}
