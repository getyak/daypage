import { SITE_NAME, SITE_URL, absoluteUrl } from "@/lib/seo";

type Crumb = { name: string; path: string };

/**
 * Emit a schema.org BreadcrumbList as JSON-LD.
 *
 * Google uses this to show breadcrumb chips in the SERP snippet — pages
 * without one render as "example.com › manifesto" (auto-inferred) which
 * often mis-labels intermediate segments. Explicit crumbs win the label.
 */
export function BreadcrumbJsonLd({ items }: { items: Crumb[] }) {
  const doc = {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((c, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: c.name,
      item: absoluteUrl(c.path),
    })),
  };
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(doc) }}
    />
  );
}

/**
 * Emit a schema.org Article as JSON-LD for long-form marketing pages
 * (manifesto, about, privacy, terms). Google Discover surfaces Articles;
 * plain <MarketingPageShell> pages default to WebPage which is weaker.
 */
export function ArticleJsonLd({
  headline,
  description,
  path,
  datePublished,
  dateModified,
  inLanguage = "en",
}: {
  headline: string;
  description: string;
  path: string;
  datePublished: string;
  dateModified?: string;
  inLanguage?: "en" | "zh-CN";
}) {
  const url = absoluteUrl(path);
  const doc = {
    "@context": "https://schema.org",
    "@type": "Article",
    headline,
    description,
    url,
    mainEntityOfPage: url,
    inLanguage,
    datePublished,
    dateModified: dateModified ?? datePublished,
    image: absoluteUrl("/opengraph-image.png"),
    author: { "@type": "Organization", name: SITE_NAME, url: SITE_URL },
    publisher: {
      "@type": "Organization",
      name: SITE_NAME,
      url: SITE_URL,
      logo: {
        "@type": "ImageObject",
        url: absoluteUrl("/apple-icon"),
      },
    },
  };
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(doc) }}
    />
  );
}

/**
 * Emit a schema.org ItemList — the recommended shape for changelog / release
 * pages, since each release is a discrete entity Google can list separately.
 */
export function ItemListJsonLd({
  name,
  items,
}: {
  name: string;
  items: { name: string; url: string; description?: string }[];
}) {
  const doc = {
    "@context": "https://schema.org",
    "@type": "ItemList",
    name,
    itemListElement: items.map((it, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: it.name,
      url: it.url,
      ...(it.description ? { description: it.description } : {}),
    })),
  };
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(doc) }}
    />
  );
}
