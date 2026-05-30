import type { ShareTemplateProps } from "./index";

function formatStamp(iso: string) {
  // "05 · 28 · 26 · 15:30" (detail.jsx:900)
  const d = new Date(iso);
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const yy = String(d.getFullYear()).slice(-2);
  const time = d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
  return `${mm} · ${dd} · ${yy} · ${time}`;
}

/**
 * Polaroid template — square photo, Fraunces serif-italic caption,
 * mono date stamp, tilted -1.5deg (detail.jsx:889-902).
 */
export function PolaroidTemplate({ body, created_at, photo_url }: ShareTemplateProps) {
  const caption = body.split("\n").filter(Boolean).slice(0, 2).join(" ");

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "linear-gradient(180deg, #f3ede2 0%, #ede5d6 100%)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 18,
        boxSizing: "border-box",
      }}
    >
      {/* Polaroid frame */}
      <div
        style={{
          background: "#FAF6EE",
          padding: "14px 14px 24px",
          borderRadius: 4,
          width: "84%",
          transform: "rotate(-1.5deg)",
          boxShadow: "0 18px 40px -16px rgba(60,40,15,0.32), 0 2px 0 rgba(0,0,0,0.04)",
        }}
      >
        {/* Square photo */}
        <div style={{ aspectRatio: "1", overflow: "hidden", borderRadius: 4, background: "#E8E0D8" }}>
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
              <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#B8A898" strokeWidth="1.5">
                <rect x="3" y="3" width="18" height="18" rx="2" />
                <circle cx="8.5" cy="8.5" r="1.5" />
                <path d="m21 15-5-5L5 21" />
              </svg>
            </div>
          )}
        </div>

        {/* Serif-italic caption */}
        <div
          style={{
            marginTop: 14,
            fontFamily: "var(--font-serif, Fraunces, Georgia, serif)",
            fontStyle: "italic",
            fontSize: 22,
            color: "#3a2f25",
            lineHeight: 1.2,
            textAlign: "center",
            overflow: "hidden",
            display: "-webkit-box",
            WebkitLineClamp: 2,
            WebkitBoxOrient: "vertical",
          }}
        >
          {caption || "a quiet afternoon"}
        </div>

        {/* Mono date stamp */}
        <div
          style={{
            fontFamily: "var(--font-mono, 'JetBrains Mono', monospace)",
            fontSize: 9,
            color: "#8a7c65",
            textAlign: "center",
            marginTop: 8,
            letterSpacing: 1.4,
          }}
        >
          {formatStamp(created_at)}
        </div>
      </div>
    </div>
  );
}
