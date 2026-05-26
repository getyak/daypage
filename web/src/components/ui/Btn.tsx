import { type ButtonHTMLAttributes, type ReactNode } from "react";

type BtnKind = "primary" | "secondary" | "soft" | "ghost";
type BtnSize = "sm" | "md";

interface BtnProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  kind?: BtnKind;
  size?: BtnSize;
  pill?: boolean;
  loading?: boolean;
  icon?: ReactNode;
  iconRight?: ReactNode;
  children?: ReactNode;
}

function Spinner() {
  return (
    <svg
      className="btn__spinner"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 16 16"
      aria-hidden="true"
    >
      <circle
        cx="8"
        cy="8"
        r="6"
        stroke="currentColor"
        strokeOpacity="0.3"
        strokeWidth="2"
      />
      <path
        d="M14 8a6 6 0 0 0-6-6"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  );
}

export function Btn({
  kind = "primary",
  size = "md",
  pill = false,
  loading = false,
  icon,
  iconRight,
  children,
  className = "",
  disabled,
  onClick,
  ...rest
}: BtnProps) {
  const base = "btn";
  const kindCls = `btn--${kind}`;
  const sizeCls = `btn--${size}`;
  const pillCls = pill ? "btn--pill" : "";

  const isDisabled = disabled || loading;

  return (
    <button
      className={[base, kindCls, sizeCls, pillCls, className]
        .filter(Boolean)
        .join(" ")}
      disabled={isDisabled}
      aria-busy={loading ? "true" : undefined}
      onClick={loading ? undefined : onClick}
      {...rest}
    >
      {loading ? (
        <Spinner />
      ) : (
        icon && <span className="btn__icon">{icon}</span>
      )}
      {children}
      {iconRight && <span className="btn__icon btn__icon--right">{iconRight}</span>}
    </button>
  );
}
