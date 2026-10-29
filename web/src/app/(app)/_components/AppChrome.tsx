"use client";

import type { ReactNode } from "react";
import { usePathname } from "next/navigation";
import "./app-chrome.css";

/** Route state controls presentation only; auth and data remain server owned. */
export function AppChrome({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const capture = pathname === "/add" || pathname === "/today";
  return (
    <div className="app-shell flex min-h-screen" data-capture={capture}>
      {children}
    </div>
  );
}
