"use client";

import { type ReactNode } from "react";

interface IPhoneFrameProps {
  children: ReactNode;
  /** Logical inner-screen width in px; height derives from 19.5:9 ratio. */
  width?: number;
  className?: string;
}

/**
 * Pure SVG iPhone 15 Pro silhouette with a content window that scales with the
 * frame. The body uses a CSS aspect-ratio box so layout shift is zero.
 */
export function IPhoneFrame({
  children,
  width = 360,
  className,
}: IPhoneFrameProps) {
  // iPhone 15 Pro: 19.5:9 outer.
  const RATIO = 19.5 / 9;
  const height = Math.round(width * RATIO);

  return (
    <div
      className={className}
      style={{
        position: "relative",
        width,
        height,
        filter:
          "drop-shadow(0 30px 60px rgba(43,40,34,0.18)) drop-shadow(0 8px 18px rgba(43,40,34,0.10))",
      }}
    >
      {/* Outer titanium ring */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: width * 0.16,
          background:
            "linear-gradient(160deg, #C6BFB3 0%, #8E867A 35%, #5F5950 70%, #948C7F 100%)",
          padding: width * 0.018,
        }}
      >
        {/* Inner bezel */}
        <div
          style={{
            position: "relative",
            width: "100%",
            height: "100%",
            borderRadius: width * 0.14,
            background: "#1A1714",
            padding: width * 0.012,
            overflow: "hidden",
          }}
        >
          {/* Screen */}
          <div
            style={{
              position: "relative",
              width: "100%",
              height: "100%",
              borderRadius: width * 0.125,
              background: "var(--bg-warm)",
              overflow: "hidden",
            }}
          >
            {children}
            {/* Dynamic island */}
            <div
              aria-hidden
              style={{
                position: "absolute",
                top: width * 0.038,
                left: "50%",
                transform: "translateX(-50%)",
                width: width * 0.31,
                height: width * 0.085,
                borderRadius: width * 0.05,
                background: "#0A0907",
                zIndex: 2,
              }}
            />
          </div>
        </div>
      </div>
    </div>
  );
}

/** Mock of the Today screen used inside the Hero iPhone. */
export function TodayMockScreen() {
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        flexDirection: "column",
        padding: "56px 18px 18px",
        gap: 12,
        fontFamily: "var(--font-inter), system-ui",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ fontSize: 11, color: "var(--fg-subtle-aa)", letterSpacing: 1 }}>
          SAT · JUN 28
        </span>
        <span
          style={{
            fontFamily: "var(--font-fraunces), serif",
            fontSize: 22,
            fontWeight: 600,
            color: "var(--fg-primary)",
            letterSpacing: -0.5,
          }}
        >
          Today
        </span>
      </div>

      <MockCard
        kind="voice"
        time="09:14"
        title="Morning coffee at Heden"
        body="Caught the rain just as it hit the window. Reminded me of Tokyo."
      />
      <MockCard
        kind="text"
        time="11:02"
        title="Idea for the wiki"
        body="What if every entity had a tiny graph preview right next to its name?"
      />
      <MockCard
        kind="photo"
        time="13:47"
        title="2 photos · Belém"
        body="Pastel de nata #427. Worth the line."
      />
      <MockCard
        kind="voice"
        time="18:30"
        title="Call with João"
        body="He's moving to Madeira next month. We should talk about Lisbon coworking."
      />

      <div style={{ marginTop: "auto" }}>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            padding: "10px 12px",
            borderRadius: 999,
            background: "var(--surface-white)",
            border: "1px solid var(--border-subtle)",
            boxShadow: "0 6px 18px -8px rgba(43,40,34,0.18)",
          }}
        >
          <div
            style={{
              width: 28,
              height: 28,
              borderRadius: 999,
              background: "var(--accent)",
              display: "grid",
              placeItems: "center",
              color: "var(--bg-warm)",
              fontSize: 14,
              fontWeight: 700,
            }}
          >
            +
          </div>
          <span style={{ fontSize: 13, color: "var(--fg-subtle-aa)", flex: 1 }}>
            What happened?
          </span>
          <div
            style={{
              width: 24,
              height: 24,
              borderRadius: 999,
              background: "var(--recording-red)",
            }}
          />
        </div>
      </div>
    </div>
  );
}

interface MockCardProps {
  kind: "voice" | "text" | "photo";
  time: string;
  title: string;
  body: string;
}

function MockCard({ kind, time, title, body }: MockCardProps) {
  const kindDot: Record<MockCardProps["kind"], string> = {
    voice: "var(--recording-red)",
    text: "var(--accent)",
    photo: "var(--heatmap-mid)",
  };
  return (
    <div
      style={{
        padding: "10px 12px",
        borderRadius: 14,
        background: "var(--surface-white)",
        border: "1px solid var(--border-subtle)",
        display: "flex",
        flexDirection: "column",
        gap: 4,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <span
          style={{
            width: 6,
            height: 6,
            borderRadius: 999,
            background: kindDot[kind],
          }}
        />
        <span style={{ fontSize: 10, color: "var(--fg-subtle-aa)", letterSpacing: 0.6 }}>
          {time}
        </span>
      </div>
      <span
        style={{
          fontSize: 12,
          fontWeight: 600,
          color: "var(--fg-primary)",
          lineHeight: 1.25,
        }}
      >
        {title}
      </span>
      <span
        style={{
          fontSize: 11,
          color: "var(--fg-muted)",
          lineHeight: 1.35,
        }}
      >
        {body}
      </span>
    </div>
  );
}
