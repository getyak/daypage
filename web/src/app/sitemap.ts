import type { MetadataRoute } from "next";
import { PUBLIC_ROUTES, SITE_URL } from "@/lib/seo";

// Stable lastModified per build. Using `new Date()` at request-time makes every
// crawl look like an edit — Googlebot then treats revisit hints as noise and
// slows re-index. Use build-time timestamp (env-injected in CI, static
// fallback otherwise) so the sitemap only changes when content changes.
const BUILD_TIMESTAMP =
  process.env.NEXT_PUBLIC_BUILD_TIMESTAMP ?? "2026-07-02T00:00:00.000Z";

export default function sitemap(): MetadataRoute.Sitemap {
  const lastModified = new Date(BUILD_TIMESTAMP);
  const out: MetadataRoute.Sitemap = [];
  for (const route of PUBLIC_ROUTES) {
    const enPath = route.path === "/" ? "" : route.path;
    const zhPath = `/zh${route.path === "/" ? "" : route.path}`;
    // Full hreflang set: en, zh-CN, and x-default → canonical (en) URL.
    const alternates = {
      languages: {
        en: `${SITE_URL}${enPath || "/"}`,
        "zh-CN": `${SITE_URL}${zhPath}`,
        "x-default": `${SITE_URL}${enPath || "/"}`,
      },
    };
    out.push({
      url: `${SITE_URL}${enPath || "/"}`,
      lastModified,
      changeFrequency: route.changefreq,
      priority: route.priority,
      alternates,
    });
    // Same priority for zh — the pages are equal, not a translation of lesser
    // weight. Signalling otherwise nudges Google to favour en for zh queries.
    out.push({
      url: `${SITE_URL}${zhPath}`,
      lastModified,
      changeFrequency: route.changefreq,
      priority: route.priority,
      alternates,
    });
  }
  return out;
}
