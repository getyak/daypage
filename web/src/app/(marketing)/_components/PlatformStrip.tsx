"use client";

import { motion, useReducedMotion } from "framer-motion";

type Status = "available" | "beta" | "private" | "soon";

type Platform = {
  name: string;
  tagline: string;
  status: Status;
  icon: React.ReactNode;
};

const STATUS_LABEL: Record<Status, string> = {
  available: "Available",
  beta: "Beta · TestFlight",
  private: "Private beta",
  soon: "Coming soon",
};

const STATUS_TONE: Record<Status, string> = {
  available: "bg-[color:var(--accent)] text-[color:var(--bg-warm)]",
  beta: "bg-[color:var(--accent-soft)] text-[color:var(--accent)] border border-[color:var(--accent-border)]",
  private:
    "bg-[color:var(--surface-white)] text-[color:var(--fg-muted)] border border-[color:var(--border-default)]",
  soon: "bg-transparent text-[color:var(--fg-subtle-aa)] border border-dashed border-[color:var(--border-default)]",
};

const PLATFORMS: Platform[] = [
  {
    name: "iOS",
    tagline: "Capture-first. Voice, text, photo, location.",
    status: "beta",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" width="22" height="22">
        <rect x="6" y="2.5" width="12" height="19" rx="3" stroke="currentColor" strokeWidth="1.6" />
        <circle cx="12" cy="18.5" r="0.9" fill="currentColor" />
      </svg>
    ),
  },
  {
    name: "macOS",
    tagline: "Wider canvas for review and editing.",
    status: "private",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" width="22" height="22">
        <rect x="3" y="4" width="18" height="12" rx="1.6" stroke="currentColor" strokeWidth="1.6" />
        <path d="M1.5 18.5h21l-1.2 1.5h-18.6L1.5 18.5z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    ),
  },
  {
    name: "watchOS",
    tagline: "Glance-and-tap voice memos from the wrist.",
    status: "soon",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" width="22" height="22">
        <rect x="6" y="6" width="12" height="14" rx="3.5" stroke="currentColor" strokeWidth="1.6" />
        <path d="M9 4.5l.6-1.6h4.8L15 4.5M9 21.5l.6 1.6h4.8L15 21.5" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
        <path d="M19 11v2" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    ),
  },
  {
    name: "Web",
    tagline: "Read your compiled diary anywhere.",
    status: "available",
    icon: (
      <svg viewBox="0 0 24 24" fill="none" width="22" height="22">
        <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.6" />
        <path d="M3 12h18M12 3c2.8 3 2.8 15 0 18M12 3c-2.8 3-2.8 15 0 18" stroke="currentColor" strokeWidth="1.4" />
      </svg>
    ),
  },
];

/**
 * Four-platform strip placed under SocialProof. Surfaces all surfaces with
 * honest status badges. Mobile collapses to a 2x2 grid; desktop stays in a row.
 */
export function PlatformStrip() {
  const reduced = useReducedMotion();

  return (
    <section
      id="platforms"
      aria-label="DayPage across your devices"
      className="border-b border-[color:var(--border-subtle)] bg-[color:var(--bg-warm)]"
    >
      <div className="mx-auto max-w-[1280px] px-6 py-16 lg:px-10 lg:py-20">
        <div className="mb-10 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="text-[12px] font-medium uppercase tracking-[0.16em] text-[color:var(--accent)]">
              Built for every screen
            </p>
            <h2 className="mt-3 max-w-[640px] font-serif text-[clamp(28px,4vw,40px)] leading-[1.15] tracking-[-0.02em] text-[color:var(--fg-primary)]">
              One vault. Four surfaces. Your day, wherever you are.
            </h2>
          </div>
          <p className="max-w-[320px] text-[14px] leading-[1.6] text-[color:var(--fg-muted)]">
            Capture on the device closest to your mouth. Review on the one with
            the biggest canvas.
          </p>
        </div>

        <ul
          role="list"
          className="grid grid-cols-2 gap-3 md:grid-cols-4 md:gap-4"
        >
          {PLATFORMS.map((p, i) => (
            <motion.li
              key={p.name}
              initial={reduced ? { opacity: 0 } : { opacity: 0, y: 12 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-60px" }}
              transition={{ delay: 0.06 * i, duration: 0.4 }}
              className="group flex flex-col gap-4 rounded-2xl border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/70 p-5 transition-colors hover:border-[color:var(--border-default)]"
            >
              <div className="flex items-center justify-between">
                <span className="inline-flex h-10 w-10 items-center justify-center rounded-xl bg-[color:var(--surface-sunken)] text-[color:var(--fg-primary)]">
                  {p.icon}
                </span>
                <span
                  className={`inline-flex items-center rounded-full px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.08em] ${STATUS_TONE[p.status]}`}
                >
                  {STATUS_LABEL[p.status]}
                </span>
              </div>
              <div>
                <h3 className="font-serif text-[20px] tracking-[-0.01em] text-[color:var(--fg-primary)]">
                  {p.name}
                </h3>
                <p className="mt-2 text-[13px] leading-[1.55] text-[color:var(--fg-muted)]">
                  {p.tagline}
                </p>
              </div>
            </motion.li>
          ))}
        </ul>
      </div>
    </section>
  );
}
