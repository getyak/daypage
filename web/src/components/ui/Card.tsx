import { type ReactNode } from "react";

interface CardProps {
  sunken?: boolean;
  children: ReactNode;
  className?: string;
}

export function Card({ sunken = false, children, className = "" }: CardProps) {
  const cls = ["card", sunken ? "card--sunken" : "", className]
    .filter(Boolean)
    .join(" ");

  return <div className={cls}>{children}</div>;
}
