import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternates } from "@/lib/seo";

const DESC =
  "Common questions about DayPage — pricing, privacy, models, sync, and platforms.";

export const metadata: Metadata = {
  title: "FAQ",
  description: DESC,
  alternates: hreflangAlternates("/faq"),
  openGraph: {
    title: `FAQ · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/faq`,
    type: "website",
    locale: "en_US",
    alternateLocale: ["zh_CN"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `FAQ · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `FAQ · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

const FAQS = [
  {
    q: "Is DayPage free?",
    a: "Yes. The app is free. You bring your own LLM key (OpenAI, DeepSeek, or Aliyun DashScope), so the only running cost is your AI usage — usually under $1/month for typical journaling.",
  },
  {
    q: "Where does my data live?",
    a: "On your device, as Markdown files inside a vault folder. You can open it in Obsidian, copy it to a USB stick, or back it up to any sync service you trust.",
  },
  {
    q: "Do you train on my journal?",
    a: "No. We never train models on user data. Your raw memos never reach our servers — they go directly from your device to the LLM provider you configured.",
  },
  {
    q: "What does AI actually do?",
    a: "Every night around 2am, AI reads the day's raw memos and produces: a structured diary page, entity pages for people/places/projects mentioned, and links into your growing knowledge graph. You review in the morning.",
  },
  {
    q: "Which models do you support?",
    a: "OpenAI (gpt-4 / gpt-4o), DeepSeek (deepseek-chat / deepseek-reasoner), and Aliyun DashScope (qwen3.5-plus). Whisper for voice transcription. All configurable.",
  },
  {
    q: "Does it work offline?",
    a: "Capture works fully offline. Voice, text, photo — all queued locally. Compilation needs network to reach the LLM. We surface a quiet banner when something is queued.",
  },
  {
    q: "Is there a web version?",
    a: "Web is read-only for now — you review compiled pages at daypage.app/today. iOS is the primary capture surface. macOS is in private beta.",
  },
  {
    q: "Can I export everything?",
    a: "Your vault is already exported — it's just a folder of Markdown files. Nothing is locked in a proprietary database. Drag the folder, copy it, version-control it.",
  },
];

export default function FaqPage() {
  const faqJsonLd = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: FAQS.map((f) => ({
      "@type": "Question",
      name: f.q,
      acceptedAnswer: { "@type": "Answer", text: f.a },
    })),
    url: `${SITE_URL}/faq`,
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqJsonLd) }}
      />
      <MarketingPageShell
        eyebrow="FAQ"
        title="The questions that come up first."
        lede="Short answers. If something is missing, email us — we keep this page honest."
      >
        {FAQS.map((f, i) => (
          <details
            key={f.q}
            className="group mt-4 rounded-2xl border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/60 p-6 transition-colors hover:border-[color:var(--border-default)]"
            open={i === 0}
          >
            <summary className="cursor-pointer list-none text-[18px] font-medium text-[color:var(--fg-primary)] [&::-webkit-details-marker]:hidden">
              <span className="mr-3 text-[color:var(--accent)]">+</span>
              {f.q}
            </summary>
            <p className="mt-3 !text-[15px] !leading-[1.7] !text-[color:var(--fg-muted)]">
              {f.a}
            </p>
          </details>
        ))}
      </MarketingPageShell>
    </>
  );
}
