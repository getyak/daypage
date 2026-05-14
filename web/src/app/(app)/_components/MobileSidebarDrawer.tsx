"use client";

import { useState, useEffect, createContext, useContext } from "react";
import { usePathname } from "next/navigation";
import { Menu, X } from "lucide-react";
import type { ReactNode } from "react";

const DrawerCtx = createContext<{ open: () => void } | null>(null);

export function MobileDrawerProvider({
  sidebar,
  children,
}: {
  sidebar: ReactNode;
  children: ReactNode;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const pathname = usePathname();

  useEffect(() => {
    setIsOpen(false);
  }, [pathname]);

  useEffect(() => {
    if (!isOpen) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setIsOpen(false);
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [isOpen]);

  return (
    <DrawerCtx.Provider value={{ open: () => setIsOpen(true) }}>
      {/* Backdrop — mobile/tablet only; desktop already has a permanent sidebar */}
      {isOpen && (
        <div
          onClick={() => setIsOpen(false)}
          aria-hidden="true"
          className="lg:hidden"
          style={{
            position: "fixed",
            inset: 0,
            zIndex: 199,
            background: "rgba(0,0,0,0.4)",
          }}
        />
      )}

      {/* Drawer panel — mobile/tablet only; hidden entirely on lg+ */}
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Navigation menu"
        aria-hidden={!isOpen}
        className="lg:hidden"
        style={{
          position: "fixed",
          top: 0,
          left: 0,
          bottom: 0,
          zIndex: 200,
          width: 280,
          maxWidth: "calc(100vw - 48px)",
          transform: isOpen ? "translateX(0)" : "translateX(-100%)",
          transition: "transform 220ms cubic-bezier(0.25, 0.46, 0.45, 0.94)",
          willChange: "transform",
          visibility: isOpen ? "visible" : "hidden",
        }}
      >
        {/* Close button */}
        <button
          type="button"
          onClick={() => setIsOpen(false)}
          aria-label="Close navigation menu"
          style={{
            position: "absolute",
            top: 14,
            right: 14,
            zIndex: 1,
            display: "inline-flex",
            alignItems: "center",
            justifyContent: "center",
            width: 32,
            height: 32,
            border: "none",
            background: "transparent",
            cursor: "pointer",
            color: "var(--fg-muted)",
          }}
        >
          <X size={18} strokeWidth={1.7} />
        </button>

        <aside
          className="sb"
          style={{ width: "100%", height: "100%", display: "flex" }}
        >
          {sidebar}
        </aside>
      </div>

      {children}
    </DrawerCtx.Provider>
  );
}

export function HamburgerButton() {
  const ctx = useContext(DrawerCtx);

  return (
    <button
      type="button"
      onClick={() => ctx?.open()}
      aria-label="Open navigation menu"
      className="lg:hidden"
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: 36,
        height: 36,
        border: "1px solid var(--accent-border)",
        borderRadius: "var(--radius-small)",
        background: "transparent",
        cursor: "pointer",
        color: "var(--fg-primary)",
        flexShrink: 0,
        marginRight: "0.25rem",
      }}
    >
      <Menu size={18} strokeWidth={1.7} />
    </button>
  );
}

// Re-export under the name layout.tsx expects.
export { MobileDrawerProvider as MobileSidebarDrawer };
