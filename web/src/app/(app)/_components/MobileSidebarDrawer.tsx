"use client";

import {
  useCallback,
  useState,
  useEffect,
  createContext,
  useContext,
  useRef,
} from "react";
import { usePathname } from "next/navigation";
import { Menu, X } from "lucide-react";
import type { ReactNode } from "react";

const DrawerCtx = createContext<{ open: (trigger: HTMLButtonElement) => void } | null>(null);

export function MobileDrawerProvider({
  sidebar,
  children,
}: {
  sidebar: ReactNode;
  children: ReactNode;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const pathname = usePathname();
  const panelRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLButtonElement | null>(null);

  const close = useCallback((restoreFocus = true) => {
    setIsOpen(false);
    if (restoreFocus) {
      window.requestAnimationFrame(() => returnFocusRef.current?.focus());
    }
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setIsOpen(false);
  }, [pathname]);

  useEffect(() => {
    if (!isOpen) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.requestAnimationFrame(() => closeButtonRef.current?.focus());

    function onKey(e: KeyboardEvent) {
      // A portalled child dialog owns its own keys and focus boundary.
      if (e.target instanceof Node && !panelRef.current?.contains(e.target)) return;
      if (e.key === "Escape") {
        e.preventDefault();
        close();
        return;
      }

      if (e.key !== "Tab") return;
      const focusable = panelRef.current?.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])'
      );
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previousOverflow;
    };
  }, [close, isOpen]);

  return (
    <DrawerCtx.Provider
      value={{
        open: (trigger) => {
          returnFocusRef.current = trigger;
          setIsOpen(true);
        },
      }}
    >
      {/* Backdrop — mobile/tablet only; desktop already has a permanent sidebar */}
      {isOpen && (
        <div
          onClick={() => close()}
          aria-hidden="true"
          className="mobile-drawer-backdrop lg:hidden"
        />
      )}

      {/* Drawer panel — mobile/tablet only; hidden entirely on lg+ */}
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label="Navigation menu"
        aria-hidden={!isOpen}
        inert={!isOpen}
        className={`mobile-drawer lg:hidden${isOpen ? " is-open" : ""}`}
      >
        {/* Close button */}
        <button
          ref={closeButtonRef}
          type="button"
          onClick={() => close()}
          aria-label="Close navigation menu"
          className="mobile-drawer__close"
        >
          <X size={18} strokeWidth={1.7} />
        </button>

        <aside className="sb">
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
      onClick={(event) => ctx?.open(event.currentTarget)}
      aria-label="Open navigation menu"
      className="mobile-menu-trigger lg:hidden"
    >
      <Menu size={18} strokeWidth={1.7} />
    </button>
  );
}

// Re-export under the name layout.tsx expects.
export { MobileDrawerProvider as MobileSidebarDrawer };
