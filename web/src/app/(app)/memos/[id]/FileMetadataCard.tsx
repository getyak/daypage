"use client";

import { formatDayKey, formatTimeOfDay } from "@/lib/memos/format";

interface FileMetadataCardProps {
  created_at: string;
  path?: string | null;
  content_hash?: string | null;
  memo_id: string;
}

// Read-only FILE metadata card. The legacy transfer/pin/export/delete action
// menu is intentionally not wired in this slice (ADR-0022) — those actions
// could target an old DB realm.
export function FileMetadataCard({ created_at, path, content_hash }: FileMetadataCardProps) {
  const derivedPath = path ?? "—";
  const hashDisplay = content_hash
    ? `${content_hash.slice(0, 6)} · ${content_hash.slice(-5)}`
    : "—";

  const monoSm: React.CSSProperties = {
    fontFamily: "var(--font-mono)",
    fontSize: "11.5px",
    letterSpacing: "0.2px",
  };

  const labelStyle: React.CSSProperties = {
    ...monoSm,
    color: "var(--fg-subtle)",
    textTransform: "uppercase",
    fontWeight: 600,
    alignSelf: "start",
    paddingTop: 1,
  };

  const valueStyle: React.CSSProperties = {
    ...monoSm,
    color: "var(--fg-primary)",
    wordBreak: "break-all",
  };

  const createdDisplay = [formatDayKey(created_at), formatTimeOfDay(created_at)]
    .filter(Boolean)
    .join(" · ");

  return (
    <div style={{ padding: "0 22px 24px", marginTop: 28, position: "relative" }}>
      {/* SectionLabel — mono 10/700/ls1.8 */}
      <div style={{ display: "flex", alignItems: "baseline", paddingBottom: 8 }}>
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontWeight: 700,
            fontSize: 10,
            letterSpacing: "1.8px",
            color: "var(--fg-muted)",
          }}
        >
          FILE
        </span>
      </div>
      <div
        style={{
          padding: "14px 16px",
          borderRadius: 14,
          border: "0.5px solid var(--border-default)",
          background: "var(--surface-white)",
          boxShadow: "var(--shadow-card)",
        }}
      >
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "80px 1fr",
            rowGap: 11,
            columnGap: 14,
          }}
        >
          <span style={labelStyle}>CREATED</span>
          <span style={valueStyle}>{createdDisplay || created_at}</span>

          <span style={labelStyle}>PATH</span>
          <span style={valueStyle}>{derivedPath}</span>

          <span style={labelStyle}>HASH</span>
          <span
            style={{
              ...valueStyle,
              fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
              letterSpacing: "0.4px",
              color: content_hash ? "var(--fg-primary)" : "var(--fg-subtle)",
            }}
          >
            {hashDisplay}
          </span>
        </div>
      </div>
    </div>
  );
}
