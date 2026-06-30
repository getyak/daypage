import { ImageResponse } from "next/og";
import { BRAND, OG_IMAGE, SITE_NAME, SITE_TAGLINE } from "@/lib/seo";

export const runtime = "edge";
export const alt = OG_IMAGE.alt;
export const size = { width: OG_IMAGE.width, height: OG_IMAGE.height };
export const contentType = "image/png";

export default async function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "72px 88px",
          background: `linear-gradient(140deg, ${BRAND.background} 0%, #F4ECD9 100%)`,
          fontFamily: "serif",
          color: BRAND.ink,
          position: "relative",
        }}
      >
        <div
          style={{
            position: "absolute",
            inset: 0,
            background:
              "radial-gradient(1100px 600px at 80% 0%, rgba(124,45,18,0.10), transparent 60%)",
          }}
        />

        <div style={{ display: "flex", alignItems: "center", gap: 14, zIndex: 1 }}>
          <div
            style={{
              width: 28,
              height: 28,
              borderRadius: 8,
              background: BRAND.primary,
              display: "flex",
            }}
          />
          <div style={{ fontSize: 28, fontWeight: 700, letterSpacing: -0.5 }}>
            {SITE_NAME}
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 28, zIndex: 1 }}>
          <div
            style={{
              fontSize: 96,
              lineHeight: 1.02,
              letterSpacing: -2,
              fontWeight: 600,
              display: "flex",
              flexDirection: "column",
            }}
          >
            <span>Your day,</span>
            <span>captured raw.</span>
            <span
              style={{
                fontStyle: "italic",
                fontWeight: 400,
                color: BRAND.primary,
              }}
            >
              Compiled by AI.
            </span>
          </div>
          <div
            style={{
              fontSize: 26,
              color: "#5B4636",
              maxWidth: 820,
              fontFamily: "sans-serif",
            }}
          >
            Local-first journaling. Voice, text, photos in. Diary and knowledge
            graph out — every day at 2am.
          </div>
        </div>

        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            fontSize: 22,
            color: "#7A5C46",
            fontFamily: "sans-serif",
            zIndex: 1,
          }}
        >
          <div>{SITE_TAGLINE}</div>
          <div>daypage.app</div>
        </div>
      </div>
    ),
    { ...size },
  );
}
