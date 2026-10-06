"use client";

import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import { useReducedMotionPreference } from "@/hooks/useBrowserCapabilities";

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

function AnimatedSummaryText({ text }: { text: string }) {
  const [count, setCount] = useState(0);
  useEffect(() => {
    let index = 0;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    const tick = () => {
      if (cancelled) return;
      index += 1;
      setCount(index);
      if (index < text.length) timer = setTimeout(tick, 36 + Math.random() * 30);
    };
    timer = setTimeout(tick, 380);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [text]);
  const done = count >= text.length;
  return <>
    <span className={done ? "shimmer-text" : undefined}>{text.slice(0, count)}</span>
    {!done && <span
      aria-hidden="true"
      style={{ display: "inline-block", width: 1, height: "1em", background: "var(--accent)",
        marginLeft: 1, verticalAlign: "text-bottom", animation: "ai-caret-blink 900ms step-end infinite" }}
    />}
  </>;
}

export function AISummaryCard() {
  const [data, setData] = useState<AISummaryData | null>(null);
  const [loading, setLoading] = useState(true);
  const prefersReduced = useReducedMotionPreference();
  const [timestamp, setTimestamp] = useState<string>("");

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

  if (loading) {
    return (
      <motion.div
        initial={prefersReduced ? false : { opacity: 0, y: 6 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
        style={{
          position: "relative",
          borderRadius: 18,
          padding: "18px 20px 20px 22px",
          background: "var(--surface-white)",
          border: "0.5px solid var(--border-subtle)",
          boxShadow: "var(--shadow-card)",
          minHeight: 92,
          overflow: "hidden",
        }}
        aria-busy="true"
        aria-label="AI 摘要加载中"
      >
        {/* shimmer sweep */}
        {!prefersReduced && (
          <motion.div
            aria-hidden="true"
            initial={{ x: "-100%" }}
            animate={{ x: "200%" }}
            transition={{ duration: 1.6, repeat: Infinity, ease: "linear" }}
            style={{
              position: "absolute",
              top: 0,
              left: 0,
              width: "40%",
              height: "100%",
              background:
                "linear-gradient(110deg, transparent 30%, rgba(255,255,255,0.55) 50%, transparent 70%)",
              pointerEvents: "none",
            }}
          />
        )}
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
      </motion.div>
    );
  }

  return (
    <motion.div
      initial={prefersReduced ? false : { opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.34, ease: [0.22, 1, 0.36, 1] }}
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
        {animateEnabled ? <AnimatedSummaryText key={summaryText} text={summaryText} /> : summaryText}
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
    </motion.div>
  );
}
