"use client";

import { useState, useRef, useCallback, useEffect } from "react";
import { Maximize2 } from "lucide-react";

interface Props {
  src: string;
  filename?: string | null;
  width?: number | null;
  height?: number | null;
  alt?: string | null;
}

export function HeroPhoto({ src, filename, width, height, alt }: Props) {
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState(false);
  const [open, setOpen] = useState(false);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const lastTap = useRef(0);

  const openLightbox = useCallback(() => {
    setOpen(true);
    dialogRef.current?.showModal();
  }, []);

  const closeLightbox = useCallback(() => {
    setOpen(false);
    dialogRef.current?.close();
  }, []);

  // ESC is handled natively by <dialog>; sync state back
  useEffect(() => {
    const el = dialogRef.current;
    if (!el) return;
    const handler = () => setOpen(false);
    el.addEventListener("close", handler);
    return () => el.removeEventListener("close", handler);
  }, []);

  function handleDoubleTap() {
    const now = Date.now();
    if (now - lastTap.current < 300) {
      openLightbox();
    }
    lastTap.current = now;
  }

  const caption = [filename, width && height ? `${width}×${height}` : null]
    .filter(Boolean)
    .join(" · ");

  return (
    <div style={{ padding: "0 14px 20px" }}>
      {/* Image wrapper */}
      <div
        style={{
          position: "relative",
          aspectRatio: "4/5",
          borderRadius: 18,
          overflow: "hidden",
          background: loaded ? "transparent" : "var(--surface-sunken)",
          cursor: "pointer",
        }}
        onClick={openLightbox}
        onTouchEnd={handleDoubleTap}
      >
        {!loaded && !error && (
          <div
            style={{
              position: "absolute",
              inset: 0,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <span
              style={{
                width: 20,
                height: 20,
                border: "2px solid var(--border-default)",
                borderTopColor: "var(--accent)",
                borderRadius: "50%",
                animation: "spin 0.6s linear infinite",
                display: "inline-block",
              }}
            />
          </div>
        )}
        {error ? (
          <div
            style={{
              position: "absolute",
              inset: 0,
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: "center",
              gap: 8,
              color: "var(--fg-subtle)",
              fontSize: 13,
            }}
          >
            <span>图片加载失败</span>
            <button
              onClick={(e) => { e.stopPropagation(); setError(false); }}
              style={{
                fontFamily: "var(--font-mono)",
                fontSize: 10,
                letterSpacing: "1px",
                textTransform: "uppercase",
                color: "var(--accent)",
                background: "none",
                border: "none",
                cursor: "pointer",
                padding: 0,
              }}
            >
              重试
            </button>
          </div>
        ) : (
          /* eslint-disable-next-line @next/next/no-img-element */
          <img
            src={src}
            alt={alt ?? "相片"}
            loading="lazy"
            onLoad={() => setLoaded(true)}
            onError={() => setError(true)}
            style={{
              width: "100%",
              height: "100%",
              objectFit: "cover",
              borderRadius: 18,
              opacity: loaded ? 1 : 0,
              animation: loaded ? "heroFadeIn 280ms ease-out forwards" : "none",
            }}
          />
        )}
      </div>

      {/* Caption row */}
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          marginTop: 8,
          padding: "0 2px",
        }}
      >
        <span
          style={{
            fontFamily: "var(--font-mono)",
            fontSize: 9.5,
            letterSpacing: "1.2px",
            fontWeight: 600,
            color: "var(--fg-subtle)",
            textTransform: "lowercase",
          }}
        >
          {caption || "photo"}
        </span>
        <button
          onClick={openLightbox}
          aria-label="展开图片"
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 4,
            background: "none",
            border: "none",
            cursor: "pointer",
            padding: 0,
            color: "var(--accent)",
          }}
        >
          <span
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: 9.5,
              letterSpacing: "1.2px",
              fontWeight: 600,
              textTransform: "uppercase",
            }}
          >
            TAP TO EXPAND
          </span>
          <Maximize2 size={11} />
        </button>
      </div>

      {/* Lightbox */}
      <dialog
        ref={dialogRef}
        onClick={(e) => {
          if (e.target === dialogRef.current) closeLightbox();
        }}
        style={{
          border: "none",
          background: "transparent",
          padding: 0,
          maxWidth: "100vw",
          maxHeight: "100vh",
          width: "100vw",
          height: "100vh",
        }}
      >
        <div
          style={{
            width: "100%",
            height: "100%",
            background: "rgba(0,0,0,0.88)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            animation: open ? "lightboxIn 220ms cubic-bezier(0.22,1,0.36,1) forwards" : "none",
          }}
          onClick={closeLightbox}
        >
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={src}
            alt={alt ?? "相片"}
            onClick={(e) => e.stopPropagation()}
            onTouchEnd={(e) => {
              e.stopPropagation();
              handleDoubleTap();
            }}
            style={{
              maxWidth: "92vw",
              maxHeight: "88vh",
              borderRadius: 12,
              objectFit: "contain",
              boxShadow: "0 8px 40px rgba(0,0,0,0.5)",
            }}
          />
        </div>
      </dialog>

      <style>{`
        @keyframes heroFadeIn {
          from { opacity: 0; }
          to   { opacity: 1; }
        }
        @keyframes lightboxIn {
          from { opacity: 0; transform: scale(0.94); }
          to   { opacity: 1; transform: scale(1); }
        }
        dialog::backdrop {
          background: transparent;
        }
      `}</style>
    </div>
  );
}
