"use client";

// CaptureHero — v9 signature entrance for /add.
//
// Mirrors HomeHero on /home: a Fraunces serif date fades in from y+12 over
// 360ms motion.island spring, backed by a mono-caps status line. This turns
// /add from a bare textarea into a museum-restraint "capture the moment"
// ritual entry. Plays once per session (SPA re-entry stays quiet) and
// collapses to instant on prefers-reduced-motion.
//
// Design source: docs/web-design-v9.md §4 (adapted from HomeHero for the
// raw-capture flow — instead of SOURCES/PAGES/THIS WEEK we surface
// RAW · CAPTURE MOMENT and the current queue count so the entrance still
// reads as a wall label, not a form header).

import { motion, useReducedMotion } from "framer-motion";
import { useEffect, useMemo, useState } from "react";

interface CaptureHeroProps {
  queueCount: number;
  doneCount: number;
}

const PLAYED_KEY = "capture-hero-played";

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
] as const;
const WEEKDAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"] as const;

export function CaptureHero({ queueCount, doneCount }: CaptureHeroProps) {
  const reduced = useReducedMotion();
  const [shouldAnimate, setShouldAnimate] = useState(false);

  // Compute date on the client so SSR/client match without hydration flicker.
  // The hero renders the same textual date either way — we just tolerate a
  // one-frame difference when the browser clock crosses midnight.
  const { dateLabel, weekday } = useMemo(() => {
    const d = new Date();
    return {
      dateLabel: `${d.getFullYear()} · ${MONTHS[d.getMonth()]} ${String(d.getDate()).padStart(2, "0")}`,
      weekday: WEEKDAYS[d.getDay()] ?? "SUN",
    };
  }, []);

  useEffect(() => {
    try {
      if (typeof window === "undefined") return;
      if (sessionStorage.getItem(PLAYED_KEY)) return;
      sessionStorage.setItem(PLAYED_KEY, "1");
      setShouldAnimate(true);
    } catch {
      /* sessionStorage blocked — stay static */
    }
  }, []);

  const animateIn = shouldAnimate && !reduced;

  return (
    <motion.header
      initial={animateIn ? { opacity: 0, y: 12 } : false}
      animate={animateIn ? { opacity: 1, y: 0 } : undefined}
      transition={{ duration: 0.36, ease: [0.2, 0.8, 0.2, 1] }}
      className="ds-home-hero ds-capture-hero"
      data-testid="capture-hero"
    >
      <h1 className="ds-home-hero__date">{dateLabel}</h1>
      <p className="ds-home-hero__stats">
        <span>{weekday}</span>
        <span aria-hidden="true">·</span>
        <span>RAW · CAPTURE MOMENT</span>
        <span aria-hidden="true">·</span>
        <span>{queueCount} IN QUEUE</span>
        <span aria-hidden="true">·</span>
        <span>{doneCount} COMPILED</span>
      </p>
    </motion.header>
  );
}
