import type { ShareTemplateProps } from "./index";

function formatDate(iso: string) {
  const d = new Date(iso);
  // "28 · MAY · 2026" (detail.jsx:944)
  const day = String(d.getDate()).padStart(2, "0");
  const month = d.toLocaleDateString("en-US", { month: "short" }).toUpperCase();
  return `${day} · ${month} · ${d.getFullYear()}`;
}

function formatTime(iso: string) {
  return new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
}

const BORDER = "var(--border-default, #D6CEC0)";
const MUTED = "var(--fg-muted, #6B6560)";

/**
 * Postcard template — photo top, dashed divider, body + dashed stamp
 * (DAYPAGE / time / divider / LAOS) (detail.jsx:935-965).
 */
export function PostcardTemplate({ body, created_at, place_name, photo_url }: ShareTemplateProps) {
  const text = body.length > 120 ? body.slice(0, 120) + "…" : body;
  const location = place_name ?? "Vientiane";

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#fff",
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
        boxShadow: "0 18px 40px -16px rgba(60,40,15,0.22)",
      }}
    >
      {/* Photo 3/2 */}
      <div style={{ aspectRatio: "3/2", overflow: "hidden", flexShrink: 0, background: "#D8CFC4" }}>
        {photo_url ? (
          <img
            src={photo_url}
            alt=""
            style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
          />
        ) : (
          <div style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center" }}>
            <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="#A89880" strokeWidth="1.5">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <circle cx="8.5" cy="8.5" r="1.5" />
              <path d="m21 15-5-5L5 21" />
            </svg>
          </div>
        )}
      </div>

      {/* Body section */}
      <div style={{ padding: 18, display: "flex", flexDirection: "column", flex: 1, overflow: "hidden" }}>
        {/* Header: serif location + mono date, dashed divider */}
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "baseline",
            paddingBottom: 10,
            borderBottom: `1px dashed ${BORDER}`,
          }}
        >
          <div style={{ fontFamily: "var(--font-serif, Fraunces, Georgia, serif)", fontSize: 22, fontWeight: 600, color: "var(--fg-primary, #2B2822)" }}>
            {location}
          </div>
          <div style={{ fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)", fontSize: 10, color: MUTED }}>
            {formatDate(created_at)}
          </div>
        </div>

        {/* Text + stamp */}
        <div style={{ display: "flex", gap: 14, marginTop: 14, flex: 1, overflow: "hidden" }}>
          <div
            style={{
              flex: 1,
              fontFamily: "var(--font-body, Inter, sans-serif)",
              fontSize: 12,
              lineHeight: 1.6,
              color: "var(--fg-primary, #2B2822)",
              whiteSpace: "pre-line",
              overflow: "hidden",
              display: "-webkit-box",
              WebkitLineClamp: 6,
              WebkitBoxOrient: "vertical",
            }}
          >
            {text}
          </div>

          {/* Stamp */}
          <div
            style={{
              width: 56,
              height: 64,
              border: `1.5px dashed ${BORDER}`,
              borderRadius: 4,
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 4,
              flexShrink: 0,
            }}
          >
            <div style={{ fontFamily: "var(--font-display, 'Space Grotesk', sans-serif)", fontSize: 9, fontWeight: 700, letterSpacing: 1, color: "var(--accent, #5D3000)" }}>
              DAYPAGE
            </div>
            <div style={{ fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)", fontSize: 8, color: MUTED }}>
              {formatTime(created_at)}
            </div>
            <div style={{ width: 30, height: 1, background: BORDER }} />
            <div style={{ fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)", fontSize: 7, color: "var(--fg-subtle, #A39F99)" }}>
              LAOS
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
