"use client";

import { useEffect } from "react";
import { useAnimationControls } from "framer-motion";
import { usePrefersReducedMotion } from "./useBrowserSnapshot";

export function useSessionEntrance(key: string) {
  const controls = useAnimationControls();
  const reduced = usePrefersReducedMotion();
  useEffect(() => {
    controls.set({ opacity: 1, y: 0 });
    if (!reduced) {
      try {
        if (!sessionStorage.getItem(key)) {
          sessionStorage.setItem(key, "1");
          controls.set({ opacity: 0, y: 12 });
          void controls.start({ opacity: 1, y: 0 });
        }
      } catch { /* Storage unavailable: retain the visible static state. */ }
    }
    return () => {
      controls.stop();
      controls.set({ opacity: 1, y: 0 });
    };
  }, [controls, key, reduced]);
  return controls;
}
