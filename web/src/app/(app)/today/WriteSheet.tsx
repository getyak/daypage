"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Camera, Check, ImageIcon, MapPin, Tag, X } from "lucide-react";

interface WriteSheetProps {
  isOpen: boolean;
  onClose: () => void;
  onSend: (text: string) => void;
}

// ─── Date / time header strings (museum-tag style) ───────────────────────────
// Design (composer.jsx:233-239): serif weekday + mono "MAY 28 · 15:47".
function useDateStrings() {
  return useMemo(() => {
    const now = new Date();
    const weekday = now.toLocaleDateString("en-US", { weekday: "long" });
    const month = now
      .toLocaleDateString("en-US", { month: "short" })
      .toUpperCase();
    const day = now.getDate();
    const hh = String(now.getHours()).padStart(2, "0");
    const mm = String(now.getMinutes()).padStart(2, "0");
    const iso = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(
      2,
      "0",
    )}-${String(now.getDate()).padStart(2, "0")}`;
    return { weekday, stamp: `${month} ${day} · ${hh}:${mm}`, iso };
  }, []);
}

// ─── Quiet icon-rail button (camera / photo / location / tag) ────────────────
// Design (composer.jsx:347-357): 40×40, transparent, muted, hover background pill.
function WriteIconBtn({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      style={{
        width: 40,
        height: 40,
        borderRadius: 999,
        border: "none",
        cursor: "pointer",
        background: "transparent",
        color: "var(--fg-muted)",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        transition: "background 140ms ease-out, color 140ms ease-out",
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.background = "var(--accent-soft)";
        e.currentTarget.style.color = "var(--accent)";
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.background = "transparent";
        e.currentTarget.style.color = "var(--fg-muted)";
      }}
    >
      {children}
    </button>
  );
}

/**
 * WriteSheet — elegant text composer that slides up from the Composer pill tap.
 *
 * Ported from .design-handoff/v8/composer.jsx:183-345. Backdrop blur overlay +
 * glass sheet (sheet-up anim), drag handle, serif weekday / mono timestamp
 * header, hairline-bounded 18px serif textarea with italic placeholder &
 * auto-grow, quiet icon rail (camera/photo/location/tag), live word count, an
 * accent "保存" pill disabled when empty, and a "SAVED TO VAULT / YYYY-MM-DD.md"
 * mono caption.
 */
export function WriteSheet({ isOpen, onClose, onSend }: WriteSheetProps) {
  const [text, setText] = useState("");
  const taRef = useRef<HTMLTextAreaElement>(null);
  const { weekday, stamp, iso } = useDateStrings();

  // Autofocus shortly after open (lets the sheet-up settle); the cleanup clears
  // the draft when the sheet closes — running setState in cleanup (not in the
  // effect body) avoids the cascading-render lint.
  useEffect(() => {
    if (!isOpen) return;
    const t = setTimeout(() => taRef.current?.focus(), 200);
    return () => {
      clearTimeout(t);
      setText("");
    };
  }, [isOpen]);

  // Auto-grow the textarea up to its max-height (design: min 90, max 280).
  useEffect(() => {
    const ta = taRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${Math.min(ta.scrollHeight, 280)}px`;
  }, [text]);

  // ESC closes.
  useEffect(() => {
    if (!isOpen) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [isOpen, onClose]);

  // Non-whitespace character count (design line 201).
  const words = useMemo(() => text.replace(/\s/g, "").length, [text]);
  const canSend = text.trim().length > 0;

  const handleSend = useCallback(() => {
    if (!canSend) return;
    onSend(text);
  }, [canSend, onSend, text]);

  // ⌘/Ctrl+Enter to save (elegance upgrade — keyboard affordance).
  const handleTextareaKey = useCallback(
    (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        handleSend();
      }
    },
    [handleSend],
  );

  if (!isOpen) return null;

  return (
    <>
      {/* Backdrop — design lines 206-209 */}
      <div
        aria-hidden="true"
        onClick={onClose}
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(30,24,18,0.34)",
          backdropFilter: "blur(2px)",
          WebkitBackdropFilter: "blur(2px)",
          zIndex: 60,
          animation: "fade-in 200ms ease-out both",
        }}
      />

      {/* Glass sheet — design lines 211-221 */}
      <div
        role="dialog"
        aria-modal="true"
        aria-label="书写"
        style={{
          position: "fixed",
          left: 0,
          right: 0,
          bottom: 0,
          zIndex: 65,
          background: "rgba(252,250,247,0.96)",
          backdropFilter: "blur(28px) saturate(160%)",
          WebkitBackdropFilter: "blur(28px) saturate(160%)",
          borderTopLeftRadius: 28,
          borderTopRightRadius: 28,
          borderTop: "0.5px solid var(--border-subtle)",
          boxShadow: "0 -24px 60px -20px rgba(60,40,15,0.32)",
          animation: "sheet-up 320ms cubic-bezier(.2,.8,.2,1) both",
          paddingBottom: "calc(28px + env(safe-area-inset-bottom, 0px))",
        }}
      >
        {/* Drag handle — design lines 222-225 */}
        <div style={{ paddingTop: 8, display: "flex", justifyContent: "center" }}>
          <span
            style={{
              width: 34,
              height: 4,
              borderRadius: 4,
              background: "var(--border-default)",
            }}
          />
        </div>

        {/* Header — museum-tag date strip (design lines 227-249) */}
        <div
          style={{
            padding: "14px 22px 12px",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
            <span
              style={{
                fontFamily: "var(--font-serif)",
                fontSize: 18,
                fontWeight: 600,
                color: "var(--fg-primary)",
                letterSpacing: "-0.2px",
                lineHeight: 1,
              }}
            >
              {weekday}
            </span>
            <span
              style={{
                fontFamily: "var(--font-mono)",
                fontSize: 10,
                fontWeight: 700,
                letterSpacing: "1.6px",
                color: "var(--fg-subtle)",
              }}
            >
              {stamp}
            </span>
          </div>
          <button
            type="button"
            aria-label="关闭"
            onClick={onClose}
            style={{
              width: 30,
              height: 30,
              borderRadius: 999,
              border: "none",
              cursor: "pointer",
              background: "var(--surface-sunken)",
              color: "var(--fg-muted)",
              display: "inline-flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <X size={13} strokeWidth={2} aria-hidden="true" />
          </button>
        </div>

        {/* Hairline — design line 252 */}
        <div
          style={{
            height: 0.5,
            background: "var(--border-subtle)",
            margin: "0 22px",
          }}
        />

        {/* Textarea — serif, italic placeholder, auto-grow (design lines 255-276) */}
        <div style={{ padding: "20px 22px 18px" }}>
          <textarea
            ref={taRef}
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={handleTextareaKey}
            placeholder="此刻在想什么？"
            rows={3}
            className="write-sheet-textarea"
            style={{
              width: "100%",
              resize: "none",
              border: "none",
              outline: "none",
              background: "transparent",
              fontFamily: "var(--font-serif)",
              fontSize: 18,
              lineHeight: 1.7,
              letterSpacing: "0.2px",
              color: "var(--fg-primary)",
              minHeight: 90,
              maxHeight: 280,
              padding: 0,
              caretColor: "var(--accent)",
            }}
          />
          <style>{`
            .write-sheet-textarea::placeholder {
              color: var(--fg-subtle);
              opacity: 0.6;
              font-style: italic;
            }
            .write-sheet-textarea::-webkit-scrollbar { display: none; }
          `}</style>
        </div>

        {/* Hairline — design line 279 */}
        <div
          style={{
            height: 0.5,
            background: "var(--border-subtle)",
            margin: "0 22px",
          }}
        />

        {/* Footer — icon rail + word count + save pill (design lines 282-330) */}
        <div
          style={{
            padding: "14px 18px 0",
            display: "flex",
            alignItems: "center",
            gap: 2,
          }}
        >
          <WriteIconBtn label="拍照">
            <Camera size={19} strokeWidth={1.7} aria-hidden="true" />
          </WriteIconBtn>
          <WriteIconBtn label="相册">
            <ImageIcon size={19} strokeWidth={1.7} aria-hidden="true" />
          </WriteIconBtn>
          <WriteIconBtn label="位置">
            <MapPin size={19} strokeWidth={1.7} aria-hidden="true" />
          </WriteIconBtn>
          <WriteIconBtn label="标签">
            <Tag size={19} strokeWidth={1.7} aria-hidden="true" />
          </WriteIconBtn>

          <span style={{ flex: 1 }} />

          <span
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: 10,
              fontWeight: 600,
              letterSpacing: "1.3px",
              color: words ? "var(--fg-muted)" : "var(--fg-subtle)",
              marginRight: 10,
              fontVariantNumeric: "tabular-nums",
            }}
          >
            {words} 字
          </span>

          <button
            type="button"
            disabled={!canSend}
            onClick={handleSend}
            style={{
              height: 38,
              padding: "0 16px",
              borderRadius: 999,
              border: "none",
              cursor: canSend ? "pointer" : "default",
              background: canSend ? "var(--accent)" : "var(--surface-sunken)",
              color: canSend ? "#FAF8F6" : "var(--fg-subtle)",
              fontFamily: "var(--font-body)",
              fontSize: 13.5,
              fontWeight: 600,
              letterSpacing: "0.2px",
              display: "inline-flex",
              alignItems: "center",
              gap: 6,
              transition: "background 180ms ease-out, color 180ms ease-out",
            }}
          >
            保存
            <Check size={13} strokeWidth={2.2} aria-hidden="true" />
          </button>
        </div>

        {/* SAVED TO VAULT caption — museum-caption (design lines 333-341) */}
        <div
          style={{
            padding: "10px 22px 0",
            fontFamily: "var(--font-mono)",
            fontSize: 9,
            letterSpacing: "1.4px",
            fontWeight: 600,
            color: "var(--fg-subtle)",
            display: "flex",
            alignItems: "center",
            gap: 8,
          }}
        >
          <span>SAVED TO</span>
          <span style={{ color: "var(--fg-muted)" }}>VAULT / {iso}.md</span>
        </div>
      </div>
    </>
  );
}
