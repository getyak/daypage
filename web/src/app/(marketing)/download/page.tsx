import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME } from "@/lib/seo";

export const metadata: Metadata = {
  title: "Download",
  description:
    "Get DayPage for iOS. Free, local-first, no account required. macOS in private beta.",
  alternates: { canonical: "/download" },
  openGraph: {
    title: `Download · ${SITE_NAME}`,
    description: "Free, local-first journaling app for iOS 16+.",
  },
};

export default function DownloadPage() {
  return (
    <MarketingPageShell
      eyebrow="Download"
      title="Free. No account. Yours."
      lede="DayPage is shipping for iOS first. macOS is in private beta. Web client is for read-only review."
    >
      <h2>iOS</h2>
      <p>
        Requires iOS 16 or later. Private beta via TestFlight while we polish
        sync. Email <a href="mailto:hello@daypage.app">hello@daypage.app</a> for
        an invite — include a sentence about what you'd journal.
      </p>

      <h2>macOS</h2>
      <p>
        SwiftUI desktop client with a wider canvas for editing compiled pages.
        Private beta. Same email.
      </p>

      <h2>Web</h2>
      <p>
        Read your journal anywhere at <a href="/today">daypage.app/today</a>.
        Capture is iOS-only for now — the web client is for reviewing what AI
        compiled overnight.
      </p>

      <h2>What you'll need</h2>
      <ul>
        <li>About 20 raw memos a day. Voice, text, photo, location.</li>
        <li>An OpenAI / DeepSeek / Aliyun API key (your data, your model).</li>
        <li>Five minutes the next morning to read the compiled page.</li>
      </ul>
    </MarketingPageShell>
  );
}
