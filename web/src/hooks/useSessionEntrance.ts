"use client";

import { useEffect, useRef } from "react";
import { useAnimationControls, type AnimationControls } from "framer-motion";
import { useReducedMotionPreference } from "./useBrowserCapabilities";

const visible = { opacity: 1, y: 0 };
const hidden = { opacity: 0, y: 12 };

interface EntranceState {
  claimed: boolean;
  finished: boolean;
}

// Kept separate so the mounted-controller contract can be tested with the
// real Framer controller, including React's layout-before-passive teardown.
export function runSessionEntrance(
  controls: AnimationControls,
  state: EntranceState,
  key: string,
  reduced: boolean,
  getStorage: () => Pick<Storage, "getItem" | "setItem"> = () => window.sessionStorage,
) {
  controls.set(visible);
  if (reduced) {
    if (state.claimed) state.finished = true;
    return;
  }
  if (state.finished) return;
  try {
    if (!state.claimed) {
      const storage = getStorage();
      if (storage.getItem(key)) return;
      storage.setItem(key, "1");
      state.claimed = true;
    }
  } catch {
    return;
  }

  let active = true;
  controls.set(hidden);
  void controls.start(visible, { duration: 0.36, ease: [0.2, 0.8, 0.2, 1] }).then(() => {
    if (active) state.finished = true;
  });
  return () => {
    active = false;
    // Framer's layout cleanup can already have unmounted the controller.
    // stop() is safe after unmount; set() would throw. Replay/reduced-motion
    // setup restores the visible state while the controller is mounted.
    controls.stop();
  };
}

/** Render the final state for SSR; claim and play only after hydration. */
export function useSessionEntrance(key: string) {
  const controls = useAnimationControls();
  const reduced = useReducedMotionPreference();
  const state = useRef<EntranceState>({ claimed: false, finished: false });

  useEffect(() => {
    return runSessionEntrance(controls, state.current, key, reduced);
  }, [controls, key, reduced]);

  return controls;
}
