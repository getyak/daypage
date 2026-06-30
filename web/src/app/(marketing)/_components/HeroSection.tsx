"use client";

import { useRef } from "react";
import {
  motion,
  useReducedMotion,
  useScroll,
  useTransform,
} from "framer-motion";
import { DeviceConstellation } from "./DeviceConstellation";
import { ShaderBackground } from "./ShaderBackground";
import { SplitText } from "./SplitText";

export function HeroSection() {
  const reduced = useReducedMotion();
  const sectionRef = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({
    target: sectionRef,
    offset: ["start start", "end start"],
  });
  // Subtle scroll-linked parallax: iPhone drifts up + tilts slightly as user scrolls.
  // Disabled implicitly when reduced-motion is set (we feed 0 below).
  const parallaxY = useTransform(scrollYProgress, [0, 1], [0, -60]);
  const heroFade = useTransform(scrollYProgress, [0, 0.8], [1, 0.45]);

  return (
    <section ref={sectionRef} className="relative isolate overflow-hidden">
      <div className="absolute inset-0 -z-10">
        <ShaderBackground className="h-full w-full" />
        {/* Two ambient glow orbs — drift the eye, never compete with content */}
        <div
          aria-hidden
          className="pointer-events-none absolute -right-[15%] top-[10%] h-[520px] w-[520px] rounded-full opacity-[0.42] mix-blend-multiply"
          style={{
            background:
              "radial-gradient(circle at center, rgba(124,45,18,0.32) 0%, transparent 65%)",
            filter: "blur(60px)",
          }}
        />
        <div
          aria-hidden
          className="pointer-events-none absolute -left-[10%] bottom-[5%] h-[440px] w-[440px] rounded-full opacity-[0.28] mix-blend-multiply"
          style={{
            background:
              "radial-gradient(circle at center, rgba(228,164,82,0.42) 0%, transparent 65%)",
            filter: "blur(80px)",
          }}
        />
      </div>

      <div className="hero-shell mx-auto grid min-h-[92svh] max-w-[1440px] grid-cols-1 items-center gap-10 px-6 pb-20 pt-28 md:min-h-[100svh] md:gap-12 md:pb-24 md:pt-32 lg:grid-cols-[1fr_1.05fr] lg:gap-14 lg:px-10 xl:gap-20">
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

          <h1 className="font-serif text-[clamp(36px,6.4vw,78px)] leading-[1.04] tracking-[-0.025em] text-[color:var(--fg-primary)]">
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
              className="cta-magnetic inline-flex h-12 items-center justify-center rounded-full bg-[color:var(--accent)] px-7 text-[15px] font-medium text-[color:var(--bg-warm)] shadow-[0_8px_24px_-12px_rgba(93,48,0,0.6)] hover:bg-[color:var(--accent-hover)]"
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

        <div className="relative flex w-full justify-center lg:justify-end">
          <motion.div
            className="w-full max-w-[640px]"
            style={
              reduced
                ? { willChange: "opacity" }
                : {
                    y: parallaxY,
                    opacity: heroFade,
                    willChange: "transform, opacity",
                  }
            }
          >
            <DeviceConstellation />
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
