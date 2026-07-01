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

// SearchAction removed: DayPage has no site-wide search endpoint. Declaring one
// that returns 404 is worse than declaring none — Google flags it as invalid.
const website = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  name: SITE_NAME,
  url: SITE_URL,
  description: SITE_TAGLINE,
  inLanguage: ["en", "zh-CN"],
  publisher: { "@type": "Organization", name: SITE_NAME, url: SITE_URL },
};

// aggregateRating removed: the previous values (4.8/128) were placeholders.
// Google Search treats fabricated review data as spammy structured data and
// can apply a manual action. Re-add only with a verifiable review source.
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
    availability: "https://schema.org/InStock",
  },
  description: SITE_DESCRIPTION,
  url: SITE_URL,
  screenshot: absoluteUrl("/opengraph-image.png"),
  softwareVersion: "0.5",
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
