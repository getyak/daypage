import { type ReactNode } from "react";

interface SectionLabelProps {
  children: ReactNode;
  className?: string;
}

export function SectionLabel({ children, className = "" }: SectionLabelProps) {
  return (
    <p className={["ds-section-label", className].filter(Boolean).join(" ")}>
      {children}
    </p>
  );
}
