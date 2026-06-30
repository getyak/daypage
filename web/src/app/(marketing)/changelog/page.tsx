import type { Metadata } from "next";
import { MarketingPageShell } from "../_components/MarketingPageShell";
import { SITE_NAME } from "@/lib/seo";

export const metadata: Metadata = {
  title: "Changelog",
  description:
    "What shipped in DayPage — small, human releases. iOS + macOS + web.",
  alternates: { canonical: "/changelog" },
  openGraph: { title: `Changelog · ${SITE_NAME}` },
};

const RELEASES = [
  {
    version: "0.5",
    date: "2026-06-29",
    title: "Museum aesthetic + Maestro flows",
    notes: [
      "Today screen redesigned around a warm-cream, museum-quiet hero.",
      "Maestro flows aligned with current UI; bilingual labels.",
      "Silent compile when API key is absent.",
    ],
  },
  {
    version: "0.4",
    date: "2026-06-15",
    title: "Memory chat + graph retrieval",
    notes: [
      "Ask past days in natural language — answers cite memos & dates.",
      "Graph retrieval layer (D2) backs the chat with structured context.",
    ],
  },
  {
    version: "0.3",
    date: "2026-05-30",
    title: "Weekly recap + offline queue",
    notes: [
      "Auto-compiles a weekly recap on Monday morning.",
      "Offline capture queue with a quiet status banner.",
    ],
  },
  {
    version: "0.2",
    date: "2026-05-10",
    title: "Voice + EXIF + on-this-day",
    notes: [
      "Whisper transcription for voice memos.",
      "EXIF-aware photo memos (aperture, shutter, ISO).",
      "On-this-day surfacing from the same date in past years.",
    ],
  },
  {
    version: "0.1",
    date: "2026-04-20",
    title: "Private beta",
    notes: [
      "Local-first Markdown vault.",
      "Today / Archive / Graph surfaces.",
      "Nightly compilation pipeline.",
    ],
  },
];

export default function ChangelogPage() {
  return (
    <MarketingPageShell
      eyebrow="Changelog"
      title="Small releases. Honest notes."
      lede="DayPage ships weekly-ish. Notes are written by the people who wrote the code."
    >
      {RELEASES.map((r) => (
        <section key={r.version} className="mt-16">
          <div className="flex items-baseline gap-4">
            <h2 className="!mt-0 !text-[22px]">v{r.version}</h2>
            <time
              dateTime={r.date}
              className="text-[13px] text-[color:var(--fg-subtle-aa)]"
            >
              {r.date}
            </time>
          </div>
          <p className="!mt-2 !text-[18px] font-serif italic text-[color:var(--fg-primary)]">
            {r.title}
          </p>
          <ul>
            {r.notes.map((n) => (
              <li key={n}>{n}</li>
            ))}
          </ul>
        </section>
      ))}
    </MarketingPageShell>
  );
}
