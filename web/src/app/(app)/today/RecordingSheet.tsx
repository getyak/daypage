"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Check } from "lucide-react";

interface RecordingSheetProps {
  isOpen: boolean;
  onClose: () => void;
  onStop: () => void;
}

const BAR_COUNT = 64;
const MAX_DURATION_S = 300;
const IDLE_TIMEOUT_S = 30;

function randomBarHeights(): number[] {
  return Array.from({ length: BAR_COUNT }, () => 4 + Math.random() * 36);
}

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60).toString().padStart(2, "0");
  const s = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

export function RecordingSheet({ isOpen, onClose, onStop }: RecordingSheetProps) {
  const [elapsed, setElapsed] = useState(0);
  const [barHeights, setBarHeights] = useState<number[]>(randomBarHeights);
  const startTimeRef = useRef<number | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const waveformRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const idleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const cleanup = useCallback(() => {
    if (timerRef.current) clearInterval(timerRef.current);
    if (waveformRef.current) clearInterval(waveformRef.current);
    if (idleTimerRef.current) clearTimeout(idleTimerRef.current);
    timerRef.current = null;
    waveformRef.current = null;
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

    setElapsed(0);
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

    // Waveform animation
    waveformRef.current = setInterval(() => {
      setBarHeights(randomBarHeights());
    }, 150);

    // Idle timeout
    resetIdle();

    return cleanup;
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
      <style>{`
        @keyframes sheet-up {
          from { transform: translateY(100%); opacity: 0 }
          to { transform: translateY(0); opacity: 1 }
        }
        @keyframes pulse-dot {
          0%, 100% { box-shadow: 0 0 0 0 rgba(227,107,74,0.6), 0 0 0 4px rgba(227,107,74,0.18) }
          50% { box-shadow: 0 0 0 5px rgba(227,107,74,0), 0 0 0 4px rgba(227,107,74,0.18) }
        }
        @keyframes blink-caret {
          0%, 100% { opacity: 1 }
          50% { opacity: 0 }
        }
        .transcription-placeholder::after {
          content: "▎";
          display: inline-block;
          animation: blink-caret 1s step-start infinite;
          margin-left: 2px;
        }
      `}</style>

      <div
        role="dialog"
        aria-modal="true"
        aria-label="录音中"
        style={{
          position: "fixed",
          bottom: 0,
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
            marginBottom: 20,
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
                fontSize: 12,
                color: "rgba(245,237,227,0.6)",
                letterSpacing: "0.5px",
                textTransform: "uppercase",
              }}
            >
              REC
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

        {/* Waveform */}
        <div
          aria-hidden="true"
          style={{
            display: "flex",
            alignItems: "center",
            gap: 2,
            height: 48,
            marginBottom: 16,
            overflow: "hidden",
          }}
        >
          {barHeights.map((h, i) => (
            <div
              key={i}
              style={{
                width: 2,
                height: h,
                borderRadius: 1,
                background: "rgba(245,237,227,0.5)",
                flexShrink: 0,
                transition: "height 120ms ease",
              }}
            />
          ))}
        </div>

        {/* Transcription placeholder */}
        <p
          className="transcription-placeholder"
          style={{
            margin: "0 0 20px",
            fontSize: 13,
            color: "rgba(245,237,227,0.65)",
            lineHeight: 1.5,
            textAlign: "center",
            fontFamily: "var(--font-body)",
          }}
        >
          正在聆听...
        </p>

        {/* Buttons */}
        <div style={{ display: "flex", gap: 10 }}>
          <button
            onClick={handleCancel}
            style={{
              flex: 1,
              background: "rgba(255,255,255,0.1)",
              color: "#F5EDE3",
              border: "none",
              borderRadius: 999,
              padding: "12px 0",
              fontWeight: 600,
              fontSize: 15,
              cursor: "pointer",
              fontFamily: "var(--font-body)",
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
              background: "#F5EDE3",
              color: "#2B2822",
              border: "none",
              borderRadius: 999,
              padding: "12px 0",
              fontWeight: 600,
              fontSize: 15,
              cursor: "pointer",
              fontFamily: "var(--font-body)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 6,
              transition: "background 140ms",
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.background = "#EDE3D6";
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.background = "#F5EDE3";
            }}
          >
            <Check size={16} strokeWidth={2.2} aria-hidden="true" />
            停止转录
          </button>
        </div>
      </div>
    </>
  );
}
