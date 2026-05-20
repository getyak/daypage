"use client";

import { useEffect, useRef } from "react";
import { X } from "lucide-react";

interface DialogProps {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: React.ReactNode;
}

export function Dialog({ open, onClose, title, children }: DialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 1000,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "rgba(0,0,0,0.45)",
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={title ? "dialog-title" : undefined}
        style={{
          position: "relative",
          background: "var(--surface-1, #fff)",
          borderRadius: "var(--radius-md, 12px)",
          boxShadow: "0 8px 32px rgba(0,0,0,0.18)",
          padding: "1.5rem",
          width: "min(480px, calc(100vw - 2rem))",
          maxHeight: "calc(100vh - 4rem)",
          overflowY: "auto",
        }}
      >
        {/* Header */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            marginBottom: title ? "1rem" : 0,
          }}
        >
          {title && (
            <h2
              id="dialog-title"
              style={{
                margin: 0,
                fontSize: "1rem",
                fontWeight: 600,
                color: "var(--fg-primary)",
              }}
            >
              {title}
            </h2>
          )}
          <button
            type="button"
            onClick={onClose}
            aria-label="Close dialog"
            style={{
              marginLeft: "auto",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              background: "none",
              border: "none",
              cursor: "pointer",
              padding: "0.25rem",
              borderRadius: "var(--radius-sm, 4px)",
              color: "var(--fg-subtle)",
            }}
          >
            <X size={16} />
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
