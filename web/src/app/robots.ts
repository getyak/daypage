import type { MetadataRoute } from "next";
import { SITE_URL } from "@/lib/seo";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: "*",
        allow: "/",
        disallow: [
          "/api/",
          "/today",
          "/inbox",
          "/insights",
          "/wiki",
          "/memos",
          "/chat",
          "/agents",
          "/orbit",
          "/domain",
          "/add",
          "/settings",
          "/login",
          "/home",
          "/design-demo",
        ],
      },
      {
        userAgent: "GPTBot",
        allow: "/",
        disallow: ["/api/", "/today", "/inbox", "/wiki", "/memos"],
      },
    ],
    sitemap: `${SITE_URL}/sitemap.xml`,
    host: SITE_URL,
  };
}
