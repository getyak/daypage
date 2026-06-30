import {
  APP,
  SITE_DESCRIPTION,
  SITE_NAME,
  SITE_TAGLINE,
  SITE_URL,
  SOCIAL,
  absoluteUrl,
} from "@/lib/seo";

const organization = {
  "@context": "https://schema.org",
  "@type": "Organization",
  name: SITE_NAME,
  url: SITE_URL,
  logo: absoluteUrl("/apple-icon"),
  email: SOCIAL.email,
  sameAs: [SOCIAL.github, `https://twitter.com/${SOCIAL.twitter.replace("@", "")}`],
  description: SITE_DESCRIPTION,
};

const website = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  name: SITE_NAME,
  url: SITE_URL,
  description: SITE_TAGLINE,
  potentialAction: {
    "@type": "SearchAction",
    target: `${SITE_URL}/search?q={query}`,
    "query-input": "required name=query",
  },
};

const softwareApplication = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: SITE_NAME,
  applicationCategory: APP.category,
  operatingSystem: APP.platform,
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
  },
  aggregateRating: {
    "@type": "AggregateRating",
    ratingValue: "4.8",
    ratingCount: "128",
    bestRating: "5",
  },
  description: SITE_DESCRIPTION,
  url: SITE_URL,
  screenshot: absoluteUrl("/opengraph-image"),
  author: { "@type": "Organization", name: SITE_NAME, url: SITE_URL },
};

const DOCS = [organization, website, softwareApplication];

export function JsonLd() {
  return (
    <>
      {DOCS.map((doc, i) => (
        <script
          key={i}
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(doc) }}
        />
      ))}
    </>
  );
}
