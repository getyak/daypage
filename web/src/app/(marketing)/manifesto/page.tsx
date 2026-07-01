import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternates } from "@/lib/seo";
import { ArticleJsonLd, BreadcrumbJsonLd } from "@/components/PageJsonLd";

const DESC =
  "Why DayPage exists — a local-first, AI-assisted journal for people who would rather dump than perform.";

export const metadata: Metadata = {
  title: "Manifesto",
  description: DESC,
  alternates: hreflangAlternates("/manifesto"),
  openGraph: {
    title: `Manifesto · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/manifesto`,
    type: "article",
    locale: "en_US",
    alternateLocale: ["zh_CN"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `Manifesto · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `Manifesto · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

export default function ManifestoPage() {
  return (
    <>
      <ArticleJsonLd
        headline={`Manifesto · ${SITE_NAME}`}
        description={DESC}
        path="/manifesto"
        datePublished="2026-05-11"
        dateModified="2026-07-02"
        inLanguage="en"
      />
      <BreadcrumbJsonLd
        items={[
          { name: "Home", path: "/" },
          { name: "Manifesto", path: "/manifesto" },
        ]}
      />
    <MarketingPageShell
      eyebrow="Manifesto"
      title="A journal you actually use beats a perfect one you don't."
      lede="DayPage is built for the way memory actually works — messy, fragmented, mostly forgotten. It collects the raw stuff during the day and lets AI do the shaping at night."
    >
      <h2>The problem with journaling</h2>
      <p>
        Most journals demand a kind of performance: full sentences, calm
        composure, retrospective wisdom. By the time you have all three at once,
        the day is gone.
      </p>
      <p>
        We dump fragments at people we trust — friends, group chats, voice
        memos to ourselves. That's where the real signal lives. DayPage takes
        that input mode seriously.
      </p>

      <h2>Three rules</h2>
      <h3>1. Local-first, always.</h3>
      <p>
        Your raw memos live as Markdown files on your device. No account
        required. Sync, only when you say so. If we disappear tomorrow your
        diary still opens in any text editor.
      </p>
      <h3>2. Capture is sacred. Compilation is opinionated.</h3>
      <p>
        Today is a no-friction inbox. There is no formatting, no required
        title, no mood picker. At 2am, an LLM reads the day and produces a
        structured page: places, people, themes, decisions, open loops.
      </p>
      <h3>3. The graph is a side effect, not the goal.</h3>
      <p>
        Entities and links are discovered while compiling, not enforced while
        writing. The knowledge graph grows because you lived a life, not
        because you tagged one.
      </p>

      <h2>Who this is for</h2>
      <p>
        Nomads, builders, researchers, and anyone whose week is too varied to
        fit a Notion template. If you have ever tried to start a journal three
        times and given up, this is the fourth try that sticks.
      </p>
    </MarketingPageShell>
    </>
  );
}
