import type { ShareTemplateProps } from "./index";

function formatDate(iso: string) {
  const d = new Date(iso);
  return d.toLocaleDateString("en-US", { month: "short", day: "2-digit", year: "numeric" }).toUpperCase();
}

function FilmPerforations() {
  const holes = Array.from({ length: 8 });
  return (
    <div
      aria-hidden="true"
      style={{
        display: "flex",
        justifyContent: "space-around",
        alignItems: "center",
        padding: "4px 8px",
        background: "#1A1A1A",
      }}
    >
      {holes.map((_, i) => (
        <div
          key={i}
          style={{
            width: 10,
            height: 7,
            borderRadius: 1,
            background: "#333",
            border: "1px solid #444",
          }}
        />
      ))}
    </div>
  );
}

export function FilmTemplate({ body, created_at, photo_url }: ShareTemplateProps) {
  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#1A1A1A",
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
        padding: 20,
      }}
    >
      <FilmPerforations />

      {/* Photo area */}
      <div
        style={{
          background: "#2A2A2A",
          aspectRatio: "4/3",
          flexShrink: 0,
          overflow: "hidden",
          border: "6px solid #F5F0E8",
          boxSizing: "border-box",
        }}
      >
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
            <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#444" strokeWidth="1.5">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <circle cx="8.5" cy="8.5" r="1.5" />
              <path d="m21 15-5-5L5 21" />
            </svg>
          </div>
        )}
      </div>

      <FilmPerforations />

      {/* Body text */}
      <div
        style={{
          flex: 1,
          padding: "12px 4px",
          overflow: "hidden",
        }}
      >
        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 13,
            lineHeight: 1.5,
            color: "#E8E0D0",
            display: "-webkit-box",
            WebkitLineClamp: 5,
            WebkitBoxOrient: "vertical",
            overflow: "hidden",
          }}
        >
          {body}
        </div>
      </div>

      {/* Footer */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "0 4px",
          flexShrink: 0,
        }}
      >
        <span
          style={{
            fontFamily: "'JetBrains Mono', monospace",
            fontSize: 9,
            color: "#666",
            letterSpacing: 1,
          }}
        >
          {formatDate(created_at)}
        </span>
        <span
          style={{
            fontFamily: "'JetBrains Mono', monospace",
            fontSize: 9,
            color: "#666",
            letterSpacing: 1,
          }}
        >
          28 / 36A
        </span>
      </div>
    </div>
  );
}
