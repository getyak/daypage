"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Check } from "lucide-react";
import { useWaveform } from "@/hooks/useWaveform";
import { Waveform } from "@/components/ui/Waveform";

interface RecordingSheetProps {
  isOpen: boolean;
  onClose: () => void;
  onStop: () => void;
}

const BAR_COUNT = 64;
const MAX_DURATION_S = 300;
const IDLE_TIMEOUT_S = 30;

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60).toString().padStart(2, "0");
  const s = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

export function RecordingSheet({ isOpen, onClose, onStop }: RecordingSheetProps) {
  const [elapsed, setElapsed] = useState(0);
  // Smooth, phase-locked live waveform (design composer.jsx:5-31, shared hook).
  const bars = useWaveform(isOpen, BAR_COUNT);
  const startTimeRef = useRef<number | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const idleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const cleanup = useCallback(() => {
    if (timerRef.current) clearInterval(timerRef.current);
    if (idleTimerRef.current) clearTimeout(idleTimerRef.current);
    timerRef.current = null;
    idleTimerRef.current = null;
  }, []);

  const resetIdle = useCallback(() => {
    if (idleTimerRef.current) clearTimeout(idleTimerRef.current);
    idleTimerRef.current = setTimeout(() => {
      onStop();
      cleanup();
    }, IDLE_TIMEOUT_S * 1000);
  }, [onStop, cleanup]);

  useEffect(() => {
    if (!isOpen) return;

    startTimeRef.current = Date.now();

    timerRef.current = setInterval(() => {
      if (!startTimeRef.current) return;
      const s = (Date.now() - startTimeRef.current) / 1000;
      setElapsed(s);
      if (s >= MAX_DURATION_S) {
        alert("录音已达上限");
        onStop();
        cleanup();
      }
    }, 1000);

    // Idle timeout
    resetIdle();

    // Reset the clock in cleanup (not the effect body) to avoid the
    // cascading-render lint while still clearing a stale value on close.
    return () => {
      cleanup();
      setElapsed(0);
    };
  }, [isOpen]); // eslint-disable-line react-hooks/exhaustive-deps

  // ESC to close
  useEffect(() => {
    if (!isOpen) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handleKey);
    return () => document.removeEventListener("keydown", handleKey);
  }, [isOpen, onClose]);

  const handleCancel = useCallback(() => {
    cleanup();
    onClose();
  }, [cleanup, onClose]);

  const handleStop = useCallback(() => {
    cleanup();
    onStop();
  }, [cleanup, onStop]);

  if (!isOpen) return null;

  return (
    <>
      <div
        role="dialog"
        aria-modal="true"
        aria-label="录音中"
        style={{
          position: "fixed",
          bottom: "calc(34px + env(safe-area-inset-bottom, 0px))",
          left: 14,
          right: 14,
          zIndex: 55,
          borderRadius: 34,
          padding: "22px 22px 24px",
          background: "rgba(45,30,12,0.92)",
          backdropFilter: "blur(28px) saturate(160%)",
          WebkitBackdropFilter: "blur(28px) saturate(160%)",
          boxShadow: "var(--shadow-recording)",
          animation: "sheet-up 320ms cubic-bezier(.2,.8,.2,1) both",
        }}
      >
        {/* Header row */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            marginBottom: 14,
          }}
        >
          {/* Recording indicator */}
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <div
              style={{
                width: 10,
                height: 10,
                borderRadius: "50%",
                background: "#E36B4A",
                animation: "pulse-dot 1.2s ease-in-out infinite",
              }}
            />
            <span
              style={{
                fontFamily: "var(--font-mono)",
                fontWeight: 500,
                fontSize: 12,
                color: "#F5EDE3",
                letterSpacing: "1.4px",
                textTransform: "uppercase",
              }}
            >
              录音中
            </span>
          </div>

          {/* Timer */}
          <span
            style={{
              fontFamily: "var(--font-mono)",
              fontSize: 28,
              fontWeight: 500,
              color: "#F5EDE3",
              letterSpacing: "1px",
              fontVariantNumeric: "tabular-nums",
            }}
          >
            {formatTime(elapsed)}
          </span>
        </div>

        {/* Waveform — phase-locked, sunken trough (design lines 447-453) */}
        <div
          aria-hidden="true"
          style={{
            height: 56,
            background: "rgba(255,255,255,0.05)",
            borderRadius: 14,
            padding: "0 14px",
            display: "flex",
            alignItems: "center",
            overflow: "hidden",
            border: "0.5px solid rgba(255,255,255,0.08)",
            marginBottom: 16,
          }}
        >
          <Waveform bars={bars} color="#F5EDE3" gap={2} width={2} height={36} />
        </div>

        {/* Transcription preview — sample line + blinking caret (design lines 454-459) */}
        <p
          style={{
            margin: "0 0 20px",
            fontSize: 13,
            color: "rgba(245,237,227,0.65)",
            lineHeight: 1.5,
            fontFamily: "var(--font-body)",
          }}
        >
          “昨天晚上的咖啡馆氛围超好，开到 10 点 — ”
          <span
            aria-hidden="true"
            style={{
              display: "inline-block",
              width: 2,
              height: 13,
              background: "#F5EDE3",
              marginLeft: 2,
              verticalAlign: "-2px",
              animation: "caret 1s steps(1) infinite",
            }}
          />
        </p>

        {/* Buttons */}
        <div style={{ display: "flex", gap: 10 }}>
          <button
            onClick={handleCancel}
            style={{
              flex: 1,
              height: 46,
              background: "rgba(255,255,255,0.1)",
              color: "#F5EDE3",
              border: "none",
              borderRadius: 999,
              fontFamily: "var(--font-body)",
              fontSize: 14,
              fontWeight: 500,
              letterSpacing: "0.2px",
              cursor: "pointer",
              transition: "background 140ms",
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.background = "rgba(255,255,255,0.16)";
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.background = "rgba(255,255,255,0.1)";
            }}
          >
            取消
          </button>

          <button
            onClick={handleStop}
            style={{
              flex: 1.6,
              height: 46,
              background: "#F5EDE3",
              color: "#2B2822",
              border: "none",
              borderRadius: 999,
              fontFamily: "var(--font-body)",
              fontSize: 14,
              fontWeight: 600,
              letterSpacing: "0.2px",
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 8,
              transition: "background 140ms",
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.background = "#EDE3D6";
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.background = "#F5EDE3";
            }}
          >
            <Check size={16} strokeWidth={2} aria-hidden="true" />
            停止并转写
          </button>
        </div>
      </div>
    </>
  );
}
