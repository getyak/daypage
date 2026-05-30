import type { ShareTemplateProps } from "./index";

function formatDate(iso: string) {
  const d = new Date(iso);
  // "28 / MAY / 2026" (detail.jsx:868)
  const day = String(d.getDate()).padStart(2, "0");
  const month = d.toLocaleDateString("en-US", { month: "short" }).toUpperCase();
  return `${day} / ${month} / ${d.getFullYear()}`;
}

// Authentic 35mm perforation strip — repeating gradient (detail.jsx:873-879)
const PERF = "repeating-linear-gradient(90deg, #f5ede3 0 8px, transparent 8px 14px)";

/**
 * Film template — dark gate, 35mm · Kodak 400 header, perforated photo strip,
 * serif-italic body (detail.jsx:861-887).
 */
export function FilmTemplate({ body, created_at, place_name, photo_url }: ShareTemplateProps) {
  const text = body.length > 130 ? body.slice(0, 130) + "…" : body;
  const location = place_name ?? "VIENTIANE";

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#0d0a07",
        color: "#f5ede3",
        padding: 18,
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
        boxShadow: "0 18px 40px -16px rgba(0,0,0,0.45)",
      }}
    >
      {/* Header: 35mm · Kodak 400 + date */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          paddingBottom: 10,
        }}
      >
        <span
          style={{
            fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
            fontSize: 10,
            color: "#e36b4a",
          }}
        >
          ● 35 mm · Kodak 400
        </span>
        <span
          style={{
            fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
            fontSize: 10,
            color: "#a39f99",
          }}
        >
          {formatDate(created_at)}
        </span>
      </div>

      {/* Photo 4/5 with top + bottom perforations */}
      <div style={{ position: "relative", flexShrink: 0 }}>
        <div style={{ aspectRatio: "4/5", overflow: "hidden", background: "#1A150F" }}>
          {photo_url ? (
            <img
              src={photo_url}
              alt=""
              style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
            />
          ) : (
            <div
              style={{
                width: "100%",
                height: "100%",
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#4a443c" strokeWidth="1.5">
                <rect x="3" y="3" width="18" height="18" rx="2" />
                <circle cx="8.5" cy="8.5" r="1.5" />
                <path d="m21 15-5-5L5 21" />
              </svg>
            </div>
          )}
        </div>
        <div aria-hidden="true" style={{ position: "absolute", left: 0, right: 0, top: -6, height: 6, background: PERF }} />
        <div aria-hidden="true" style={{ position: "absolute", left: 0, right: 0, bottom: -6, height: 6, background: PERF }} />
      </div>

      {/* Serif-italic body */}
      <div
        style={{
          fontFamily: "var(--font-serif, Fraunces, Georgia, serif)",
          fontStyle: "italic",
          fontSize: 14,
          lineHeight: 1.6,
          marginTop: 16,
          color: "#e8dccc",
          whiteSpace: "pre-line",
          flex: 1,
          overflow: "hidden",
        }}
      >
        {text}
      </div>

      {/* Footer */}
      <div
        style={{
          fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
          fontSize: 10,
          color: "#a39f99",
          marginTop: 14,
          letterSpacing: 1.2,
          textTransform: "uppercase",
          flexShrink: 0,
        }}
      >
        {location} · 18.04°N 102.64°E
      </div>
    </div>
  );
}
