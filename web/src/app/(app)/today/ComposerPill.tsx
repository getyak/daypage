"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Mic, Plus, Type } from "lucide-react";

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
        bottom: "calc(26px + env(safe-area-inset-bottom, 0px))",
        left: 0,
        right: 0,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        pointerEvents: isRecording ? "none" : "auto",
        opacity: isRecording ? 0 : 1,
        transition: "opacity 180ms ease-out",
        zIndex: 20,
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

      {/* Pill */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          padding: 6,
          borderRadius: 999,
          background: "rgba(255,253,250,0.82)",
          backdropFilter: "blur(28px) saturate(160%)",
          WebkitBackdropFilter: "blur(28px) saturate(160%)",
          border: "0.5px solid rgba(214,206,192,0.5)",
          boxShadow:
            "inset 0 0.5px 0 rgba(255,255,255,0.8), 0 2px 8px rgba(60,40,15,0.10), 0 8px 32px rgba(60,40,15,0.08)",
          animation: "composer-scale-in 240ms ease-out both",
        }}
      >
        {/* [+] Attach button */}
        <button
          aria-label="添加附件"
          onClick={onPlusPress}
          style={{
            width: 48,
            height: 48,
            borderRadius: "50%",
            border: "none",
            background: "transparent",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            color: "var(--fg-muted)",
            transition: "color 140ms, background 140ms",
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.background = "rgba(93,48,0,0.06)";
            e.currentTarget.style.color = "var(--accent)";
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.background = "transparent";
            e.currentTarget.style.color = "var(--fg-muted)";
          }}
        >
          <Plus size={20} strokeWidth={1.7} aria-hidden="true" />
        </button>

        {/* [🎙️] Mic button */}
        <button
          aria-label="按住录音"
          onPointerDown={handleMicPointerDown}
          onPointerUp={handleMicPointerUp}
          onPointerLeave={handleMicPointerLeave}
          onPointerCancel={handleMicPointerLeave}
          style={{
            width: 64,
            height: 56,
            borderRadius: 999,
            border: "none",
            background: micPressed
              ? "linear-gradient(180deg, #5D3000, #3D2000)"
              : "linear-gradient(180deg, #7a3f00, #5D3000)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            color: "#fff",
            transition: "background 120ms, box-shadow 120ms",
            animation: "composer-mic-breathe 1.6s ease-in-out infinite",
            boxShadow: micPressed
              ? "0 0 0 0 rgba(93,48,0,0)"
              : undefined,
            touchAction: "none",
            userSelect: "none",
          }}
        >
          <Mic size={22} strokeWidth={1.8} aria-hidden="true" />
        </button>

        {/* [Aa] Text button */}
        <button
          aria-label="键盘输入"
          onClick={onTextPress}
          style={{
            width: 48,
            height: 48,
            borderRadius: "50%",
            border: "none",
            background: "transparent",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            color: "var(--fg-muted)",
            transition: "color 140ms, background 140ms",
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.background = "rgba(93,48,0,0.06)";
            e.currentTarget.style.color = "var(--accent)";
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.background = "transparent";
            e.currentTarget.style.color = "var(--fg-muted)";
          }}
        >
          <Type size={18} strokeWidth={1.7} aria-hidden="true" />
        </button>
      </div>

      {/* Hint text */}
      <p
        style={{
          margin: 0,
          paddingTop: 4,
          fontFamily: "var(--font-mono)",
          fontSize: 10,
          letterSpacing: "1.5px",
          textTransform: "uppercase",
          color: "var(--fg-subtle)",
          textAlign: "center",
        }}
      >
        长按录音 · 轻点切换
      </p>
    </div>
  );
}
