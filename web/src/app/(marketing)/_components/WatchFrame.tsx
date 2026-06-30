"use client";

import { type ReactNode } from "react";

interface WatchFrameProps {
  children: ReactNode;
  /** Outer case width in px. Height ≈ width * 1.18 (Series-10 49mm). */
  width?: number;
  className?: string;
}

/**
 * Pure-CSS Apple Watch silhouette with digital crown and side button. Inner
 * screen is a rounded rect that scales with the case.
 */
export function WatchFrame({
  children,
  width = 160,
  className,
}: WatchFrameProps) {
  const height = Math.round(width * 1.18);
  const crownH = Math.round(width * 0.16);
  const crownW = Math.round(width * 0.05);
  const buttonH = Math.round(width * 0.12);

  return (
    <div
      className={className}
      style={{
        position: "relative",
        width: width + crownW + 4,
        height,
        filter:
          "drop-shadow(0 22px 44px rgba(43,40,34,0.22)) drop-shadow(0 6px 14px rgba(43,40,34,0.12))",
      }}
    >
      <div
        aria-hidden
        style={{
          position: "absolute",
          right: 0,
          top: "30%",
          width: crownW,
          height: crownH,
          background:
            "linear-gradient(180deg, #C8C1B5 0%, #918A7D 50%, #5F5950 100%)",
          borderRadius: "2px 3px 3px 2px",
          boxShadow: "inset -1px 0 0 rgba(0,0,0,0.3)",
        }}
      />
      <div
        aria-hidden
        style={{
          position: "absolute",
          right: 0,
          top: "30%",
          marginTop: crownH + 6,
          width: crownW * 0.8,
          height: buttonH,
          background:
            "linear-gradient(180deg, #8E867A 0%, #5F5950 100%)",
          borderRadius: "1px 2px 2px 1px",
        }}
      />

      <div
        style={{
          position: "relative",
          width,
          height,
          borderRadius: width * 0.32,
          background:
            "linear-gradient(160deg, #28241F 0%, #3A342C 40%, #1A1714 100%)",
          padding: Math.max(4, width * 0.04),
        }}
      >
        <div
          style={{
            width: "100%",
            height: "100%",
            borderRadius: width * 0.26,
            background: "#000",
            overflow: "hidden",
            position: "relative",
          }}
        >
          {children}
        </div>
      </div>
    </div>
  );
}

/** Today-glance mock for the watch face. */
export function WatchGlanceMock() {
  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        justifyContent: "space-between",
        padding: "10px 8px 12px",
        color: "#F4ECD9",
        fontFamily: "var(--font-inter), sans-serif",
        background:
          "radial-gradient(120% 80% at 30% 0%, rgba(124,45,18,0.22) 0%, transparent 60%), #000",
      }}
    >
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          fontSize: 9,
          color: "rgba(244,236,217,0.55)",
        }}
      >
        <span>Today</span>
        <span style={{ color: "#E36B4A" }}>● 14:22</span>
      </div>

      <div style={{ textAlign: "center" }}>
        <div
          style={{
            fontFamily: "var(--font-fraunces), serif",
            fontSize: 28,
            lineHeight: 1,
            letterSpacing: -1,
            fontWeight: 600,
          }}
        >
          12
        </div>
        <div
          style={{
            marginTop: 3,
            fontSize: 9,
            color: "rgba(244,236,217,0.65)",
          }}
        >
          memos today
        </div>
      </div>

      <div
        style={{
          display: "flex",
          justifyContent: "center",
          gap: 3,
        }}
      >
        {[1, 1, 1, 1, 0.5, 0.5, 0.2].map((opacity, i) => (
          <span
            key={i}
            style={{
              width: 6,
              height: 6,
              borderRadius: "50%",
              background: `rgba(227,107,74,${opacity})`,
            }}
          />
        ))}
      </div>
    </div>
  );
}
