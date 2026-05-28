"use client";

import { useEffect, useRef, type ReactNode } from "react";

interface DrawerProps {
  isOpen: boolean;
  onClose: () => void;
  children: ReactNode;
}

const FOCUSABLE =
  'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';

export function Drawer({ isOpen, onClose, children }: DrawerProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  // Body overflow lock
  useEffect(() => {
    if (isOpen) {
      document.body.style.overflow = "hidden";
    } else {
      document.body.style.overflow = "";
    }
    return () => {
      document.body.style.overflow = "";
    };
  }, [isOpen]);

  // ESC key
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [isOpen, onClose]);

  // Focus trap
  useEffect(() => {
    if (!isOpen) return;
    const panel = panelRef.current;
    if (!panel) return;

    // Focus first focusable element
    const focusables = panel.querySelectorAll<HTMLElement>(FOCUSABLE);
    if (focusables.length > 0) focusables[0].focus();

    const trap = (e: KeyboardEvent) => {
      if (e.key !== "Tab") return;
      const els = panel.querySelectorAll<HTMLElement>(FOCUSABLE);
      if (els.length === 0) return;
      const first = els[0];
      const last = els[els.length - 1];
      if (e.shiftKey) {
        if (document.activeElement === first) {
          e.preventDefault();
          last.focus();
        }
      } else {
        if (document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", trap);
    return () => document.removeEventListener("keydown", trap);
  }, [isOpen]);

  if (!isOpen) return null;

  return (
    <>
      {/* Backdrop */}
      <div
        onClick={onClose}
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(20,16,12,0.32)",
          backdropFilter: "blur(2px)",
          WebkitBackdropFilter: "blur(2px)",
          zIndex: 80,
          animation: "fade-in 220ms ease-out both",
        }}
        aria-hidden="true"
      />

      {/* Panel */}
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="drawer-title"
        style={{
          position: "fixed",
          top: 0,
          left: 0,
          bottom: 0,
          width: "86%",
          maxWidth: 360,
          zIndex: 85,
          background: "rgba(252,250,247,0.96)",
          backdropFilter: "blur(28px) saturate(160%)",
          WebkitBackdropFilter: "blur(28px) saturate(160%)",
          borderRight: "0.5px solid var(--border-subtle)",
          boxShadow: "10px 0 40px -12px rgba(60,40,15,0.22)",
          display: "flex",
          flexDirection: "column",
          overflowY: "auto",
          animation: "slide-in-left 280ms cubic-bezier(.2,.8,.2,1) both",
        }}
      >
        {children}
      </div>
    </>
  );
}
