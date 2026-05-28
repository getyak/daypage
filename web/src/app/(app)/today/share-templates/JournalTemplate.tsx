import type { ShareTemplateProps } from "./index";

function formatDate(iso: string) {
  const d = new Date(iso);
  return d.toLocaleDateString("zh-CN", { year: "numeric", month: "long", day: "numeric", weekday: "long" });
}

function PushpinSVG() {
  return (
    <svg
      width="22"
      height="28"
      viewBox="0 0 22 28"
      fill="none"
      aria-hidden="true"
      style={{ position: "absolute", top: 20, right: 22 }}
    >
      <ellipse cx="11" cy="8" rx="7" ry="7" fill="#C0392B" />
      <ellipse cx="11" cy="8" rx="4" ry="4" fill="#E74C3C" />
      <line x1="11" y1="14" x2="11" y2="28" stroke="#A0896A" strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

export function JournalTemplate({ body, created_at, place_name }: ShareTemplateProps) {
  const lines = body.split("\n").filter(Boolean);
  const title = lines[0] ?? "Journal Entry";
  const rest = lines.slice(1).join("\n");

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#F5EDE3",
        padding: 24,
        display: "flex",
        flexDirection: "column",
        boxSizing: "border-box",
        position: "relative",
      }}
    >
      <PushpinSVG />

      {/* Ruled lines decoration */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          inset: 0,
          backgroundImage:
            "repeating-linear-gradient(transparent, transparent 27px, rgba(160,137,112,0.15) 27px, rgba(160,137,112,0.15) 28px)",
          backgroundPositionY: 56,
          borderRadius: 18,
          pointerEvents: "none",
        }}
      />

      {/* Left margin line */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          left: 44,
          top: 0,
          bottom: 0,
          width: 1,
          background: "rgba(200,100,80,0.2)",
          pointerEvents: "none",
        }}
      />

      <div style={{ position: "relative", flex: 1, display: "flex", flexDirection: "column", paddingLeft: 12 }}>
        <div
          style={{
            fontFamily: "Fraunces, Georgia, serif",
            fontSize: 22,
            lineHeight: 1.3,
            color: "#3A3025",
            fontWeight: 600,
            marginBottom: 14,
            paddingRight: 32,
          }}
        >
          {title}
        </div>

        <div
          style={{
            fontFamily: "Inter, sans-serif",
            fontSize: 14,
            lineHeight: 1.7,
            color: "#4A3F35",
            flex: 1,
            overflow: "hidden",
            display: "-webkit-box",
            WebkitLineClamp: 9,
            WebkitBoxOrient: "vertical",
          }}
        >
          {rest || body}
        </div>
      </div>

      <div
        style={{
          position: "relative",
          fontFamily: "'JetBrains Mono', monospace",
          fontSize: 9,
          color: "#A09080",
          letterSpacing: 0.5,
          marginTop: 12,
          paddingLeft: 12,
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
