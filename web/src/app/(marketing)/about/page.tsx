import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME } from "@/lib/seo";

export const metadata: Metadata = {
  title: "About",
  description:
    "DayPage is built by a small team that wanted a journal that survives nomad life. Here is who, and why.",
  alternates: { canonical: "/about" },
  openGraph: { title: `About · ${SITE_NAME}` },
};

export default function AboutPage() {
  return (
    <MarketingPageShell
      eyebrow="About"
      title="Built by people who keep losing their notes."
      lede="DayPage started as a personal tool. The author's previous journal app got abandoned three months in. This one was designed to survive."
    >
      <h2>Origin</h2>
      <p>
        After the fourth abandoned journal app, the author started thinking
        about the actual capture mode: voice memos in a noisy cafe, a photo of
        a whiteboard, a 2-line thought before sleep. None of these are diary
        entries. All of them are signal.
      </p>
      <p>
        DayPage separates capture from composition. You dump. AI assembles. You
        review.
      </p>

      <h2>Team</h2>
      <p>
        Currently a solo project with help from friends on design and copy.
        Open source pieces will be published once the core stabilises.
      </p>

      <h2>Where it's going</h2>
      <ul>
        <li>macOS desktop client out of private beta.</li>
        <li>Better cross-device sync, still local-first.</li>
        <li>Plugin surface for connectors (Twitter likes, Slack threads).</li>
      </ul>

      <h2>Talk to us</h2>
      <p>
        Email <a href="mailto:hello@daypage.app">hello@daypage.app</a>, or
        open an issue on <a href="https://github.com/getyak/daypage">GitHub</a>.
      </p>
    </MarketingPageShell>
  );
}
