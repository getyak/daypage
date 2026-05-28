"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Camera, Image, MapPin, Paperclip } from "lucide-react";

interface AttachSheetProps {
  isOpen: boolean;
  onClose: () => void;
}

const BUTTONS = [
  { icon: Camera, label: "拍照", id: "camera" },
  { icon: Image, label: "相册", id: "album" },
  { icon: MapPin, label: "位置", id: "location" },
  { icon: Paperclip, label: "附件", id: "file" },
] as const;

export function AttachSheet({ isOpen, onClose }: AttachSheetProps) {
  const cameraInputRef = useRef<HTMLInputElement>(null);
  const albumInputRef = useRef<HTMLInputElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const sheetRef = useRef<HTMLDivElement>(null);
  const handleRef = useRef<HTMLDivElement>(null);

  // Swipe-to-close
  const dragStartY = useRef<number | null>(null);
  const [dragOffset, setDragOffset] = useState(0);

  const handlePointerDown = useCallback((e: React.PointerEvent) => {
    dragStartY.current = e.clientY;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }, []);

  const handlePointerMove = useCallback((e: React.PointerEvent) => {
    if (dragStartY.current === null) return;
    const delta = e.clientY - dragStartY.current;
    if (delta > 0) setDragOffset(delta);
  }, []);

  const handlePointerUp = useCallback(() => {
    if (dragOffset >= 80) {
      onClose();
    }
    dragStartY.current = null;
    setDragOffset(0);
  }, [dragOffset, onClose]);

  const handleButtonClick = useCallback((id: (typeof BUTTONS)[number]["id"]) => {
    if (id === "camera") {
      cameraInputRef.current?.click();
    } else if (id === "album") {
      albumInputRef.current?.click();
    } else if (id === "location") {
      if (typeof navigator !== "undefined" && navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
          (pos) => {
            console.log("Location:", pos.coords.latitude, pos.coords.longitude);
          },
          (err) => {
            console.warn("Geolocation error:", err.message);
          },
          { enableHighAccuracy: true, timeout: 6000 }
        );
      }
    } else if (id === "file") {
      fileInputRef.current?.click();
    }
  }, []);

  // ESC to close + focus trap
  useEffect(() => {
    if (!isOpen) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  const sheetTransform = dragOffset > 0
    ? `translateY(${dragOffset * 0.6}px)`
    : undefined;
  const sheetOpacity = dragOffset > 0
    ? Math.max(0, 1 - dragOffset / 200)
    : undefined;

  return (
    <>
      <style>{`
        @keyframes attach-fade-in {
          from { opacity: 0 }
          to { opacity: 1 }
        }
        @keyframes sheet-up {
          from { transform: translateY(100%); opacity: 0 }
          to { transform: translateY(0); opacity: 1 }
        }
      `}</style>

      {/* Backdrop */}
      <div
        aria-hidden="true"
        onClick={onClose}
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(30,24,18,0.32)",
          backdropFilter: "blur(2px)",
          WebkitBackdropFilter: "blur(2px)",
          zIndex: 60,
          animation: "attach-fade-in 200ms ease-out both",
        }}
      />

      {/* Sheet panel */}
      <div
        ref={sheetRef}
        role="dialog"
        aria-modal="true"
        aria-label="添加附件"
        style={{
          position: "fixed",
          left: 14,
          right: 14,
          bottom: 110,
          zIndex: 65,
          borderRadius: 28,
          padding: "20px 18px 22px",
          background: "rgba(255,253,250,0.92)",
          backdropFilter: "blur(28px) saturate(160%)",
          WebkitBackdropFilter: "blur(28px) saturate(160%)",
          border: "0.5px solid rgba(214,206,192,0.5)",
          boxShadow: "var(--shadow-attach)",
          animation: dragOffset === 0 ? "sheet-up 280ms cubic-bezier(.2,.8,.2,1) both" : undefined,
          transform: sheetTransform,
          opacity: sheetOpacity,
          transition: dragOffset === 0 ? "transform 220ms cubic-bezier(.2,.8,.2,1), opacity 220ms ease-out" : undefined,
        }}
      >
        {/* Drag handle */}
        <div
          ref={handleRef}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerCancel={handlePointerUp}
          style={{
            display: "flex",
            justifyContent: "center",
            paddingBottom: 18,
            cursor: "grab",
            touchAction: "none",
            userSelect: "none",
          }}
        >
          <div
            style={{
              width: 36,
              height: 4,
              borderRadius: 2,
              background: "#D6CEC0",
            }}
          />
        </div>

        {/* 4 buttons */}
        <div
          style={{
            display: "flex",
            gap: 16,
            justifyContent: "center",
          }}
        >
          {BUTTONS.map(({ icon: Icon, label, id }) => (
            <div
              key={id}
              style={{
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                gap: 8,
              }}
            >
              <button
                aria-label={label}
                onClick={() => handleButtonClick(id)}
                style={{
                  width: 56,
                  height: 56,
                  borderRadius: 18,
                  border: "0.5px solid var(--border-subtle)",
                  background: "var(--surface-sunken)",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  cursor: "pointer",
                  color: "var(--fg-muted)",
                  transition: "background 140ms, color 140ms",
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.background = "var(--accent-soft)";
                  e.currentTarget.style.color = "var(--accent)";
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.background = "var(--surface-sunken)";
                  e.currentTarget.style.color = "var(--fg-muted)";
                }}
              >
                <Icon size={22} strokeWidth={1.6} aria-hidden="true" />
              </button>
              <span
                style={{
                  fontSize: 12,
                  color: "var(--fg-muted)",
                  textAlign: "center",
                  fontFamily: "var(--font-body)",
                }}
              >
                {label}
              </span>
            </div>
          ))}
        </div>
      </div>

      {/* Hidden file inputs */}
      <input
        ref={cameraInputRef}
        type="file"
        accept="image/*"
        capture="environment"
        hidden
        onChange={() => {}}
      />
      <input
        ref={albumInputRef}
        type="file"
        accept="image/*"
        hidden
        onChange={() => {}}
      />
      <input
        ref={fileInputRef}
        type="file"
        hidden
        onChange={() => {}}
      />
    </>
  );
}
