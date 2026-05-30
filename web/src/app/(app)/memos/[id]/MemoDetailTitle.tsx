"use client";

interface Props {
  place?: string | null;
  kind: string;
  location?: string | null;
}

const KIND_LABELS: Record<string, string> = {
  text: "TEXT",
  voice: "VOICE",
  photo: "PHOTO",
  mixed: "MIXED",
};

export function MemoDetailTitle({ place, kind, location }: Props) {
  const kindLabel = KIND_LABELS[kind] ?? kind.toUpperCase();
  const subtitle = [kindLabel, location?.toUpperCase()].filter(Boolean).join(" · ");
  const isLong = (place?.length ?? 0) > 30;

  return (
    <div style={{ padding: "22px 22px 16px" }}>
      {place ? (
        <h1
          style={{
            fontFamily: "var(--font-serif, Georgia, serif)",
            fontSize: isLong ? 26 : 34,
            lineHeight: isLong ? 1.2 : 1.05,
            letterSpacing: "-0.7px",
            fontWeight: 600,
            margin: "0 0 8px",
            color: "var(--fg-primary)",
            ...(isLong
              ? { textOverflow: "ellipsis", whiteSpace: "nowrap", overflow: "hidden" }
              : {}),
          }}
        >
          {place}
        </h1>
      ) : (
        <h1
          style={{
            fontFamily: "var(--font-serif, Georgia, serif)",
            fontSize: 30,
            lineHeight: 1.15,
            letterSpacing: "-0.7px",
            fontWeight: 600,
            fontStyle: "italic",
            margin: "0 0 8px",
            color: "var(--fg-muted)",
          }}
        >
          未命名片刻
        </h1>
      )}
      {subtitle && (
        <p
          style={{
            fontFamily: "var(--font-mono)",
            fontSize: 10,
            letterSpacing: "1.4px",
            fontWeight: 600,
            color: "var(--fg-subtle)",
            margin: 0,
            textTransform: "uppercase",
          }}
        >
          {subtitle}
        </p>
      )}
    </div>
  );
}
