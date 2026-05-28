import { type ReactNode } from "react";

interface SectionLabelProps {
  children: ReactNode;
  className?: string;
  // Optional right-side slot (e.g. a Chip or Btn). When provided, the label
  // renders as a flex row with the label on the left and `right` on the right.
  right?: ReactNode;
}

const labelStyle: React.CSSProperties = {
  fontSize: 11,
  letterSpacing: "1.6px",
  textTransform: "uppercase",
  fontWeight: 700,
  color: "var(--fg-muted)",
  fontFamily: "var(--font-family-display, 'Space Grotesk'), ui-sans-serif, sans-serif",
  lineHeight: 1.2,
  margin: 0,
};

export function SectionLabel({ children, className = "", right }: SectionLabelProps) {
  if (right === undefined) {
    return (
      <h2
        role="heading"
        aria-level={2}
        className={className || undefined}
        style={labelStyle}
      >
        {children}
      </h2>
    );
  }
  return (
    <div
      className={className || undefined}
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        marginBottom: 12,
      }}
    >
      <h2 role="heading" aria-level={2} style={labelStyle}>
        {children}
      </h2>
      <span style={{ display: "inline-flex", alignItems: "center" }}>{right}</span>
    </div>
  );
}
