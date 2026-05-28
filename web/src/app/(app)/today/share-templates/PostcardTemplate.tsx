import type { ShareTemplateProps } from "./index";

function formatDate(iso: string) {
  const d = new Date(iso);
  return d.toLocaleDateString("en-US", { month: "short", day: "2-digit", year: "2-digit" }).toUpperCase();
}

export function PostcardTemplate({ body, created_at, place_name, photo_url }: ShareTemplateProps) {
  const excerpt = body.slice(0, 120) + (body.length > 120 ? "…" : "");

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#F7F3EE",
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
      }}
    >
      {/* Split layout — photo top, text bottom (adapted for portrait 4:5) */}
      {/* Photo half */}
      <div style={{ flex: "0 0 55%", position: "relative", overflow: "hidden" }}>
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
              background: "#D8CFC4",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="#A89880" strokeWidth="1.5">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <circle cx="8.5" cy="8.5" r="1.5" />
              <path d="m21 15-5-5L5 21" />
            </svg>
          </div>
        )}

        {/* Stamp placeholder */}
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            top: 12,
            right: 12,
            width: 24,
            height: 30,
            border: "1.5px solid rgba(255,255,255,0.7)",
            background: "rgba(255,255,255,0.15)",
            borderRadius: 2,
            backdropFilter: "blur(2px)",
          }}
        />
      </div>

      {/* Divider */}
      <div
        aria-hidden="true"
        style={{
          height: 1,
          background: "#C8B8A4",
          margin: "0 16px",
          flexShrink: 0,
        }}
      />

      {/* Text half */}
      <div
        style={{
          flex: 1,
          padding: 16,
          display: "flex",
          flexDirection: "column",
          overflow: "hidden",
        }}
      >
        {/* FROM label */}
        <div
          style={{
            fontFamily: "'JetBrains Mono', monospace",
            fontSize: 8,
            letterSpacing: 3,
            color: "#A09080",
            marginBottom: 6,
            textTransform: "uppercase",
          }}
        >
          FROM
        </div>

        {/* Location */}
        {place_name && (
          <div
            style={{
              fontFamily: "Fraunces, Georgia, serif",
              fontSize: 15,
              lineHeight: 1.2,
              color: "#3A3025",
              fontWeight: 600,
              marginBottom: 10,
            }}
          >
            {place_name}
          </div>
        )}

        {/* Body excerpt */}
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 12,
            lineHeight: 1.6,
            color: "#5A4E44",
            flex: 1,
            overflow: "hidden",
            display: "-webkit-box",
            WebkitLineClamp: 4,
            WebkitBoxOrient: "vertical",
          }}
        >
          {excerpt}
        </div>

        {/* Date footer */}
        <div
          style={{
            fontFamily: "'JetBrains Mono', monospace",
            fontSize: 9,
            color: "#A09080",
            letterSpacing: 1,
            marginTop: 8,
            flexShrink: 0,
          }}
        >
          {formatDate(created_at)}
        </div>
      </div>
    </div>
  );
}
