"use client";

import { useEffect, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";

const DESKTOP_QUERY = "(min-width: 1024px)";

/**
 * US-050 — /today is the *mobile* capture/browse flow. On desktop (≥1024px)
 * the web app is a knowledge workstation: capture is unified under /add, so
 * the mobile flow (full-bleed toolbar, 280pt slide-in drawer, fixed
 * ComposerPill) must not render — it collides with the desktop sidebar shell.
 *
 * This guard:
 *  - renders nothing and redirects desktop viewports to /add, so the
 *    misaligned mobile layout is never painted on desktop;
 *  - renders the mobile flow as-is below the breakpoint.
 *
 * SSR renders nothing (matched === null) to avoid a hydration flash of the
 * mobile layout on desktop; the real decision is made after mount, where
 * window.matchMedia is available.
 */
export function MobileOnlyGuard({ children }: { children: ReactNode }) {
  const router = useRouter();
  const [isMobile, setIsMobile] = useState<boolean | null>(null);

  useEffect(() => {
    const mql = window.matchMedia(DESKTOP_QUERY);

    const apply = (isDesktop: boolean) => {
      if (isDesktop) {
        // Desktop capture is unified under /add.
        router.replace("/add");
      } else {
        setIsMobile(true);
      }
    };

    apply(mql.matches);
    const onChange = (e: MediaQueryListEvent) => apply(e.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, [router]);

  if (!isMobile) return null;
  return <>{children}</>;
}
