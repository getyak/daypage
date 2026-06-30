import { ImageResponse } from "next/og";
import { BRAND } from "@/lib/seo";

export const runtime = "edge";
export const size = { width: 32, height: 32 };
export const contentType = "image/png";

export default function Icon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          background: BRAND.primary,
          color: BRAND.background,
          fontSize: 22,
          fontWeight: 700,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          borderRadius: 7,
          fontFamily: "serif",
          letterSpacing: -1,
        }}
      >
        D
      </div>
    ),
    { ...size },
  );
}
