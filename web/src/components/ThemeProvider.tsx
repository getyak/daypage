"use client";

import { useEffect } from "react";

// Reads the theme preference from localStorage and applies data-theme to <html>.
// Must run before first paint — the script in layout.tsx handles SSR flash prevention.
export function ThemeProvider() {
  useEffect(() => {
    const apply = () => {
      try {
        const raw = localStorage.getItem("codex.settings.v1");
        const parsed = raw ? (JSON.parse(raw) as { theme?: string }) : {};
        const theme = parsed.theme ?? "system";
        document.documentElement.setAttribute("data-theme", theme);
      } catch {
        document.documentElement.setAttribute("data-theme", "system");
      }
    };

    apply();

    const handler = (e: StorageEvent) => {
      if (e.key === "codex.settings.v1") apply();
    };
    window.addEventListener("storage", handler);
    return () => window.removeEventListener("storage", handler);
  }, []);

  return null;
}
