"use client";

import { useEffect, useRef, useState } from "react";

type UnlockStatus = {
  memo_count: number;
  unlock_threshold: number;
  unlocked: boolean;
};

// Sparkle icon — same shape as AISummaryCard's SparkleSVG but larger
function SparkleSVG() {
  return (
    <svg
      width="16"
      height="16"
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

export function UnlockPlaceholderCard({
  composerMicRef,
}: {
  composerMicRef?: React.RefObject<HTMLButtonElement | null>;
}) {
  const [status, setStatus] = useState<UnlockStatus | null>(null);
  const [visible, setVisible] = useState(true);
  const [fadeOut, setFadeOut] = useState(false);
  const [showBanner, setShowBanner] = useState(false);
  const prevUnlocked = useRef(false);

  useEffect(() => {
    fetch("/api/today/unlock-status")
      .then((r) => r.json())
      .then((d: UnlockStatus) => setStatus(d))
      .catch(() => {});
  }, []);

  // Trigger fade-out animation when threshold is newly met
  useEffect(() => {
    if (!status) return;
    if (status.unlocked && !prevUnlocked.current) {
      prevUnlocked.current = true;
      setFadeOut(true);
      setShowBanner(true);
      const t = setTimeout(() => setVisible(false), 280);
      return () => clearTimeout(t);
    }
    prevUnlocked.current = status.unlocked;
  }, [status]);

  // Don't render once fully faded
  if (!visible) return null;

  // Already unlocked on first load — skip the placeholder entirely
  if (status?.unlocked && !fadeOut) return null;

  const handleClick = () => {
    composerMicRef?.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      handleClick();
    }
  };

  if (showBanner) {
    return (
      <div
        aria-live="polite"
        style={{
          opacity: fadeOut ? 0 : 1,
          transition: "opacity 280ms ease-out",
          borderRadius: 18,
          padding: "14px 18px",
          background: "var(--accent-soft)",
          border: "0.5px solid var(--accent-border)",
          display: "flex",
          alignItems: "center",
          gap: 8,
        }}
      >
        <SparkleSVG />
        <span
          style={{
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: "var(--font-size-mono-sm)",
            textTransform: "uppercase",
            letterSpacing: "0.06em",
            color: "var(--accent)",
            fontWeight: 600,
          }}
        >
          今日已解锁
        </span>
      </div>
    );
  }

  return (
    <div
      role="button"
      tabIndex={0}
      aria-label="再记一条解锁今日成稿，点击聚焦输入框"
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      style={{
        opacity: fadeOut ? 0 : 1,
        transition: "opacity 280ms ease-out",
        cursor: "pointer",
        borderRadius: 18,
        padding: 18,
        background: "transparent",
        border: "1.5px dashed var(--accent-border)",
        display: "flex",
        alignItems: "center",
        gap: 14,
      }}
    >
      {/* Sparkle icon circle */}
      <div
        aria-hidden="true"
        style={{
          width: 36,
          height: 36,
          borderRadius: "50%",
          background: "var(--accent-soft)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          flexShrink: 0,
        }}
      >
        <SparkleSVG />
      </div>

      {/* Text */}
      <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
        <span
          style={{
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: "var(--font-size-mono-sm)",
            textTransform: "uppercase",
            letterSpacing: "0.06em",
            color: "var(--fg-primary)",
            fontWeight: 600,
          }}
        >
          再记一条解锁今日成稿
        </span>
        <span
          style={{
            fontFamily: "var(--font-family-body), ui-sans-serif, sans-serif",
            fontSize: "var(--font-size-body-xs)",
            color: "var(--fg-muted)",
            lineHeight: 1.4,
          }}
        >
          AI 将把今天的碎片连缀成一篇日页
        </span>
      </div>
    </div>
  );
}
