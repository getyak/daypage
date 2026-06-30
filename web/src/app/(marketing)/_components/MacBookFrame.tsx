"use client";

import { type ReactNode } from "react";

interface MacBookFrameProps {
  children: ReactNode;
  /** Logical outer width in px; height derives from 16:10 + lid stack. */
  width?: number;
  className?: string;
}

/**
 * Pure-CSS MacBook silhouette with a notched lid and a sliver of base. The
 * inner screen is a 16:10 surface so children render at native macOS aspect.
 */
export function MacBookFrame({
  children,
  width = 520,
  className,
}: MacBookFrameProps) {
  const SCREEN_RATIO = 10 / 16;
  const screenH = Math.round(width * SCREEN_RATIO);
  const notchW = Math.round(width * 0.18);
  const notchH = Math.max(8, Math.round(width * 0.018));
  const baseH = Math.max(6, Math.round(width * 0.014));
  const baseExtra = Math.round(width * 0.06);
  const totalH = screenH + baseH + 4;

  return (
    <div
      className={className}
      style={{
        position: "relative",
        width,
        height: totalH,
        filter:
          "drop-shadow(0 36px 70px rgba(43,40,34,0.22)) drop-shadow(0 10px 22px rgba(43,40,34,0.12))",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: `0 0 ${baseH + 4}px 0`,
          borderRadius: width * 0.022,
          background:
            "linear-gradient(160deg, #C8C1B5 0%, #918A7D 35%, #5F5950 70%, #989085 100%)",
          padding: Math.max(3, width * 0.006),
        }}
      >
        <div
          style={{
            position: "relative",
            width: "100%",
            height: "100%",
            borderRadius: width * 0.018,
            background: "#0F0D0B",
            overflow: "hidden",
          }}
        >
          <div
            aria-hidden
            style={{
              position: "absolute",
              top: 0,
              left: "50%",
              transform: "translateX(-50%)",
              width: notchW,
              height: notchH,
              background: "#0F0D0B",
              borderBottomLeftRadius: notchH,
              borderBottomRightRadius: notchH,
              zIndex: 2,
            }}
          />
          <div
            style={{
              position: "absolute",
              inset: `${Math.round(width * 0.012)}px ${Math.round(
                width * 0.008,
              )}px`,
              borderRadius: width * 0.012,
              overflow: "hidden",
              background: "var(--bg-warm)",
            }}
          >
            {children}
          </div>
        </div>
      </div>

      <div
        aria-hidden
        style={{
          position: "absolute",
          bottom: 0,
          left: -baseExtra / 2,
          width: width + baseExtra,
          height: baseH,
          borderRadius: `0 0 ${baseH}px ${baseH}px`,
          background:
            "linear-gradient(180deg, #B7AFA2 0%, #8B8377 60%, #5C564D 100%)",
          boxShadow: "inset 0 1px 0 rgba(255,255,255,0.4)",
        }}
      />
      <div
        aria-hidden
        style={{
          position: "absolute",
          bottom: baseH,
          left: "50%",
          transform: "translateX(-50%)",
          width: width * 0.18,
          height: 3,
          background: "rgba(0,0,0,0.18)",
          borderRadius: 2,
        }}
      />
    </div>
  );
}

/** Minimal Archive month-grid mock for the MacBook lid. */
export function MacBookArchiveMock() {
  const days = Array.from({ length: 35 });
  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        padding: 12,
        background:
          "linear-gradient(180deg, var(--bg-warm) 0%, #F4ECD9 100%)",
        color: "var(--fg-primary)",
        fontFamily: "var(--font-inter), sans-serif",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          marginBottom: 10,
        }}
      >
        <div
          style={{
            fontFamily: "var(--font-fraunces), serif",
            fontSize: 13,
            fontWeight: 600,
          }}
        >
          June · 2026
        </div>
        <div
          style={{
            display: "flex",
            gap: 6,
            fontSize: 9,
            color: "var(--fg-subtle, #A39F99)",
          }}
        >
          <span>Archive</span>
          <span>·</span>
          <span>Graph</span>
        </div>
      </div>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(7, 1fr)",
          gap: 3,
          flex: 1,
        }}
      >
        {days.map((_, i) => {
          const intensity = [0, 0.15, 0.3, 0.55, 0.85][i % 5];
          return (
            <div
              key={i}
              style={{
                aspectRatio: "1 / 1",
                borderRadius: 3,
                background:
                  intensity === 0
                    ? "rgba(0,0,0,0.04)"
                    : `color-mix(in srgb, var(--accent) ${intensity * 100}%, transparent)`,
              }}
            />
          );
        })}
      </div>
      <div
        style={{
          marginTop: 8,
          fontSize: 9,
          color: "var(--fg-subtle, #A39F99)",
        }}
      >
        128 days captured · 1,402 memos
      </div>
    </div>
  );
}
