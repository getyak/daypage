import type { ShareTemplateProps } from "./index";

function formatDate(iso: string) {
  const d = new Date(iso);
  return d.toLocaleDateString("zh-CN", { year: "numeric", month: "long", day: "numeric" });
}

export function MinimalTemplate({ body, created_at, place_name, photo_url }: ShareTemplateProps) {
  const lines = body.split("\n").filter(Boolean);
  const title = lines[0] ?? "Memo";
  const rest = lines.slice(1).join("\n");

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#FAF8F6",
        padding: 28,
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
      }}
    >
      {photo_url && (
        <div style={{ marginBottom: 20, borderRadius: 10, overflow: "hidden", flexShrink: 0 }}>
          <img
            src={photo_url}
            alt=""
            style={{ width: "100%", height: 120, objectFit: "cover", display: "block" }}
          />
        </div>
      )}

      <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <div
          style={{
            fontFamily: "Fraunces, Georgia, serif",
            fontSize: 24,
            lineHeight: 1.2,
            letterSpacing: -0.3,
            color: "#2A1F16",
            fontWeight: 700,
            marginBottom: 16,
          }}
        >
          {title}
        </div>

        {rest && (
          <div
            style={{
              fontFamily: "Inter, sans-serif",
              fontSize: 14,
              lineHeight: 1.6,
              color: "#4A3F35",
              flex: 1,
              overflow: "hidden",
              display: "-webkit-box",
              WebkitLineClamp: 8,
              WebkitBoxOrient: "vertical",
            }}
          >
            {rest}
          </div>
        )}
      </div>

      <div
        style={{
          fontFamily: "'JetBrains Mono', monospace",
          fontSize: 9,
          color: "#A09080",
          letterSpacing: 0.5,
          marginTop: 16,
          display: "flex",
          gap: 8,
          flexShrink: 0,
        }}
      >
        <span>{formatDate(created_at)}</span>
        {place_name && (
          <>
            <span>·</span>
            <span>{place_name}</span>
          </>
        )}
      </div>
    </div>
  );
}
