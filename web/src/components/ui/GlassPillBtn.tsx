import { type ButtonHTMLAttributes, type ReactNode } from "react";

interface GlassPillBtnProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  dark?: boolean;
  size?: "sm" | "md";
  "aria-label": string;
  children?: ReactNode;
}

export function GlassPillBtn({
  dark = false,
  size = "md",
  children,
  className = "",
  disabled,
  onClick,
  ...rest
}: GlassPillBtnProps) {
  const isSm = size === "sm";

  return (
    <button
      type="button"
      className={[
        "glass-pill-btn",
        isSm ? "glass-pill-btn--sm" : "glass-pill-btn--md",
        dark ? "glass-pill-btn--dark" : "",
        className,
      ]
        .filter(Boolean)
        .join(" ")}
      disabled={disabled}
      onClick={disabled ? undefined : onClick}
      {...rest}
    >
      {children}
    </button>
  );
}
