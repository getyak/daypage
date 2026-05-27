"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

type Props = {
  memoId: string;
  compileStatus: string;
};

export function MemoActions({ memoId, compileStatus }: Props) {
  const router = useRouter();
  const [recompiling, setRecompiling] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleRecompile() {
    setRecompiling(true);
    setError(null);
    try {
      const res = await fetch(`/api/memos/${memoId}/recompile`, { method: "POST" });
      if (!res.ok) throw new Error("Recompile failed");
      router.refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to recompile");
    } finally {
      setRecompiling(false);
    }
  }

  async function handleDelete() {
    setDeleting(true);
    setError(null);
    try {
      const res = await fetch(`/api/memos/${memoId}`, { method: "DELETE" });
      if (!res.ok && res.status !== 204) throw new Error("Delete failed");
      router.push("/home");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to delete");
      setDeleting(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: 8, flexShrink: 0 }}>
      <div style={{ display: "flex", gap: 8 }}>
        <button
          onClick={handleRecompile}
          disabled={recompiling || compileStatus === "running"}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            padding: "6px 14px",
            borderRadius: 6,
            border: "1px solid var(--border)",
            background: "var(--surface)",
            color: recompiling ? "var(--fg-subtle)" : "var(--fg)",
            fontSize: "0.8125rem",
            cursor: recompiling ? "not-allowed" : "pointer",
            opacity: recompiling ? 0.6 : 1,
            transition: "opacity 0.15s",
          }}
        >
          {recompiling && (
            <span style={{ display: "inline-block", width: 12, height: 12, border: "2px solid var(--fg-subtle)", borderTopColor: "var(--accent)", borderRadius: "50%", animation: "spin 0.6s linear infinite" }} />
          )}
          {recompiling ? "Recompiling…" : "Recompile"}
        </button>

        <button
          onClick={() => setShowConfirm(true)}
          disabled={deleting}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            padding: "6px 14px",
            borderRadius: 6,
            border: "1px solid var(--error, #ef4444)",
            background: "transparent",
            color: "var(--error, #ef4444)",
            fontSize: "0.8125rem",
            cursor: deleting ? "not-allowed" : "pointer",
            opacity: deleting ? 0.6 : 1,
            transition: "opacity 0.15s",
          }}
        >
          {deleting && (
            <span style={{ display: "inline-block", width: 12, height: 12, border: "2px solid var(--error, #ef4444)", borderTopColor: "transparent", borderRadius: "50%", animation: "spin 0.6s linear infinite" }} />
          )}
          Delete
        </button>
      </div>

      {error && (
        <div style={{ fontSize: "0.75rem", color: "var(--error, #ef4444)" }}>{error}</div>
      )}

      {/* Confirm dialog */}
      {showConfirm && (
        <div
          style={{ position: "fixed", inset: 0, background: "rgba(0,0,0,0.4)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 50 }}
          onClick={() => setShowConfirm(false)}
        >
          <div
            style={{ background: "var(--surface-white, #fff)", borderRadius: 12, padding: "28px 32px", maxWidth: 380, width: "90%", boxShadow: "0 8px 32px rgba(0,0,0,0.18)" }}
            onClick={(e) => e.stopPropagation()}
          >
            <h2 style={{ fontSize: "1rem", fontWeight: 600, margin: "0 0 8px" }}>Delete this memo?</h2>
            <p style={{ fontSize: "0.875rem", color: "var(--fg-muted)", margin: "0 0 20px", lineHeight: 1.5 }}>
              This action is permanent and cannot be undone. The memo will be removed from all linked pages.
            </p>
            <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
              <button
                onClick={() => setShowConfirm(false)}
                style={{ padding: "6px 16px", borderRadius: 6, border: "1px solid var(--border)", background: "transparent", cursor: "pointer", fontSize: "0.875rem" }}
              >
                Cancel
              </button>
              <button
                onClick={() => { setShowConfirm(false); void handleDelete(); }}
                disabled={deleting}
                style={{ padding: "6px 16px", borderRadius: 6, border: "none", background: "var(--error, #ef4444)", color: "#fff", cursor: "pointer", fontSize: "0.875rem", fontWeight: 600 }}
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}

      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
    </div>
  );
}
