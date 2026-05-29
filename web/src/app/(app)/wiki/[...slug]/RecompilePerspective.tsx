"use client";

import { useState, useCallback } from "react";
import { useRouter } from "next/navigation";
import { Sparkles, X, Loader } from "lucide-react";

interface RecompilePerspectiveProps {
  pageSlug: string;
}

const SUGGESTIONS = [
  "用更精炼、要点式的视角重写",
  "聚焦其中的情绪与感受",
  "以批判性、追问式的视角重新组织",
];

// US-030 — 自定义编译视角（MVP）
// 在 wiki / domain 页提供"重新编译（自定义视角）"入口与输入框。提交后调用
// /api/pages/:slug/recompile，成功后刷新页面以呈现重编后的 body。
export function RecompilePerspective({ pageSlug }: RecompilePerspectiveProps) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [prompt, setPrompt] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = useCallback(async () => {
    const p = prompt.trim();
    if (!p || loading) return;
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(
        `/api/pages/${encodeURIComponent(pageSlug)}/recompile`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ perspective_prompt: p }),
        }
      );
      if (!res.ok) {
        const data = (await res.json().catch(() => null)) as
          | { error?: string }
          | null;
        throw new Error(data?.error ?? "重新编译失败");
      }
      setOpen(false);
      setPrompt("");
      // Re-fetch the server component so the new body is rendered.
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "出错了，请重试");
    } finally {
      setLoading(false);
    }
  }, [prompt, loading, pageSlug, router]);

  if (!open) {
    return (
      <button
        className="btn btn--soft btn--sm"
        onClick={() => setOpen(true)}
        style={{ display: "flex", alignItems: "center", gap: "0.375rem" }}
        title="用自定义视角重新编译这一页"
      >
        <Sparkles size={13} />
        重新编译
      </button>
    );
  }

  return (
    <div
      style={{
        position: "fixed",
        bottom: "1.5rem",
        right: "1.5rem",
        width: "min(440px, calc(100vw - 3rem))",
        background: "var(--surface-white)",
        border: "1px solid var(--accent-border)",
        borderRadius: "var(--radius-md)",
        boxShadow: "0 8px 32px rgba(0,0,0,0.12)",
        display: "flex",
        flexDirection: "column",
        zIndex: 200,
        overflow: "hidden",
      }}
    >
      {/* Header */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: "0.5rem",
          padding: "0.75rem 1rem",
          borderBottom: "1px solid var(--accent-border)",
        }}
      >
        <Sparkles size={14} style={{ color: "var(--accent)" }} />
        <span
          style={{
            flex: 1,
            fontSize: "0.875rem",
            fontWeight: 600,
            color: "var(--fg-primary)",
          }}
        >
          重新编译（自定义视角）
        </span>
        <button
          type="button"
          className="btn btn--ghost btn--sm"
          onClick={() => {
            setOpen(false);
            setError(null);
          }}
          aria-label="Close"
          style={{ padding: "0.25rem", minWidth: 0 }}
        >
          <X size={14} />
        </button>
      </div>

      {/* Body */}
      <div style={{ padding: "0.875rem 1rem", display: "flex", flexDirection: "column", gap: "0.625rem" }}>
        <p style={{ fontSize: "0.8125rem", color: "var(--fg-muted)", margin: 0, lineHeight: 1.5 }}>
          用同样的素材、按你给的视角重新编译这一页。例如：
        </p>
        <div style={{ display: "flex", flexWrap: "wrap", gap: "0.375rem" }}>
          {SUGGESTIONS.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => setPrompt(s)}
              className="btn btn--ghost btn--sm"
              style={{ fontSize: "0.75rem" }}
            >
              {s}
            </button>
          ))}
        </div>
        <textarea
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="描述你想要的视角，例如：用更乐观、面向行动的语气重写…"
          rows={3}
          autoFocus
          style={{
            resize: "vertical",
            border: "1px solid var(--accent-border)",
            borderRadius: "var(--radius-sm)",
            padding: "0.5rem 0.625rem",
            fontSize: "0.875rem",
            background: "var(--bg-warm)",
            color: "var(--fg-primary)",
            fontFamily: "inherit",
            outline: "none",
            minHeight: "4.5rem",
          }}
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
              e.preventDefault();
              handleSubmit();
            }
          }}
        />
        {error && (
          <p style={{ fontSize: "0.8125rem", color: "var(--error)", margin: 0 }}>
            {error}
          </p>
        )}
        <div style={{ display: "flex", justifyContent: "flex-end", gap: "0.5rem" }}>
          <button
            type="button"
            className="btn btn--ghost btn--sm"
            onClick={() => {
              setOpen(false);
              setError(null);
            }}
            disabled={loading}
          >
            取消
          </button>
          <button
            type="button"
            className="btn btn--primary btn--sm"
            onClick={handleSubmit}
            disabled={!prompt.trim() || loading}
            style={{ display: "flex", alignItems: "center", gap: "0.375rem" }}
          >
            {loading ? (
              <>
                <Loader size={13} style={{ animation: "spin 1s linear infinite" }} />
                编译中…
              </>
            ) : (
              "重新编译"
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
