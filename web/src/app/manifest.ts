import type { MetadataRoute } from "next";
import { BRAND, SITE_DESCRIPTION, SITE_NAME, SITE_TAGLINE } from "@/lib/seo";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: `${SITE_NAME} — ${SITE_TAGLINE}`,
    short_name: SITE_NAME,
    description: SITE_DESCRIPTION,
    start_url: "/",
    display: "standalone",
    background_color: BRAND.background,
    theme_color: BRAND.background,
    orientation: "portrait",
    icons: [
      { src: "/icon", sizes: "any", type: "image/png" },
      { src: "/apple-icon", sizes: "180x180", type: "image/png" },
    ],
    categories: ["productivity", "lifestyle", "utilities"],
  };
}
