import { type ReactNode } from "react";

type ChipTone = "default" | "accent" | "success" | "warning" | "error" | "ghost";

interface ChipProps {
  tone?: ChipTone;
  onClick?: () => void;
  children: ReactNode;
  className?: string;
}

export function Chip({
  tone = "default",
  onClick,
  children,
  className = "",
}: ChipProps) {
  const cls = ["chip", `chip--${tone}`, onClick ? "chip--interactive" : "", className]
    .filter(Boolean)
    .join(" ");

  if (onClick) {
    return (
      <button type="button" className={cls} onClick={onClick}>
        {children}
      </button>
    );
  }
  return <span className={cls}>{children}</span>;
}
