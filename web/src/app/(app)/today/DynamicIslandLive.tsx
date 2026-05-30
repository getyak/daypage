"use client";

import { useWaveform } from "@/hooks/useWaveform";
import { Waveform } from "@/components/ui/Waveform";

interface DynamicIslandLiveProps {
  /** Whether a recording is in progress (expands the capsule + animates). */
  active: boolean;
  /** Elapsed recording seconds. */
  elapsed: number;
}

function formatClock(elapsed: number): string {
  const mm = String(Math.floor(elapsed / 60)).padStart(2, "0");
  const ss = String(Math.floor(elapsed % 60)).padStart(2, "0");
  return `${mm}:${ss}`;
}

/**
 * DynamicIslandLive — top-center live-activity capsule shown while recording.
 *
 * Ported from .design-handoff/v8/composer.jsx:485-520. A black pill pinned to
 * top:11 that expands from 126px (idle) to 248px (active) over 360ms, revealing
 * a pulsing mic dot + JetBrains-mono timer on the left and an 18-bar mini
 * Waveform on the right. Mirrors the iOS Dynamic Island live activity.
 */
export function DynamicIslandLive({ active, elapsed }: DynamicIslandLiveProps) {
  const bars = useWaveform(active, 18);

  // Unlike the prototype (which renders an idle 126px black capsule overlaid on
  // the simulated iOS notch), the real web page has no device chrome — an idle
  // black pill would just be a stray bar at the top. Only mount while recording.
  if (!active) return null;

  return (
    <div
      style={{
        position: "absolute",
        top: 11,
        left: "50%",
        transform: "translateX(-50%)",
        width: 248,
        height: 37,
        borderRadius: 24,
        background: "#000",
        zIndex: 70,
        overflow: "hidden",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        paddingLeft: 16,
        paddingRight: 12,
        pointerEvents: "none",
        animation: "scale-in 360ms cubic-bezier(.2,.8,.2,1)",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span
          style={{
            width: 8,
            height: 8,
            borderRadius: 999,
            background: "#E36B4A",
            animation: "pulse-dot 1.2s ease-in-out infinite",
          }}
        />
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontSize: 11,
            fontWeight: 500,
            letterSpacing: "1px",
            color: "#F5EDE3",
            fontVariantNumeric: "tabular-nums",
          }}
        >
          {formatClock(elapsed)}
        </span>
      </div>
      <div style={{ display: "flex", alignItems: "center", height: 18 }}>
        <Waveform bars={bars} color="#F5EDE3" gap={1.5} width={1.6} height={18} />
      </div>
    </div>
  );
}
