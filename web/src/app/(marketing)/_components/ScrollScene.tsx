"use client";

import {
  motion,
  useScroll,
  useReducedMotion,
  type MotionValue,
} from "framer-motion";
import { useRef, type ReactNode } from "react";

interface ScrollSceneProps {
  /** Total scroll height in viewport units, default 3 = 300vh. */
  acts?: number;
  /** Render left-side copy. Receives scrollYProgress for per-act fades. */
  copy: (progress: MotionValue<number>) => ReactNode;
  /** Render right-side sticky stage (e.g. iPhone). Receives progress. */
  stage: (progress: MotionValue<number>) => ReactNode;
  id?: string;
  tone?: "warm" | "sunken";
  label?: string;
}

const TONE_BG: Record<NonNullable<ScrollSceneProps["tone"]>, string> = {
  warm: "bg-[color:var(--bg-warm)]",
  sunken: "bg-[color:var(--surface-sunken)]",
};

/**
 * Pinned scroll container. The scrollable region is `acts * 100vh` tall;
 * inside it, a sticky inner panel renders the copy + stage side-by-side.
 * Scroll progress (0 → 1 across the whole region) is passed to both render
 * props so consumers map it to per-act animations via useTransform — no
 * setState in the scroll handler.
 *
 * Falls back to plain stacked layout when prefers-reduced-motion is on.
 */
export function ScrollScene({
  acts = 3,
  copy,
  stage,
  id,
  tone = "warm",
  label,
}: ScrollSceneProps) {
  const targetRef = useRef<HTMLDivElement | null>(null);
  const reduced = useReducedMotion();

  const { scrollYProgress } = useScroll({
    target: targetRef,
    offset: ["start start", "end end"],
  });

  if (reduced) {
    return (
      <section id={id} className={`relative ${TONE_BG[tone]}`}>
        {Array.from({ length: acts }, (_, i) => (
          <div
            key={i}
            className="mx-auto grid max-w-[1280px] grid-cols-1 items-center gap-12 px-6 py-24 lg:grid-cols-2 lg:px-10"
          >
            <div>{copy(scrollYProgress)}</div>
            <div className="flex justify-center">{stage(scrollYProgress)}</div>
          </div>
        ))}
      </section>
    );
  }

  return (
    <section
      id={id}
      ref={targetRef}
      className={`${TONE_BG[tone]}`}
      style={{ position: "relative", height: `${acts * 100}svh` }}
    >
      <div className="sticky top-0 flex h-[100svh] items-center overflow-hidden">
        <div className="mx-auto grid w-full max-w-[1280px] grid-cols-1 items-center gap-12 px-6 lg:grid-cols-[1fr_1fr] lg:gap-16 lg:px-10">
          <div className="relative">
            {label ? (
              <p className="mb-6 text-[12px] font-semibold uppercase tracking-[0.14em] text-[color:var(--fg-subtle-aa)]">
                {label}
              </p>
            ) : null}
            <motion.div style={{ willChange: "transform, opacity" }}>
              {copy(scrollYProgress)}
            </motion.div>
          </div>
          <div className="relative flex justify-center lg:justify-end">
            {stage(scrollYProgress)}
          </div>
        </div>
      </div>
    </section>
  );
}
