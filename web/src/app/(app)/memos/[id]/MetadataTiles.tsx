"use client";

interface Props {
  weather?: string | null;
  humidity?: string | null;
  kind: string;
  createdAt: string; // ISO string
}

const KIND_ZH: Record<string, string> = {
  text: "文本",
  voice: "语音",
  photo: "照片",
  mixed: "混合",
};

function getLightPeriod(isoString: string): string {
  const h = new Date(isoString).getHours();
  if (h >= 5 && h < 9) return "黎明";
  if (h >= 9 && h < 12) return "上午";
  if (h >= 12 && h < 14) return "正午";
  if (h >= 14 && h < 17) return "下午";
  if (h >= 17 && h < 19) return "傍晚";
  return "夜晚";
}

function getLightCode(isoString: string): string {
  const h = new Date(isoString).getHours();
  if (h >= 5 && h < 9) return "DAWN";
  if (h >= 9 && h < 12) return "MORNING";
  if (h >= 12 && h < 14) return "NOON";
  if (h >= 14 && h < 17) return "AFTERNOON";
  if (h >= 17 && h < 19) return "EVENING";
  return "NIGHT";
}

const DASH = "—";

const labelStyle: React.CSSProperties = {
  fontFamily: "var(--font-mono)",
  fontSize: 8.5,
  fontWeight: 700,
  letterSpacing: "1.4px",
  textTransform: "uppercase",
  color: "var(--fg-subtle)",
  marginBottom: 4,
};

const valueStyle: React.CSSProperties = {
  fontSize: 18,
  fontWeight: 600,
  color: "var(--fg-primary)",
  lineHeight: 1.1,
  marginBottom: 3,
};

const subStyle: React.CSSProperties = {
  fontFamily: "var(--font-mono)",
  fontSize: 8,
  fontWeight: 600,
  letterSpacing: "1.2px",
  textTransform: "uppercase",
  color: "var(--fg-subtle)",
};

interface TileProps {
  label: string;
  value: string;
  sub: string;
  first?: boolean;
}

function Tile({ label, value, sub, first }: TileProps) {
  return (
    <div
      role="group"
      style={{
        padding: "12px 8px 11px",
        textAlign: "center",
        borderLeft: first ? "none" : "0.5px solid var(--border-subtle)",
      }}
    >
      <dt style={labelStyle}>{label}</dt>
      <dd
        style={{
          ...valueStyle,
          color: value === DASH ? "var(--fg-subtle)" : "var(--fg-primary)",
          margin: 0,
        }}
      >
        {value}
      </dd>
      <dd style={{ ...subStyle, margin: 0 }}>{value === DASH ? "" : sub}</dd>
    </div>
  );
}

export function MetadataTiles({ weather, humidity, kind, createdAt }: Props) {
  const lightPeriod = getLightPeriod(createdAt);
  const lightCode = getLightCode(createdAt);
  const kindZh = KIND_ZH[kind] ?? kind;

  // Extract weather display value — could be a string like "晴" or a JSON object
  let weatherDisplay = DASH;
  let weatherSub = "CONDITION";
  if (weather) {
    weatherDisplay = weather;
    weatherSub = "WEATHER";
  }

  return (
    <div style={{ padding: "0 14px 20px" }}>
      <dl
        style={{
          display: "grid",
          gridTemplateColumns: "1.05fr 1fr 1fr 0.85fr",
          borderRadius: 14,
          overflow: "hidden",
          background: "var(--surface-white)",
          border: "0.5px solid var(--border-default)",
          boxShadow: "var(--shadow-card)",
          margin: 0,
        }}
      >
        <Tile first label="WEATHER" value={weatherDisplay} sub={weatherSub} />
        <Tile label="HUMIDITY" value={humidity ?? DASH} sub="PERCENT" />
        <Tile label="LIGHT" value={lightPeriod} sub={lightCode} />
        <Tile label="KIND" value={kindZh} sub={kind.toUpperCase()} />
      </dl>
    </div>
  );
}
