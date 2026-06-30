"use client";

import { motion, useReducedMotion } from "framer-motion";

const BADGES = [
  { label: "Local-first", hint: "Your data on your device" },
  { label: "Privacy by default", hint: "No training. No selling." },
  { label: "Bring-your-own-LLM", hint: "OpenAI · DeepSeek · Qwen" },
  { label: "Open vault", hint: "Plain Markdown, always" },
];

const STATS = [
  { value: "20", suffix: "+", label: "memos/day, comfortably" },
  { value: "2", suffix: "am", label: "AI compiles overnight" },
  { value: "0", suffix: "", label: "vendor lock-in" },
];

export function SocialProof() {
  const reduced = useReducedMotion();

  return (
    <section
      aria-label="What people trust about DayPage"
      className="relative border-y border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/40"
    >
      <div className="mx-auto max-w-[1280px] px-6 py-12 lg:px-10">
        <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-[1.1fr_0.9fr]">
          <div>
            <p className="text-[12px] font-medium uppercase tracking-[0.16em] text-[color:var(--fg-subtle-aa)]">
              What stays true
            </p>
            <ul className="mt-5 flex flex-wrap gap-2.5">
              {BADGES.map((b, i) => (
                <motion.li
                  key={b.label}
                  initial={reduced ? { opacity: 0 } : { opacity: 0, y: 6 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true, margin: "-80px" }}
                  transition={{ delay: 0.04 * i, duration: 0.4 }}
                  className="group inline-flex items-center gap-2 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)] px-3.5 py-1.5"
                >
                  <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--accent)] transition-transform duration-300 group-hover:scale-150" />
                  <span className="text-[13px] font-medium text-[color:var(--fg-primary)]">
                    {b.label}
                  </span>
                  <span className="hidden text-[12px] text-[color:var(--fg-subtle-aa)] md:inline">
                    · {b.hint}
                  </span>
                </motion.li>
              ))}
            </ul>
          </div>

          <dl className="grid grid-cols-3 gap-4 border-l border-[color:var(--border-subtle)] pl-8 lg:pl-12">
            {STATS.map((s, i) => (
              <motion.div
                key={s.label}
                initial={reduced ? { opacity: 0 } : { opacity: 0, y: 8 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, margin: "-80px" }}
                transition={{ delay: 0.06 * i, duration: 0.5 }}
              >
                <dt className="font-serif text-[clamp(32px,4vw,44px)] leading-none tracking-[-0.02em] text-[color:var(--fg-primary)]">
                  {s.value}
                  <span className="text-[color:var(--accent)]">{s.suffix}</span>
                </dt>
                <dd className="mt-2 text-[12px] leading-tight text-[color:var(--fg-subtle-aa)]">
                  {s.label}
                </dd>
              </motion.div>
            ))}
          </dl>
        </div>
      </div>
    </section>
  );
}
