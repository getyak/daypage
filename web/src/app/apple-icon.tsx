import { ImageResponse } from "next/og";
import { BRAND } from "@/lib/seo";

export const runtime = "edge";
export const size = { width: 180, height: 180 };
export const contentType = "image/png";

export default function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          background: `linear-gradient(135deg, ${BRAND.primary} 0%, #B45A1B 100%)`,
          color: BRAND.background,
          fontSize: 124,
          fontWeight: 700,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontFamily: "serif",
          letterSpacing: -6,
        }}
      >
        D
      </div>
    ),
    { ...size },
  );
}
