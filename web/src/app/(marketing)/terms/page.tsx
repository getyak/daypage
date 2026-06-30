import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME } from "@/lib/seo";

export const metadata: Metadata = {
  title: "Terms",
  description: `Terms of use for ${SITE_NAME} — short, plain English.`,
  alternates: { canonical: "/terms" },
  openGraph: { title: `Terms · ${SITE_NAME}` },
};

export default function TermsPage() {
  return (
    <MarketingPageShell
      eyebrow="Terms"
      title="Short, plain English."
      lede="DayPage is provided as-is. Be kind to your data — back it up. Be kind to your model — bring your own key."
    >
      <h2>You own your journal</h2>
      <p>
        All content you capture in DayPage remains your property. We make no
        claim over your memos, photos, voice recordings, or compiled pages.
      </p>

      <h2>You are responsible for your API keys</h2>
      <p>
        Bringing your own LLM key means usage charges from that provider are
        yours. We do not proxy your traffic.
      </p>

      <h2>No warranty</h2>
      <p>
        Software is provided without warranty. Back up your Markdown vault
        regularly. We are early — bugs happen.
      </p>

      <h2>Acceptable use</h2>
      <ul>
        <li>Don't use DayPage to harm others.</li>
        <li>Don't reverse-engineer the AI pipeline to abuse third-party APIs.</li>
      </ul>

      <h2>Changes</h2>
      <p>
        We may update these terms; material changes will be announced in the
        changelog.
      </p>
    </MarketingPageShell>
  );
}
