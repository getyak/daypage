"use client";

import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link2, FileText, Mic, Bookmark, Wand2 } from "lucide-react";

const HINT_CHIPS = [
  { icon: Link2, label: "URL" },
  { icon: FileText, label: "File" },
  { icon: Mic, label: "Voice" },
  { icon: Bookmark, label: "Bookmarklet" },
  { icon: Wand2, label: "Auto-detect" },
] as const;

const URL_RE = /^https?:\/\//;

async function createMemo(body: string) {
  const type = URL_RE.test(body.trim()) ? "url" : "text";
  const res = await fetch("/api/memos", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type, body, origin: "web" }),
  });
  if (!res.ok) {
    const data = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(data.error ?? `Request failed (${res.status})`);
  }
  return res.json();
}

export function UnifiedInput() {
  const [body, setBody] = useState("");
  const queryClient = useQueryClient();
  const empty = body.trim().length === 0;

  const mutation = useMutation({
    mutationFn: createMemo,
    onSuccess: (newMemo) => {
      setBody("");
      // Prepend the new pending memo to the compile queue cache
      queryClient.setQueryData<{ items: unknown[] }>(
        ["memos", "pending"],
        (old) => ({
          items: [newMemo, ...(old?.items ?? [])],
          next_cursor: null,
          has_more: false,
        })
      );
    },
  });

  function handleSubmit() {
    if (empty) return;
    mutation.mutate(body);
  }

  return (
    <div
      className="card"
      style={{
        padding: "1.25rem",
        display: "flex",
        flexDirection: "column",
        gap: "0.875rem",
      }}
    >
      {/* Textarea */}
      <textarea
        value={body}
        onChange={(e) => setBody(e.target.value)}
        placeholder="Paste a URL, drop a file, or just type something…"
        rows={6}
        style={{
          width: "100%",
          resize: "vertical",
          border: "1.5px solid var(--accent-border)",
          borderRadius: "var(--radius-sm)",
          padding: "0.75rem",
          fontFamily: "var(--font-inter), ui-sans-serif, sans-serif",
          fontSize: "0.9375rem",
          lineHeight: 1.6,
          color: "var(--fg-primary)",
          background: "var(--bg-warm)",
          outline: "none",
          transition: "border-color 100ms ease-out",
          boxSizing: "border-box",
        }}
        onFocus={(e) =>
          (e.currentTarget.style.borderColor = "var(--accent)")
        }
        onBlur={(e) =>
          (e.currentTarget.style.borderColor = "var(--accent-border)")
        }
      />

      {/* Hint chips row */}
      <div style={{ display: "flex", flexWrap: "wrap", gap: "0.375rem" }}>
        {HINT_CHIPS.map(({ icon: Icon, label }) => (
          <button
            key={label}
            type="button"
            className="chip chip--ghost chip--interactive"
            style={{ fontSize: "0.8125rem" }}
          >
            <Icon size={12} />
            {label}
          </button>
        ))}
      </div>

      {/* Inline error */}
      {mutation.isError && (
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "0.5rem",
            padding: "0.625rem 0.75rem",
            background: "var(--error-soft, #fff1f1)",
            border: "1px solid var(--error, #e53e3e)",
            borderRadius: "var(--radius-sm)",
            fontSize: "0.875rem",
            color: "var(--error, #c53030)",
          }}
        >
          <span style={{ flex: 1 }}>
            {mutation.error instanceof Error
              ? mutation.error.message
              : "Something went wrong"}
          </span>
          <button
            type="button"
            className="btn btn--secondary btn--sm"
            onClick={handleSubmit}
          >
            Retry
          </button>
        </div>
      )}

      {/* Action row */}
      <div style={{ display: "flex", justifyContent: "flex-end", gap: "0.5rem" }}>
        <button
          type="button"
          className="btn btn--secondary btn--sm"
          disabled={empty || mutation.isPending}
        >
          Save draft
        </button>
        <button
          type="button"
          className="btn btn--primary btn--sm"
          disabled={empty || mutation.isPending}
          onClick={handleSubmit}
        >
          {mutation.isPending ? "Adding…" : "Add"}
        </button>
      </div>
    </div>
  );
}
