"use client";

import { MapPin, ExternalLink } from "lucide-react";

interface LocationCardProps {
  location?: string | null;
  lat?: number | null;
  lng?: number | null;
  place_name?: string | null;
  country?: string | null;
}

export function LocationCard({ location, lat, lng, place_name, country }: LocationCardProps) {
  const hasCoords = typeof lat === "number" && typeof lng === "number";
  const hasPlace = !!place_name || !!location;

  if (!hasCoords && !hasPlace) return null;

  const displayPlace = place_name || location || "";
  const displayMeta = [location, country].filter(Boolean).join(" · ");

  const mapsUrl =
    hasCoords
      ? `https://maps.apple.com/?ll=${lat},${lng}&q=${encodeURIComponent(displayPlace)}`
      : `https://maps.apple.com/?q=${encodeURIComponent(displayPlace)}`;

  return (
    <div
      style={{
        margin: "0 24px 24px",
        borderRadius: 18,
        overflow: "hidden",
        border: "0.5px solid var(--border-default)",
        background: "var(--surface-white)",
        boxShadow: "var(--shadow-card)",
      }}
    >
      {/* Map placeholder */}
      <div
        style={{
          position: "relative",
          height: 160,
          background: "linear-gradient(145deg, #F5EDE3 0%, #EDE0D0 50%, #E3D5C5 100%)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        {/* Decorative grid lines */}
        <svg
          style={{ position: "absolute", inset: 0, width: "100%", height: "100%", opacity: 0.15 }}
          xmlns="http://www.w3.org/2000/svg"
        >
          {Array.from({ length: 6 }).map((_, i) => (
            <line
              key={`h${i}`}
              x1="0"
              y1={`${(i + 1) * (100 / 7)}%`}
              x2="100%"
              y2={`${(i + 1) * (100 / 7)}%`}
              stroke="#8B6F5C"
              strokeWidth="0.5"
            />
          ))}
          {Array.from({ length: 8 }).map((_, i) => (
            <line
              key={`v${i}`}
              x1={`${(i + 1) * (100 / 9)}%`}
              y1="0"
              x2={`${(i + 1) * (100 / 9)}%`}
              y2="100%"
              stroke="#8B6F5C"
              strokeWidth="0.5"
            />
          ))}
        </svg>

        <MapPin
          size={36}
          style={{ color: "var(--accent)", opacity: 0.7, position: "relative", zIndex: 1 }}
        />

        {/* Place chip */}
        <div
          style={{
            position: "absolute",
            left: 14,
            bottom: 14,
            padding: "7px 11px",
            borderRadius: 10,
            background: "rgba(250,248,246,0.92)",
            backdropFilter: "blur(10px)",
            WebkitBackdropFilter: "blur(10px)",
            border: "0.5px solid var(--border-subtle)",
            display: "flex",
            flexDirection: "column",
            gap: 2,
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <MapPin size={11} style={{ color: "var(--accent)", flexShrink: 0 }} />
            <span
              style={{
                fontSize: "12.5px",
                fontWeight: 600,
                color: "var(--fg-primary)",
                lineHeight: 1.2,
              }}
            >
              {displayPlace}
            </span>
          </div>
          {displayMeta && (
            <span
              style={{
                fontSize: "10px",
                fontFamily: "var(--font-mono)",
                textTransform: "uppercase",
                letterSpacing: "0.3px",
                color: "var(--fg-subtle)",
                paddingLeft: 16,
              }}
            >
              {displayMeta}
            </span>
          )}
        </div>
      </div>

      {/* Bottom button */}
      <a
        href={mapsUrl}
        target="_blank"
        rel="noopener noreferrer"
        style={{
          display: "flex",
          alignItems: "center",
          gap: 7,
          padding: "12px 16px",
          color: "var(--accent)",
          fontSize: "13px",
          fontWeight: 500,
          textDecoration: "none",
          borderTop: "0.5px solid var(--border-subtle)",
        }}
      >
        <MapPin size={13} style={{ flexShrink: 0 }} />
        <span style={{ flex: 1 }}>在 Apple 地图中打开</span>
        <ExternalLink size={12} style={{ opacity: 0.6 }} />
      </a>
    </div>
  );
}
