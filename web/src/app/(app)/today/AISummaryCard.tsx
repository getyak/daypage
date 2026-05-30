"use client";

import { useEffect, useRef, useState } from "react";

type AISummaryData = {
  summary: string | null;
  generated_at: string | null;
  is_stale: boolean;
  memo_count_at_generation: number;
};

const PLACEHOLDER = "今天还没攒够话，再记一条试试";

function SparkleSVG() {
  return (
    <svg
      width="11"
      height="11"
      viewBox="0 0 11 11"
      fill="none"
      aria-hidden="true"
      style={{ display: "block", flexShrink: 0 }}
    >
      <path
        d="M5.5 0L6.45 4.05L10.5 5L6.45 5.95L5.5 10L4.55 5.95L0.5 5L4.55 4.05L5.5 0Z"
        fill="var(--accent)"
      />
    </svg>
  );
}

function useTypewriter(text: string, enabled: boolean) {
  const [displayed, setDisplayed] = useState("");
  const [done, setDone] = useState(false);
  const frameRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!enabled) {
      setDisplayed(text);
      setDone(true);
      return;
    }

    setDisplayed("");
    setDone(false);

    let index = 0;
    let cancelled = false;

    const tick = () => {
      if (cancelled) return;
      if (index >= text.length) {
        setDone(true);
        return;
      }
      setDisplayed(text.slice(0, index + 1));
      index++;
      const delay = 36 + Math.random() * 30;
      frameRef.current = setTimeout(tick, delay);
    };

    const startDelay = setTimeout(tick, 380);

    return () => {
      cancelled = true;
      clearTimeout(startDelay);
      if (frameRef.current !== null) clearTimeout(frameRef.current);
    };
  }, [text, enabled]);

  return { displayed, done };
}

export function AISummaryCard() {
  const [data, setData] = useState<AISummaryData | null>(null);
  const [loading, setLoading] = useState(true);
  const [prefersReduced, setPrefersReduced] = useState(false);
  const [timestamp, setTimestamp] = useState<string>("");

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    setPrefersReduced(mq.matches);
    const handler = (e: MediaQueryListEvent) => setPrefersReduced(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, []);

  useEffect(() => {
    fetch("/api/today/ai-summary")
      .then((r) => r.json())
      .then((d: AISummaryData) => {
        setData(d);
        if (d.generated_at) {
          const dt = new Date(d.generated_at);
          const hh = String(dt.getHours()).padStart(2, "0");
          const mm = String(dt.getMinutes()).padStart(2, "0");
          setTimestamp(`${hh}:${mm}`);
        }
      })
      .catch(() => setData(null))
      .finally(() => setLoading(false));
  }, []);

  const summaryText = data?.summary ?? PLACEHOLDER;
  const isPlaceholder = !data?.summary;
  const animateEnabled = !prefersReduced && !isPlaceholder && !loading;

  const { displayed, done } = useTypewriter(summaryText, animateEnabled);

  const renderedText = animateEnabled ? displayed : summaryText;
  const showCaret = animateEnabled && !done;
  // Signature elegance (gap CRITICAL): once the typewriter finishes, the
  // resolved summary breathes via the iridescent .shimmer-text sweep
  // (globals.css ← tokens.css:54-60). Skipped for placeholder copy, while
  // loading, and when the user prefers reduced motion.
  const showShimmer = !isPlaceholder && !loading && !prefersReduced && (done || !animateEnabled);

  if (loading) {
    return (
      <div
        style={{
          position: "relative",
          borderRadius: 18,
          padding: "18px 20px 20px 22px",
          background: "var(--surface-white)",
          border: "0.5px solid var(--border-subtle)",
          boxShadow: "var(--shadow-card)",
          minHeight: 92,
        }}
        aria-busy="true"
        aria-label="AI 摘要加载中"
      >
        <div
          style={{
            position: "absolute",
            left: 0,
            top: 14,
            bottom: 14,
            width: 2,
            borderRadius: 999,
            background: "var(--accent)",
            opacity: 0.85,
          }}
        />
        <div
          style={{
            height: 10,
            width: "40%",
            borderRadius: 4,
            background: "var(--surface-sunken)",
            marginBottom: 14,
          }}
        />
        <div
          style={{
            height: 10,
            width: "80%",
            borderRadius: 4,
            background: "var(--surface-sunken)",
            marginBottom: 8,
          }}
        />
        <div
          style={{
            height: 10,
            width: "60%",
            borderRadius: 4,
            background: "var(--surface-sunken)",
          }}
        />
      </div>
    );
  }

  return (
    <div
      style={{
        position: "relative",
        borderRadius: 18,
        padding: "18px 20px 20px 22px",
        background: "var(--surface-white)",
        border: "0.5px solid var(--border-subtle)",
        boxShadow: "var(--shadow-card)",
      }}
    >
      {/* Left accent rail */}
      <div
        style={{
          position: "absolute",
          left: 0,
          top: 14,
          bottom: 14,
          width: 2,
          borderRadius: 999,
          background: "var(--accent)",
          opacity: 0.85,
        }}
      />

      {/* Header row */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          marginBottom: 12,
        }}
      >
        <SparkleSVG />
        <span
          style={{
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: 9.5,
            textTransform: "uppercase",
            letterSpacing: "1.6px",
            color: "var(--accent)",
            fontWeight: 700,
            flex: 1,
          }}
        >
          AI · 今日一句
        </span>
        {timestamp && (
          <span
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: 5,
            }}
            aria-label={`生成时间 ${timestamp}`}
          >
            <span
              aria-hidden="true"
              style={{
                width: 5,
                height: 5,
                borderRadius: 999,
                background: "var(--accent)",
                flexShrink: 0,
              }}
            />
            <span
              style={{
                fontFamily: "var(--font-family-mono), monospace",
                fontSize: 9,
                color: "var(--fg-subtle)",
                letterSpacing: "1.2px",
                fontWeight: 600,
              }}
            >
              {timestamp}
            </span>
          </span>
        )}
      </div>

      {/* Summary text */}
      <blockquote
        aria-live="polite"
        style={{
          margin: 0,
          padding: 0,
          fontFamily: `"Fraunces", var(--font-family-serif), Georgia, serif`,
          fontSize: 19,
          fontWeight: 500,
          fontStyle: isPlaceholder ? "normal" : "italic",
          lineHeight: 1.45,
          letterSpacing: "0.1px",
          minHeight: 54,
          color: isPlaceholder ? "var(--fg-subtle)" : "var(--fg-primary)",
        }}
      >
        {showShimmer ? (
          <span className="shimmer-text">{renderedText}</span>
        ) : (
          renderedText
        )}
        {showCaret && (
          <span
            aria-hidden="true"
            style={{
              display: "inline-block",
              width: 1,
              height: "1em",
              background: "var(--accent)",
              marginLeft: 1,
              verticalAlign: "text-bottom",
              animation: "ai-caret-blink 900ms step-end infinite",
            }}
          />
        )}
        {data?.is_stale && !isPlaceholder && (
          <>
            {" "}
            <button
              type="button"
              onClick={() => window.location.reload()}
              style={{
                fontFamily: "var(--font-family-mono), monospace",
                fontSize: "var(--font-size-mono-xs)",
                color: "var(--accent)",
                background: "none",
                border: "none",
                cursor: "pointer",
                padding: 0,
                textDecoration: "underline",
                textUnderlineOffset: 2,
                fontStyle: "normal",
              }}
            >
              重新生成
            </button>
          </>
        )}
      </blockquote>

      <style>{`
        @keyframes ai-caret-blink {
          0%, 100% { opacity: 1; }
          50% { opacity: 0; }
        }
      `}</style>
    </div>
  );
}
