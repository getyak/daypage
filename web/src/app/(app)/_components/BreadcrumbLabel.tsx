"use client";

import { usePathname } from "next/navigation";

const NAV_LABELS: Array<{ href: string; label: string }> = [
  { href: "/home", label: "Home" },
  { href: "/add", label: "Add" },
  { href: "/agents", label: "Agents" },
  { href: "/chat", label: "Chat" },
  { href: "/wiki", label: "Wiki" },
  { href: "/inbox", label: "Inbox" },
  { href: "/insights", label: "Insights" },
  { href: "/settings", label: "Settings" },
];

function deriveLabel(pathname: string): string {
  for (const { href, label } of NAV_LABELS) {
    if (pathname.startsWith(href)) return label;
  }
  return "Home";
}

export function BreadcrumbLabel() {
  const pathname = usePathname();
  return (
    <span style={{ fontSize: "0.875rem", fontWeight: 500, color: "var(--fg-primary)" }}>
      {deriveLabel(pathname)}
    </span>
  );
}
