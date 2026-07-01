import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME, SITE_URL, hreflangAlternates } from "@/lib/seo";

const DESC =
  "DayPage is local-first by design. Your raw memos live on your device as Markdown. We do not sell or share your journal data — ever.";

export const metadata: Metadata = {
  title: "Privacy",
  description: DESC,
  alternates: hreflangAlternates("/privacy"),
  openGraph: {
    title: `Privacy · ${SITE_NAME}`,
    description: DESC,
    url: `${SITE_URL}/privacy`,
    type: "website",
    locale: "en_US",
    alternateLocale: ["zh_CN"],
    images: [{ url: "/opengraph-image.png", width: 1200, height: 630, alt: `Privacy · ${SITE_NAME}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `Privacy · ${SITE_NAME}`,
    description: DESC,
    images: ["/opengraph-image.png"],
  },
};

export default function PrivacyPage() {
  return (
    <MarketingPageShell
      eyebrow="Privacy"
      title="Your journal stays yours."
      lede="Local-first is not a slogan — it's the architecture. Here is exactly what touches a network, when, and why."
    >
      <h2>What stays local</h2>
      <p>
        Raw memos, attachments, voice recordings, and the compiled Markdown
        diary all live in a Markdown vault on your device. You can copy the
        folder out, open it in Obsidian, or burn it to a USB stick.
      </p>

      <h2>What goes over the network</h2>
      <ul>
        <li>
          <strong>AI compilation</strong>: at 2am the day's raw text (no audio,
          no images) is sent to your configured LLM provider (OpenAI, DeepSeek,
          or Aliyun DashScope). You bring your own key.
        </li>
        <li>
          <strong>Voice transcription</strong>: M4A files go to Whisper only if
          you enable it, and only the audio for that memo.
        </li>
        <li>
          <strong>Weather + reverse geocoding</strong>: anonymous lat/lng to
          OpenWeatherMap and Apple — never tied to your identity.
        </li>
      </ul>

      <h2>What we never do</h2>
      <ul>
        <li>Sell your data. There is no ad model.</li>
        <li>Train models on your journal.</li>
        <li>Track you across apps.</li>
        <li>Require an account to capture.</li>
      </ul>

      <h2>Crash telemetry</h2>
      <p>
        Optional Sentry crash reports, opt-in only. No memo content is ever
        attached.
      </p>

      <h2>Questions</h2>
      <p>
        Email <a href="mailto:hello@daypage.app">hello@daypage.app</a>. We
        reply.
      </p>
    </MarketingPageShell>
  );
}
