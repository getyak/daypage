"use client";

import { useState } from "react";
import { Link2, FileText, Mic, Bookmark, Wand2 } from "lucide-react";

const HINT_CHIPS = [
  { icon: Link2, label: "URL" },
  { icon: FileText, label: "File" },
  { icon: Mic, label: "Voice" },
  { icon: Bookmark, label: "Bookmarklet" },
  { icon: Wand2, label: "Auto-detect" },
] as const;

export function UnifiedInput() {
  const [body, setBody] = useState("");
  const empty = body.trim().length === 0;

  return (
    <div className="card" style={{ padding: "1.25rem", display: "flex", flexDirection: "column", gap: "0.875rem" }}>
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
        onFocus={(e) => (e.currentTarget.style.borderColor = "var(--accent)")}
        onBlur={(e) => (e.currentTarget.style.borderColor = "var(--accent-border)")}
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

      {/* Action row */}
      <div style={{ display: "flex", justifyContent: "flex-end", gap: "0.5rem" }}>
        <button type="button" className="btn btn--secondary btn--sm" disabled={empty}>
          Save draft
        </button>
        <button type="button" className="btn btn--primary btn--sm" disabled={empty}>
          Add
        </button>
      </div>
    </div>
  );
}
