"use client";

import { motion, useReducedMotion } from "framer-motion";
import { IPhoneFrame, TodayMockScreen } from "./IPhoneFrame";
import { ShaderBackground } from "./ShaderBackground";
import { SplitText } from "./SplitText";

export function HeroSection() {
  const reduced = useReducedMotion();

  return (
    <section className="relative isolate overflow-hidden">
      <div className="absolute inset-0 -z-10">
        <ShaderBackground className="h-full w-full" />
      </div>

      <div className="mx-auto grid min-h-[100svh] max-w-[1280px] grid-cols-1 items-center gap-12 px-6 pb-24 pt-32 lg:grid-cols-[1.1fr_0.9fr] lg:gap-16 lg:px-10">
        <div className="relative">
          <motion.p
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
            className="mb-6 inline-flex items-center gap-2 rounded-full border border-[color:var(--border-subtle)] bg-[color:var(--surface-white)]/70 px-3 py-1 text-[12px] font-medium text-[color:var(--fg-subtle-aa)] backdrop-blur"
          >
            <span className="h-1.5 w-1.5 rounded-full bg-[color:var(--accent)]" />
            Now in private beta · iOS
          </motion.p>

          <h1 className="font-serif text-[clamp(44px,7vw,84px)] leading-[1.02] tracking-[-0.025em] text-[color:var(--fg-primary)]">
            <SplitText
              text="Your day,"
              as="span"
              className="block"
              stagger={0.06}
              delay={0.1}
            />
            <SplitText
              text="captured raw."
              as="span"
              className="block"
              stagger={0.06}
              delay={0.4}
            />
            <SplitText
              text="Compiled by AI."
              as="span"
              className="mt-2 block font-normal italic text-[color:var(--accent)]"
              stagger={0.06}
              delay={0.75}
            />
          </h1>

          <motion.p
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 1.15, ease: [0.16, 1, 0.3, 1] }}
            className="mt-8 max-w-[520px] text-[18px] leading-[1.55] text-[color:var(--fg-muted)]"
          >
            Dump voice, text, photos into Today. At 2am, AI compiles your raw
            fragments into a structured diary and a knowledge wiki that grows
            with every day.
          </motion.p>

          <motion.div
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 1.3, ease: [0.16, 1, 0.3, 1] }}
            className="mt-10 flex flex-col items-start gap-3 sm:flex-row sm:items-center"
          >
            <a
              href="/download"
              className="inline-flex h-12 items-center justify-center rounded-full bg-[color:var(--accent)] px-7 text-[15px] font-medium text-[color:var(--bg-warm)] shadow-[0_8px_24px_-12px_rgba(93,48,0,0.6)] transition-[transform,background-color] duration-200 hover:bg-[color:var(--accent-hover)] active:scale-[0.98]"
            >
              Start your first day →
            </a>
            <a
              href="/manifesto"
              className="inline-flex h-12 items-center justify-center rounded-full border border-[color:var(--border-default)] bg-[color:var(--surface-white)]/80 px-6 text-[15px] font-medium text-[color:var(--fg-primary)] backdrop-blur transition-colors hover:border-[color:var(--fg-muted)]"
            >
              Read the manifesto
            </a>
          </motion.div>

          <motion.p
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.6, delay: 1.5 }}
            className="mt-6 text-[13px] text-[color:var(--fg-subtle-aa)]"
          >
            Free. No account required. Local-first.
          </motion.p>
        </div>

        <div className="relative flex justify-center lg:justify-end">
          <motion.div
            initial={reduced ? { opacity: 0 } : { opacity: 0, x: 40, y: 10, rotate: 2 }}
            animate={reduced ? { opacity: 1 } : { opacity: 1, x: 0, y: 0, rotate: -1.5 }}
            transition={
              reduced
                ? { duration: 0.3 }
                : { type: "spring", stiffness: 90, damping: 18, delay: 1.0 }
            }
            style={{ willChange: "transform, opacity" }}
          >
            <IPhoneFrame width={320}>
              <TodayMockScreen />
            </IPhoneFrame>
          </motion.div>
        </div>
      </div>

      <motion.div
        aria-hidden
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 0.6, delay: 2 }}
        className="absolute bottom-8 left-1/2 -translate-x-1/2 text-[color:var(--fg-subtle-aa)]"
      >
        <motion.div
          animate={reduced ? undefined : { y: [0, 6, 0] }}
          transition={{ duration: 2.2, repeat: Infinity, ease: "easeInOut" }}
        >
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
            <path
              d="M5 8l5 5 5-5"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </motion.div>
      </motion.div>
    </section>
  );
}
