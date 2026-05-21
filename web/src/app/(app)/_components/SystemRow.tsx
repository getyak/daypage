"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Settings, User, LogOut } from "lucide-react";

const ICONS = {
  settings: Settings,
  user: User,
  logout: LogOut,
} as const;

type SystemIconName = keyof typeof ICONS;

export function SystemRow({
  iconName,
  label,
  meta,
  disabled = false,
  title,
  as = "div",
  href,
}: {
  iconName: SystemIconName;
  label: string;
  meta?: string;
  disabled?: boolean;
  title?: string;
  as?: "div" | "button";
  href?: string;
}) {
  const Icon = ICONS[iconName];
  const pathname = usePathname();
  const isActive = href ? pathname === href || pathname.startsWith(`${href}/`) : false;

  const inner = (
    <>
      <span className="sb__item-icon">
        <Icon size={18} strokeWidth={1.7} />
      </span>
      <span className="sb__item-label">{label}</span>
      {meta ? <span className="sb__item-meta">{meta}</span> : null}
    </>
  );

  if (as === "button") {
    return (
      <button
        type="submit"
        className="sb__item"
        style={{
          width: "100%",
          background: "transparent",
          border: "none",
          textAlign: "left",
          font: "inherit",
        }}
      >
        {inner}
      </button>
    );
  }

  if (href && !disabled) {
    return (
      <Link
        href={href}
        className={`sb__item${isActive ? " is-active" : ""}`}
        title={title}
        aria-current={isActive ? "page" : undefined}
      >
        {inner}
      </Link>
    );
  }

  return (
    <div
      className="sb__item"
      style={{
        cursor: disabled ? "default" : undefined,
        opacity: disabled ? 0.5 : undefined,
      }}
      title={title}
    >
      {inner}
    </div>
  );
}
