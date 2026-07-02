"use client";

// HomeHero — v9 signature move. First-paint of /home shows a Fraunces serif
// date fading in from y+12 over 360ms (motion.island) with a spring curve,
// followed by a mono-caps stats line. Replays once per session (SPA re-entry
// stays quiet) and collapses to instant on prefers-reduced-motion.
//
// Design source: docs/web-design-v9.md §4.

import { motion, useReducedMotion } from "framer-motion";
import { useEffect, useState } from "react";

interface HomeHeroProps {
  date: string;      // Formatted title, e.g. "2026 · Jul 02"
  weekday: string;   // Short weekday, e.g. "WED"
  sourceCount: number;
  pageCount: number;
  thisWeekCount: number;
}

const PLAYED_KEY = "home-hero-played";

export function HomeHero({ date, weekday, sourceCount, pageCount, thisWeekCount }: HomeHeroProps) {
  const reduced = useReducedMotion();
  const [shouldAnimate, setShouldAnimate] = useState(false);

  useEffect(() => {
    // Only play the entrance once per browser session. Falls back to the
    // static end-state when sessionStorage is unavailable (private mode).
    try {
      if (typeof window === "undefined") return;
      if (sessionStorage.getItem(PLAYED_KEY)) return;
      sessionStorage.setItem(PLAYED_KEY, "1");
      setShouldAnimate(true);
    } catch {
      // sessionStorage blocked — silently stay in the static state.
    }
  }, []);

  const animateIn = shouldAnimate && !reduced;

  return (
    <motion.header
      initial={animateIn ? { opacity: 0, y: 12 } : false}
      animate={animateIn ? { opacity: 1, y: 0 } : undefined}
      transition={{
        duration: 0.36,                       // motion.island
        ease: [0.2, 0.8, 0.2, 1],              // motion.spring
      }}
      className="ds-home-hero"
    >
      <h1 className="ds-home-hero__date">{date}</h1>
      <p className="ds-home-hero__stats">
        <span>{weekday}</span>
        <span aria-hidden="true">·</span>
        <span>{sourceCount} SOURCES</span>
        <span aria-hidden="true">·</span>
        <span>{pageCount} PAGES</span>
        <span aria-hidden="true">·</span>
        <span>{thisWeekCount} THIS WEEK</span>
      </p>
    </motion.header>
  );
}
