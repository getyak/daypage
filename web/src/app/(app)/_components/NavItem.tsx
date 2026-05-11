"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  Home,
  Plus,
  MessageSquare,
  BookOpen,
  Inbox,
  Settings,
  User,
  LogOut,
} from "lucide-react";
import type { ReactNode } from "react";

// Icon id → lucide component. The map lives in the client component so that
// the server layout only needs to pass a plain string across the RSC boundary
// (React 19 / Next 16 disallow passing function components as props to
// client components).
const ICONS = {
  home: Home,
  plus: Plus,
  message: MessageSquare,
  book: BookOpen,
  inbox: Inbox,
  settings: Settings,
  user: User,
  logout: LogOut,
} as const;

export type NavIconName = keyof typeof ICONS;

export function NavItem({
  href,
  iconName,
  label,
  badge,
  meta,
}: {
  href: string;
  iconName: NavIconName;
  label: string;
  badge?: number;
  meta?: string;
}) {
  const pathname = usePathname();
  const active = pathname === href || (href !== "/" && pathname.startsWith(href));
  const Icon = ICONS[iconName];

  return (
    <Link href={href} className={"sb__item" + (active ? " is-active" : "")}>
      <span className="sb__item-icon">
        <Icon size={18} strokeWidth={1.7} />
      </span>
      <span className="sb__item-label">{label}</span>
      {badge !== undefined ? (
        <span className="sb__item-badge">{badge > 99 ? "99+" : badge}</span>
      ) : meta ? (
        <span className="sb__item-meta">{meta}</span>
      ) : null}
    </Link>
  );
}

export function NavItemLink({
  href,
  children,
}: {
  href: string;
  children: ReactNode;
}) {
  const pathname = usePathname();
  const active = pathname === href || (href !== "/" && pathname.startsWith(href));

  return (
    <Link href={href} className={"sb__domain" + (active ? " is-active" : "")}>
      {children}
    </Link>
  );
}
