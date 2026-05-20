"use client";

import { useEffect, useState, type ReactNode } from "react";
import { ChevronsLeft, ChevronsRight } from "lucide-react";

const STORAGE_KEY = "daypage.sidebarCollapsed";
const EXPANDED_W = 248;
const COLLAPSED_W = 60;

/**
 * Desktop sidebar shell with icon-only collapse. The collapsed state is
 * persisted to localStorage and broadcast to CSS via `data-collapsed` on the
 * outer <aside> (rules in globals.css hide labels/meta/etc. when collapsed)
 * and to the layout grid via the `--sb-w` CSS variable on <html>.
 *
 * Server-side renders in expanded state to match the SSR HTML; the effect
 * below applies the persisted preference after hydration to avoid layout
 * thrash on first paint.
 */
export function DesktopSidebarShell({ children }: { children: ReactNode }) {
  const [collapsed, setCollapsed] = useState(false);

  // Read persisted preference once on mount.
  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      // eslint-disable-next-line react-hooks/set-state-in-effect
      if (raw === "true") setCollapsed(true);
    } catch {
      // localStorage may be unavailable (private mode, SSR snapshot mismatch)
    }
  }, []);

  // Publish width to the layout so the main column can react in pure CSS.
  useEffect(() => {
    const w = collapsed ? COLLAPSED_W : EXPANDED_W;
    document.documentElement.style.setProperty("--sb-w", `${w}px`);
  }, [collapsed]);

  function toggle() {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        window.localStorage.setItem(STORAGE_KEY, next ? "true" : "false");
      } catch {
        // ignore
      }
      return next;
    });
  }

  return (
    <aside
      className="sb hidden lg:flex shrink-0"
      data-collapsed={collapsed ? "true" : "false"}
      style={{ width: collapsed ? COLLAPSED_W : EXPANDED_W }}
    >
      {children}
      <button
        type="button"
        onClick={toggle}
        aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
        aria-expanded={!collapsed}
        title={collapsed ? "Expand sidebar" : "Collapse sidebar"}
        className="sb__collapse-btn"
      >
        {collapsed ? (
          <ChevronsRight size={16} strokeWidth={1.7} />
        ) : (
          <ChevronsLeft size={16} strokeWidth={1.7} />
        )}
      </button>
    </aside>
  );
}
