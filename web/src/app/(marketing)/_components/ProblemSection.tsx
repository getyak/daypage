"use client";

import { motion, useReducedMotion } from "framer-motion";
import { SplitText } from "./SplitText";

export function ProblemSection() {
  const reduced = useReducedMotion();

  return (
    <section
      id="problem"
      className="relative flex min-h-[100svh] items-center overflow-hidden bg-[color:var(--fg-primary)]"
    >
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            "radial-gradient(ellipse 65% 50% at 50% 50%, rgba(250,248,246,0.04), transparent 70%)",
        }}
      />

      <div className="relative mx-auto w-full max-w-[1100px] px-6 py-32 lg:px-10">
        <motion.p
          initial={{ opacity: 0, y: 8 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-25% 0px" }}
          transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
          className="mb-8 text-[12px] font-semibold uppercase tracking-[0.14em] text-[color:var(--bg-warm)]/45"
        >
          The problem
        </motion.p>

        <h2 className="max-w-[920px] font-serif text-[clamp(40px,6.5vw,82px)] italic leading-[1.05] tracking-[-0.02em] text-[color:var(--bg-warm)]">
          {reduced ? (
            "You forget. The day forgets you back."
          ) : (
            <>
              <SplitText
                text="You forget."
                as="span"
                className="block"
                stagger={0.08}
                delay={0.1}
              />
              <SplitText
                text="The day forgets you back."
                as="span"
                className="mt-2 block text-[color:var(--bg-warm)]/70"
                stagger={0.08}
                delay={0.65}
              />
            </>
          )}
        </h2>

        <motion.p
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-25% 0px" }}
          transition={{ duration: 0.6, delay: 1.3, ease: [0.16, 1, 0.3, 1] }}
          className="mt-12 max-w-[560px] text-[17px] leading-[1.6] text-[color:var(--bg-warm)]/65"
        >
          By the time you sit down to journal, the texture of the day is gone —
          the sounds, the photos, the half-formed thoughts. DayPage catches
          them as they happen, then weaves them together while you sleep.
        </motion.p>
      </div>
    </section>
  );
}
