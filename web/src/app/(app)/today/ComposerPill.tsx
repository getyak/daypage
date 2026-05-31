"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Mic, Plus } from "lucide-react";

// ─── Mic Permission Hook ─────────────────────────────────────────────────────

type MicPermission = "unknown" | "granted" | "denied" | "requesting";

function useMicPermission() {
  const [permission, setPermission] = useState<MicPermission>("unknown");

  useEffect(() => {
    if (typeof navigator === "undefined") return;
    if (navigator.permissions) {
      navigator.permissions
        .query({ name: "microphone" as PermissionName })
        .then((status) => {
          setPermission(status.state === "granted" ? "granted" : status.state === "denied" ? "denied" : "unknown");
          status.onchange = () => {
            setPermission(status.state === "granted" ? "granted" : status.state === "denied" ? "denied" : "unknown");
          };
        })
        .catch(() => {});
    }
  }, []);

  const requestPermission = useCallback(async (): Promise<boolean> => {
    if (permission === "granted") return true;
    setPermission("requesting");
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
      setPermission("granted");
      return true;
    } catch {
      setPermission("denied");
      return false;
    }
  }, [permission]);

  return { permission, requestPermission };
}

// ─── Props ───────────────────────────────────────────────────────────────────

interface ComposerPillProps {
  onMicPress: () => void;
  onMicLongPress: () => void;
  onPlusPress: () => void;
  onTextPress: () => void;
  isRecording: boolean;
}

// ─── Component ───────────────────────────────────────────────────────────────

export function ComposerPill({
  onMicPress,
  onMicLongPress,
  onPlusPress,
  onTextPress,
  isRecording,
}: ComposerPillProps) {
  const { permission, requestPermission } = useMicPermission();
  const [micPressed, setMicPressed] = useState(false);
  const longPressTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pressStarted = useRef(false);
  const [denied, setDenied] = useState(false);

  const clearTimer = useCallback(() => {
    if (longPressTimer.current !== null) {
      clearTimeout(longPressTimer.current);
      longPressTimer.current = null;
    }
  }, []);

  const handleMicPointerDown = useCallback(
    (e: React.PointerEvent<HTMLButtonElement>) => {
      e.currentTarget.setPointerCapture(e.pointerId);
      pressStarted.current = true;
      setMicPressed(true);

      longPressTimer.current = setTimeout(async () => {
        if (!pressStarted.current) return;
        if (typeof navigator !== "undefined" && navigator.vibrate) {
          navigator.vibrate(10);
        }
        if (permission !== "granted") {
          const ok = await requestPermission();
          if (!ok) {
            setDenied(true);
            setTimeout(() => setDenied(false), 3500);
            pressStarted.current = false;
            setMicPressed(false);
            return;
          }
        }
        onMicLongPress();
        pressStarted.current = false;
        setMicPressed(false);
      }, 220);
    },
    [permission, requestPermission, onMicLongPress]
  );

  const handleMicPointerUp = useCallback(
    (e: React.PointerEvent<HTMLButtonElement>) => {
      e.currentTarget.releasePointerCapture(e.pointerId);
      const wasPressed = pressStarted.current;
      pressStarted.current = false;
      setMicPressed(false);

      if (wasPressed && longPressTimer.current !== null) {
        // tap: timer hasn't fired yet — it was a short press
        clearTimer();
        if (typeof navigator !== "undefined" && navigator.vibrate) {
          navigator.vibrate(5);
        }
        onMicPress();
      } else {
        clearTimer();
      }
    },
    [clearTimer, onMicPress]
  );

  const handleMicPointerLeave = useCallback(() => {
    pressStarted.current = false;
    setMicPressed(false);
    clearTimer();
  }, [clearTimer]);

  useEffect(() => () => clearTimer(), [clearTimer]);

  return (
    <div
      style={{
        position: "absolute",
        bottom: 0,
        left: 0,
        right: 0,
        paddingTop: 48,
        paddingLeft: 14,
        paddingRight: 14,
        paddingBottom: "calc(22px + env(safe-area-inset-bottom, 0px))",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        pointerEvents: isRecording ? "none" : "auto",
        opacity: isRecording ? 0 : 1,
        transition: "opacity 180ms ease-out",
        zIndex: 20,
        background:
          "linear-gradient(to bottom, transparent 0%, rgba(250,248,246,0.72) 38%, rgba(250,248,246,0.96) 68%, #FAF8F6 100%)",
      }}
    >
      {/* Permission denied toast */}
      {denied && (
        <div
          role="alert"
          style={{
            marginBottom: 8,
            padding: "8px 14px",
            borderRadius: 10,
            background: "rgba(162,58,46,0.92)",
            color: "#fff",
            fontSize: 12,
            fontFamily: "var(--font-mono)",
            letterSpacing: "0.5px",
            backdropFilter: "blur(12px)",
            boxShadow: "0 4px 16px rgba(0,0,0,0.18)",
          }}
        >
          需要麦克风权限才能录音 · 去设置
        </div>
      )}

      {/* Pill — [+] [text placeholder] [mic] (design composer.jsx:89-157) */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 4,
          width: "100%",
          maxWidth: 420,
          padding: "6px 6px 6px 10px",
          borderRadius: 999,
          background: "rgba(255,253,250,0.84)",
          backdropFilter: "blur(28px) saturate(160%)",
          WebkitBackdropFilter: "blur(28px) saturate(160%)",
          border: "0.5px solid rgba(214,206,192,0.55)",
          boxShadow:
            "inset 0 1px 0 rgba(255,255,255,0.9), inset 0 -1px 0 rgba(0,0,0,0.04), 0 2px 6px rgba(60,40,15,0.08), 0 18px 32px -12px rgba(60,40,15,0.22)",
          animation: "composer-scale-in 240ms ease-out both",
        }}
      >
        {/* [+] small grey attach button (design:104-113) */}
        <button
          aria-label="添加附件"
          onClick={onPlusPress}
          style={{
            width: 36,
            height: 44,
            borderRadius: 999,
            border: "none",
            background: "transparent",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            flexShrink: 0,
            color: "var(--fg-muted)",
            transition: "color 140ms",
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.color = "var(--accent)";
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.color = "var(--fg-muted)";
          }}
        >
          <Plus size={20} strokeWidth={1.7} aria-hidden="true" />
        </button>

        {/* text-field stub — italic serif placeholder + blinking accent caret;
            taps open the WriteSheet (design:116-129) */}
        <button
          aria-label="书写"
          onClick={onTextPress}
          style={{
            flex: 1,
            height: 44,
            border: "none",
            cursor: "text",
            background: "transparent",
            textAlign: "left",
            padding: "0 12px 0 4px",
            display: "flex",
            alignItems: "center",
            gap: 10,
            color: "var(--fg-subtle)",
            fontFamily: "var(--font-serif)",
            fontSize: 15.5,
            fontStyle: "italic",
            letterSpacing: "0.2px",
          }}
        >
          记下此刻
          <span
            aria-hidden="true"
            style={{
              display: "inline-block",
              width: 2,
              height: 14,
              background: "var(--accent)",
              opacity: 0.5,
              animation: "caret 1.2s steps(1) infinite",
            }}
          />
        </button>

        {/* [🎙️] Mic button — 50×44 amber gradient (design:132-156) */}
        <button
          aria-label="按住录音"
          onPointerDown={handleMicPointerDown}
          onPointerUp={handleMicPointerUp}
          onPointerLeave={handleMicPointerLeave}
          onPointerCancel={handleMicPointerLeave}
          style={{
            width: 50,
            height: 44,
            borderRadius: 999,
            border: "none",
            flexShrink: 0,
            background: micPressed
              ? "linear-gradient(180deg, #5D3000 0%, #3D2000 100%)"
              : "linear-gradient(180deg, #7a3f00 0%, #5D3000 100%)",
            display: "inline-flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            color: "#FAF8F6",
            position: "relative",
            transition: "background 120ms",
            animation: "composer-mic-breathe 1.6s ease-in-out infinite",
            boxShadow:
              "inset 0 1px 0 rgba(255,255,255,0.18), 0 4px 10px -4px rgba(93,48,0,0.45)",
            touchAction: "none",
            userSelect: "none",
          }}
        >
          <Mic size={20} strokeWidth={1.9} aria-hidden="true" />
        </button>
      </div>

      {/* Hint text — '轻点书写 · 长按录音' (design:163) */}
      <p
        style={{
          margin: 0,
          paddingTop: 8,
          fontFamily: "var(--font-mono)",
          fontSize: 9,
          fontWeight: 600,
          letterSpacing: "1.4px",
          color: "var(--fg-subtle)",
          textAlign: "center",
        }}
      >
        轻点书写 · 长按录音
      </p>
    </div>
  );
}
