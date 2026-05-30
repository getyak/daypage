interface WaveformProps {
  /** Bar heights, typically produced by `useWaveform`. */
  bars: number[];
  /** Bar fill color (any CSS color / var). */
  color?: string;
  /** Horizontal gap between bars, px. */
  gap?: number;
  /** Bar width, px. */
  width?: number;
  /** Container height, px. */
  height?: number;
  /** When false, bars render 1.2× taller (asymmetric, non-mirrored look). */
  mirror?: boolean;
  /** Container opacity. */
  opacity?: number;
}

/**
 * Waveform — a pure presentational strip of vertical bars.
 *
 * Ported from .design-handoff/v8/composer.jsx:34-46. Maps a `bars` array
 * (see `useWaveform`) to a flex row of rounded divs whose individual height and
 * opacity scale with the sample value. No state, no effects — render-only.
 *
 * Shared by <RecordingSheet> and the Dynamic Island live activity.
 */
export function Waveform({
  bars,
  color = "var(--accent)",
  gap = 2,
  width = 2,
  height = 32,
  mirror = true,
  opacity = 1,
}: WaveformProps) {
  return (
    <div
      aria-hidden="true"
      style={{ display: "flex", alignItems: "center", gap, height, opacity }}
    >
      {bars.map((h, i) => (
        <div
          key={i}
          style={{
            width,
            height: Math.max(width, h * (mirror ? 1 : 1.2)),
            background: color,
            borderRadius: width,
            opacity: 0.55 + 0.45 * (h / 28),
            transition: "height 80ms linear",
          }}
        />
      ))}
    </div>
  );
}
