import type { ShareTemplateProps } from "./index";

function formatTime(iso: string) {
  const d = new Date(iso);
  return d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
}

const HAIRLINE = "var(--border-subtle, #EDE8DF)";
const MUTED = "var(--fg-muted, #6B6560)";

/**
 * Minimal template — DAYPAGE + time header, top/bottom hairlines,
 * centered daypage.app footer (detail.jsx:843-859).
 */
export function MinimalTemplate({ body, created_at, place_name, photo_url }: ShareTemplateProps) {
  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#fff",
        padding: 22,
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
        boxShadow: "0 18px 40px -16px rgba(60,40,15,0.22)",
      }}
    >
      {/* Header: DAYPAGE display label + time */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <span
          style={{
            fontFamily: "var(--font-display, 'Space Grotesk', sans-serif)",
            fontWeight: 700,
            fontSize: 14,
            letterSpacing: 1.4,
            color: "var(--fg-primary, #2B2822)",
          }}
        >
          DAYPAGE
        </span>
        <span
          style={{
            fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
            fontSize: 10,
            color: MUTED,
          }}
        >
          {formatTime(created_at)}
        </span>
      </div>

      {/* Top hairline */}
      <div style={{ height: 1, background: HAIRLINE, margin: "10px 0 14px" }} />

      {/* Photo 4/3 */}
      {photo_url && (
        <div style={{ borderRadius: 10, overflow: "hidden", flexShrink: 0, aspectRatio: "4/3" }}>
          <img
            src={photo_url}
            alt=""
            style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
          />
        </div>
      )}

      {/* Body */}
      <div
        style={{
          fontFamily: "var(--font-body, Inter, sans-serif)",
          fontSize: 14,
          lineHeight: 1.62,
          color: "var(--fg-primary, #2B2822)",
          marginTop: 14,
          whiteSpace: "pre-line",
          flex: 1,
          overflow: "hidden",
          display: "-webkit-box",
          WebkitLineClamp: 7,
          WebkitBoxOrient: "vertical",
        }}
      >
        {body}
      </div>

      {/* Place name */}
      {place_name && (
        <div
          style={{
            fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
            fontSize: 9,
            color: MUTED,
            marginTop: 14,
            letterSpacing: 1.4,
            textTransform: "uppercase",
            flexShrink: 0,
          }}
        >
          {place_name}
        </div>
      )}

      {/* Bottom hairline + centered footer */}
      <div style={{ height: 1, background: HAIRLINE, margin: "14px 0 8px", flexShrink: 0 }} />
      <div
        style={{
          fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
          fontSize: 9,
          color: "var(--fg-subtle, #A39F99)",
          textAlign: "center",
          letterSpacing: 1,
          flexShrink: 0,
        }}
      >
        daypage.app
      </div>
    </div>
  );
}
