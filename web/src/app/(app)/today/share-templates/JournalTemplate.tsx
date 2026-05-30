import type { ShareTemplateProps } from "./index";

function weekday(iso: string) {
  return new Date(iso).toLocaleDateString("en-US", { weekday: "long" });
}

function monthDay(iso: string) {
  const d = new Date(iso);
  // "may 28" (detail.jsx:921)
  return `${d.toLocaleDateString("en-US", { month: "long" }).toLowerCase()} ${d.getDate()}`;
}

/**
 * Journal template — washi-tape strips, ruled lines, red margin accent,
 * serif date title, 5/4 photo (detail.jsx:904-933).
 */
export function JournalTemplate({ body, created_at, place_name, photo_url, weather }: ShareTemplateProps) {
  const text = body.length > 160 ? body.slice(0, 160) + "…" : body;
  const location = place_name ?? "VIENTIANE";
  const temp = weather ?? "28°";

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#FBF6E8",
        padding: 20,
        position: "relative",
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
        boxShadow: "0 18px 40px -16px rgba(60,40,15,0.25)",
        // Ruled lines (detail.jsx:908)
        backgroundImage:
          "repeating-linear-gradient(180deg, transparent 0 27px, rgba(180,150,90,0.18) 27px 28px)",
      }}
    >
      {/* Left margin accent line */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          left: 44,
          top: 0,
          bottom: 0,
          width: 1,
          background: "rgba(227,107,74,0.3)",
          pointerEvents: "none",
        }}
      />

      {/* Washi tape — orange (top-left), green (top-right) */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          top: -6,
          left: 30,
          width: 90,
          height: 18,
          background: "rgba(227,107,74,0.55)",
          transform: "rotate(-5deg)",
          boxShadow: "0 2px 4px rgba(60,40,15,0.15)",
        }}
      />
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          top: -4,
          right: 24,
          width: 64,
          height: 14,
          background: "rgba(106,134,68,0.5)",
          transform: "rotate(8deg)",
          boxShadow: "0 2px 4px rgba(60,40,15,0.15)",
        }}
      />

      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        {/* Serif title: weekday · month day */}
        <div
          style={{
            fontFamily: "var(--font-serif, Fraunces, Georgia, serif)",
            fontSize: 22,
            fontWeight: 600,
            lineHeight: 1.1,
            color: "#3a2a18",
            marginTop: 10,
          }}
        >
          {weekday(created_at)}
          <span style={{ fontSize: 14, fontWeight: 500, color: "#8a6a3a", marginLeft: 8 }}>
            · {monthDay(created_at)}
          </span>
        </div>

        {/* Divider */}
        <div style={{ height: 1, background: "#c9a677", margin: "10px 0 14px", opacity: 0.7 }} />

        {/* Photo 5/4 */}
        {photo_url && (
          <div style={{ aspectRatio: "5/4", overflow: "hidden", borderRadius: 8, flexShrink: 0 }}>
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
            fontSize: 13,
            lineHeight: 1.7,
            color: "#3a2a18",
            marginTop: 14,
            whiteSpace: "pre-line",
            flex: 1,
            overflow: "hidden",
            display: "-webkit-box",
            WebkitLineClamp: 6,
            WebkitBoxOrient: "vertical",
          }}
        >
          {text}
        </div>

        {/* Footer: red dot + location · temp */}
        <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 14, flexShrink: 0 }}>
          <span style={{ width: 18, height: 18, borderRadius: 999, background: "#E36B4A", flexShrink: 0 }} />
          <span
            style={{
              fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
              fontSize: 10,
              color: "#8a6a3a",
              letterSpacing: 1.2,
              textTransform: "uppercase",
            }}
          >
            {location} · {temp}
          </span>
        </div>
      </div>
    </div>
  );
}
