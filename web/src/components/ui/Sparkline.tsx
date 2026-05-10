interface SparklineProps {
  values: number[];
  w?: number;
  h?: number;
  color?: string;
  fill?: boolean;
}

export function Sparkline({
  values,
  w = 80,
  h = 24,
  color = "var(--accent)",
  fill = false,
}: SparklineProps) {
  if (values.length < 2) return null;

  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;

  const pad = 1;
  const usableW = w - pad * 2;
  const usableH = h - pad * 2;

  const points = values.map((v, i) => {
    const x = pad + (i / (values.length - 1)) * usableW;
    const y = pad + (1 - (v - min) / range) * usableH;
    return `${x},${y}`;
  });

  const polyline = points.join(" ");

  if (fill) {
    const firstX = pad;
    const lastX = pad + usableW;
    const bottom = pad + usableH;
    const area = `${firstX},${bottom} ${polyline} ${lastX},${bottom}`;
    return (
      <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true">
        <polygon points={area} fill={color} fillOpacity={0.15} />
        <polyline points={polyline} fill="none" stroke={color} strokeWidth={1.5} strokeLinejoin="round" strokeLinecap="round" />
      </svg>
    );
  }

  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true">
      <polyline points={polyline} fill="none" stroke={color} strokeWidth={1.5} strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}
