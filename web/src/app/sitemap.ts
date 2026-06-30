import type { MetadataRoute } from "next";
import { PUBLIC_ROUTES, SITE_URL } from "@/lib/seo";

export default function sitemap(): MetadataRoute.Sitemap {
  const lastModified = new Date();
  const out: MetadataRoute.Sitemap = [];
  for (const route of PUBLIC_ROUTES) {
    const enPath = route.path === "/" ? "" : route.path;
    const zhPath = `/zh${route.path === "/" ? "" : route.path}`;
    const alternates = {
      languages: {
        en: `${SITE_URL}${enPath}`,
        "zh-CN": `${SITE_URL}${zhPath}`,
      },
    };
    out.push({
      url: `${SITE_URL}${enPath}`,
      lastModified,
      changeFrequency: route.changefreq,
      priority: route.priority,
      alternates,
    });
    out.push({
      url: `${SITE_URL}${zhPath}`,
      lastModified,
      changeFrequency: route.changefreq,
      priority: route.priority * 0.9,
      alternates,
    });
  }
  return out;
}
