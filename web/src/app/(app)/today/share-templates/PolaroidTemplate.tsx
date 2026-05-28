import type { ShareTemplateProps } from "./index";

export function PolaroidTemplate({ body, photo_url }: ShareTemplateProps) {
  const caption = body.split("\n").filter(Boolean).slice(0, 3).join(" ");

  return (
    <div
      style={{
        width: "100%",
        aspectRatio: "4/5",
        borderRadius: 18,
        overflow: "hidden",
        background: "#F0ECE4",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxSizing: "border-box",
      }}
    >
      {/* Polaroid frame */}
      <div
        style={{
          background: "#FFFFFF",
          padding: "12px 12px 0 12px",
          boxShadow: "0 4px 20px rgba(0,0,0,0.12), 0 1px 4px rgba(0,0,0,0.08)",
          borderRadius: 2,
          width: "80%",
          transform: "rotate(-1.5deg)",
        }}
      >
        {/* Photo area */}
        <div
          style={{
            aspectRatio: "4/5",
            background: "#E8E0D8",
            overflow: "hidden",
            borderRadius: 1,
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
                background: "#E8E0D8",
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

        {/* Caption area */}
        <div
          style={{
            padding: "16px 4px 20px",
            minHeight: 64,
          }}
        >
          <div
            style={{
              fontFamily: "Caveat, cursive",
              fontSize: 16,
              lineHeight: 1.4,
              color: "#3A3025",
              overflow: "hidden",
              display: "-webkit-box",
              WebkitLineClamp: 3,
              WebkitBoxOrient: "vertical",
            }}
          >
            {caption || "No caption"}
          </div>
        </div>
      </div>
    </div>
  );
}
