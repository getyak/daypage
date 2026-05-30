"use client";

import { useEffect, useMemo, useRef, useState } from "react";

/**
 * useWaveform — simulated live microphone waveform.
 *
 * Ported from .design-handoff/v8/composer.jsx:5-31. Produces an organic,
 * continuously-shifting bar array driven by a phase-based sine/cosine envelope
 * plus a touch of noise. Each animation frame shifts the buffer left and pushes
 * a fresh sample on the right, so the waveform appears to scroll.
 *
 * Shared primitive for both <RecordingSheet> (count ~64) and the Dynamic Island
 * live activity (count ~18). Returns a `number[]` of bar heights in the range
 * [2, 28]. When `active` is false the buffer resets to a flat baseline (all 2s)
 * and the animation loop is torn down.
 *
 * "use client" — relies on requestAnimationFrame; consumers must be client
 * components.
 */
export function useWaveform(active: boolean, count = 56): number[] {
  // Flat baseline buffer used whenever the waveform is idle. Memoized so its
  // identity only changes with `count`, never per render.
  const baseline = useMemo(() => Array<number>(count).fill(2), [count]);

  const [liveBars, setLiveBars] = useState<number[]>(baseline);
  const rafRef = useRef(0);
  const tickRef = useRef(0);

  useEffect(() => {
    if (!active) return;

    const loop = () => {
      tickRef.current += 1;
      setLiveBars((prev) => {
        // shift left, push a new sample at the right edge
        const source = prev.length === count ? prev : baseline;
        const next = source.slice(1);
        const phase = tickRef.current * 0.18;
        const env = 0.55 + 0.45 * Math.sin(phase * 0.4);
        const v =
          4 +
          Math.abs(
            Math.sin(phase) * 14 +
              Math.cos(phase * 2.7) * 8 +
              (Math.random() - 0.5) * 6
          ) *
            env;
        next.push(Math.max(2, Math.min(28, v)));
        return next;
      });
      rafRef.current = requestAnimationFrame(loop);
    };

    rafRef.current = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(rafRef.current);
  }, [active, count, baseline]);

  // While idle, return the flat baseline directly rather than resetting state
  // inside the effect (avoids cascading-render lint + an extra commit).
  return active ? liveBars : baseline;
}
