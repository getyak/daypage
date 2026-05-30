"use client";

import { MapPin, Navigation, ArrowUpRight } from "lucide-react";

interface LocationCardProps {
  location?: string | null;
  lat?: number | null;
  lng?: number | null;
  place_name?: string | null;
  country?: string | null;
}

/**
 * Hand-drawn stylized vector map (detail.jsx:137-189 MiniMap).
 * water #A8D8E8, parks #CEDFB4 over base #F2EAD6, hand-drawn white streets.
 * Purely decorative — marked aria-hidden.
 */
function MiniMap() {
  return (
    <svg
      viewBox="0 0 400 240"
      width="100%"
      height="100%"
      preserveAspectRatio="xMidYMid slice"
      aria-hidden="true"
      style={{ display: "block" }}
    >
      <rect width="400" height="240" fill="#F2EAD6" />
      {/* water bodies */}
      <path d="M-10 30 Q 40 10 90 40 Q 140 70 110 110 Q 80 130 30 120 Z" fill="#A8D8E8" opacity="0.85" />
      <path d="M340 0 Q 360 30 400 25 L 400 -10 Z" fill="#A8D8E8" opacity="0.85" />
      <path d="M280 180 Q 320 200 360 195 Q 400 188 410 220 L 410 260 L 280 260 Z" fill="#A8D8E8" opacity="0.85" />
      {/* green park */}
      <path d="M210 80 Q 250 70 280 90 Q 290 120 260 130 Q 220 130 210 105 Z" fill="#CEDFB4" opacity="0.9" />
      {/* primary streets */}
      <g stroke="#fff" strokeWidth="3" fill="none" strokeLinecap="round">
        <path d="M 0 60 Q 100 80 200 70 T 400 90" />
        <path d="M 0 140 Q 80 160 180 150 T 400 160" />
        <path d="M 60 0 Q 80 60 100 120 T 130 240" />
        <path d="M 200 0 Q 220 80 200 160 T 220 240" />
        <path d="M 320 0 Q 300 60 340 120 T 320 240" />
        <path d="M 0 200 Q 100 210 200 200 T 400 210" />
      </g>
      {/* secondary streets */}
      <g stroke="#fff" strokeWidth="1.5" fill="none" strokeLinecap="round" opacity="0.8">
        <path d="M 30 0 L 50 240" />
        <path d="M 150 0 L 170 240" />
        <path d="M 260 0 L 240 240" />
        <path d="M 380 0 L 380 240" />
        <path d="M 0 100 L 400 110" />
        <path d="M 0 180 L 400 175" />
      </g>
    </svg>
  );
}

export function LocationCard({ location, lat, lng, place_name, country }: LocationCardProps) {
  const hasCoords = typeof lat === "number" && typeof lng === "number";
  const hasPlace = !!place_name || !!location;

  if (!hasCoords && !hasPlace) return null;

  const displayPlace = place_name || location || "";
  // chip sub-line: "<LOCATION> · <COUNTRY>" — matches detail.jsx:341
  const chipMeta = [location, country].filter(Boolean).join(" · ").toUpperCase();

  // SectionLabel right-aligned coords (detail.jsx:296-298)
  const coordLabel = hasCoords
    ? `${Math.abs(lat as number).toFixed(2)}°${(lat as number) >= 0 ? "N" : "S"} · ${Math.abs(
        lng as number,
      ).toFixed(2)}°${(lng as number) >= 0 ? "E" : "W"}`
    : null;

  const mapsUrl = hasCoords
    ? `https://maps.apple.com/?ll=${lat},${lng}&q=${encodeURIComponent(displayPlace)}`
    : `https://maps.apple.com/?q=${encodeURIComponent(displayPlace)}`;

  return (
    <div style={{ padding: "0 22px", marginTop: 28 }}>
      {/* SectionLabel — mono 10/700/ls1.8, right-aligned coords (detail.jsx:411-420) */}
      <div style={{ display: "flex", alignItems: "baseline", paddingBottom: 8 }}>
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontWeight: 700,
            fontSize: 10,
            letterSpacing: "1.8px",
            color: "var(--fg-muted)",
          }}
        >
          LOCATION
        </span>
        {coordLabel && (
          <span
            style={{
              marginLeft: "auto",
              fontFamily: "var(--font-mono)",
              fontSize: 9.5,
              fontWeight: 600,
              letterSpacing: "1.4px",
              color: "var(--fg-subtle)",
            }}
          >
            {coordLabel}
          </span>
        )}
      </div>

      <div
        style={{
          borderRadius: 18,
          overflow: "hidden",
          border: "0.5px solid var(--border-subtle)",
          background: "var(--surface-white)",
          boxShadow: "var(--shadow-card)",
        }}
      >
        {/* Hand-drawn map */}
        <div
          style={{
            position: "relative",
            height: 150,
            background: "#EFE7D5",
          }}
        >
          <MiniMap />

          {/* center pin (detail.jsx:174-187) */}
          <div
            style={{
              position: "absolute",
              left: "48%",
              top: "42%",
              transform: "translate(-50%,-100%)",
            }}
            aria-hidden="true"
          >
            <div
              style={{
                width: 30,
                height: 30,
                borderRadius: 999,
                background: "#E63946",
                boxShadow: "0 4px 10px rgba(230,57,70,0.4)",
                border: "2.5px solid #fff",
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              <span style={{ width: 10, height: 10, borderRadius: 999, background: "#fff" }} />
            </div>
          </div>

          {/* Glass place chip (detail.jsx:319-345) */}
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
              display: "inline-flex",
              alignItems: "center",
              gap: 7,
            }}
          >
            <MapPin size={12} style={{ color: "var(--accent)", flexShrink: 0 }} fill="var(--accent)" />
            <div>
              <div
                style={{
                  fontSize: 12.5,
                  fontWeight: 600,
                  color: "var(--fg-primary)",
                  lineHeight: 1.1,
                }}
              >
                {displayPlace}
              </div>
              {chipMeta && (
                <div
                  style={{
                    fontFamily: "var(--font-mono)",
                    fontSize: 8.5,
                    fontWeight: 600,
                    letterSpacing: "1.2px",
                    color: "var(--fg-subtle)",
                    marginTop: 2,
                  }}
                >
                  {chipMeta}
                </div>
              )}
            </div>
          </div>
        </div>

        {/* Open-in-maps button */}
        <a
          href={mapsUrl}
          target="_blank"
          rel="noopener noreferrer"
          style={{
            display: "flex",
            alignItems: "center",
            gap: 10,
            padding: "13px 16px",
            color: "var(--accent)",
            fontSize: 13.5,
            fontWeight: 500,
            textDecoration: "none",
            borderTop: "0.5px solid var(--border-subtle)",
          }}
        >
          <Navigation size={14} style={{ flexShrink: 0 }} />
          <span style={{ flex: 1 }}>在 Apple 地图中打开</span>
          <ArrowUpRight size={13} style={{ opacity: 0.7 }} />
        </a>
      </div>
    </div>
  );
}
