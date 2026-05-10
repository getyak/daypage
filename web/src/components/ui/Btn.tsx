import { type ButtonHTMLAttributes, type ReactNode } from "react";

type BtnKind = "primary" | "secondary" | "soft" | "ghost";
type BtnSize = "sm" | "md";

interface BtnProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  kind?: BtnKind;
  size?: BtnSize;
  pill?: boolean;
  icon?: ReactNode;
  iconRight?: ReactNode;
  children?: ReactNode;
}

export function Btn({
  kind = "primary",
  size = "md",
  pill = false,
  icon,
  iconRight,
  children,
  className = "",
  ...rest
}: BtnProps) {
  const base = "btn";
  const kindCls = `btn--${kind}`;
  const sizeCls = `btn--${size}`;
  const pillCls = pill ? "btn--pill" : "";

  return (
    <button
      className={[base, kindCls, sizeCls, pillCls, className]
        .filter(Boolean)
        .join(" ")}
      {...rest}
    >
      {icon && <span className="btn__icon">{icon}</span>}
      {children}
      {iconRight && <span className="btn__icon btn__icon--right">{iconRight}</span>}
    </button>
  );
}
