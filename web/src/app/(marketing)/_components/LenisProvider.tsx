"use client";

import { useEffect } from "react";
import Lenis from "lenis";
import { useReducedMotionPreference } from "@/hooks/useBrowserCapabilities";

export function LenisProvider({ children }: { children: React.ReactNode }) {
  const reduced = useReducedMotionPreference();
  useEffect(() => {
    if (typeof window === "undefined" || reduced) return;

    const lenis = new Lenis({
      duration: 1.2,
      easing: (t: number) => Math.min(1, 1.001 - Math.pow(2, -10 * t)),
      smoothWheel: true,
      syncTouch: false,
    });

    let rafId = 0;
    const raf = (time: number) => {
      lenis.raf(time);
      rafId = requestAnimationFrame(raf);
    };
    rafId = requestAnimationFrame(raf);

    return () => {
      cancelAnimationFrame(rafId);
      lenis.destroy();
    };
  }, [reduced]);

  return <>{children}</>;
}
