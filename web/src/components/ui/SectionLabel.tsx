import { type ReactNode } from "react";

interface SectionLabelProps {
  children: ReactNode;
  className?: string;
  // Optional right-side slot (e.g. a Chip or Btn). When provided, the label
  // renders as a flex row with the label on the left and `right` on the right.
  right?: ReactNode;
}

export function SectionLabel({ children, className = "", right }: SectionLabelProps) {
  if (right === undefined) {
    return (
      <p className={["ds-section-label", className].filter(Boolean).join(" ")}>
        {children}
      </p>
    );
  }
  return (
    <div
      className={["section-label-row", className].filter(Boolean).join(" ")}
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        marginBottom: 12,
      }}
    >
      <span className="ds-section-label">{children}</span>
      <span style={{ display: "inline-flex", alignItems: "center" }}>{right}</span>
    </div>
  );
}
