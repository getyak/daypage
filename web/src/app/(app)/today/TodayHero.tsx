"use client";

import { useEffect, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import { Dot } from "@/components/ui/Dot";

type HeaderData = {
  weekday: string;
  weekday_zh: string;
  date_iso: string;
  date_display: string;
  memo_count: number;
  weather: {
    temp: number | null;
    condition: string | null;
    icon: string | null;
  };
  location: string | null;
};

function SunIcon() {
  return (
    <svg
      aria-hidden="true"
      width={11}
      height={11}
      viewBox="0 0 11 11"
      fill="none"
      style={{ display: "inline-block", verticalAlign: "middle", flexShrink: 0 }}
    >
      <circle cx="5.5" cy="5.5" r="2" stroke="currentColor" strokeWidth="1.2" />
      <line x1="5.5" y1="0.5" x2="5.5" y2="2" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="5.5" y1="9" x2="5.5" y2="10.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="0.5" y1="5.5" x2="2" y2="5.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="9" y1="5.5" x2="10.5" y2="5.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="1.93" y1="1.93" x2="2.99" y2="2.99" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="8.01" y1="8.01" x2="9.07" y2="9.07" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="9.07" y1="1.93" x2="8.01" y2="2.99" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
      <line x1="2.99" y1="8.01" x2="1.93" y2="9.07" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
    </svg>
  );
}

const metaStyle: React.CSSProperties = {
  fontFamily: "var(--font-jetbrains-mono), ui-monospace, monospace",
  fontSize: 11,
  letterSpacing: 1.2,
  textTransform: "uppercase" as const,
  color: "var(--fg-muted)",
  marginTop: 12,
  display: "flex",
  alignItems: "center",
  gap: 8,
  flexWrap: "wrap" as const,
};

export function TodayHero() {
  const [data, setData] = useState<HeaderData | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    fetch("/api/today/header")
      .then((r) => {
        if (!r.ok) throw new Error("fetch failed");
        return r.json();
      })
      .then((d: HeaderData) => setData(d))
      .catch(() => setError(true));
  }, []);

  // Loading state
  if (!data && !error) {
    return (
      <div style={{ paddingTop: 4, paddingBottom: 18 }}>
        <div
          style={{
            height: 56,
            width: 180,
            borderRadius: 6,
            background: "var(--surface-sunken)",
            marginBottom: 16,
          }}
        />
        <div style={metaStyle}>LOADING…</div>
      </div>
    );
  }

  // Error / fallback state — keep the serif hero anchored with a calm
  // "今天" instead of a bare em-dash, and replace the meaningless
  // "MAY 28 · — · — · —" string with a single quiet retry affordance.
  if (error || !data) {
    return (
      <div style={{ paddingTop: 4, paddingBottom: 18 }}>
        <h1
          style={{
            fontFamily: "var(--font-serif)",
            fontSize: 56,
            lineHeight: 1,
            letterSpacing: -0.8,
            fontWeight: 600,
            color: "var(--fg-primary)",
            margin: 0,
          }}
        >
          今天
        </h1>
        <div style={metaStyle}>
          <span>暂时无法加载今日信息</span>
          <Dot />
          <button
            type="button"
            onClick={() => {
              setError(false);
              setData(null);
              fetch("/api/today/header")
                .then((r) => {
                  if (!r.ok) throw new Error("fetch failed");
                  return r.json();
                })
                .then((d: HeaderData) => setData(d))
                .catch(() => setError(true));
            }}
            style={{
              font: "inherit",
              letterSpacing: "inherit",
              textTransform: "inherit",
              color: "var(--accent)",
              background: "none",
              border: "none",
              padding: 0,
              cursor: "pointer",
            }}
          >
            重试
          </button>
        </div>
      </div>
    );
  }

  const { weekday_zh, date_display, memo_count, weather } = data;

  const weatherTemp = weather.temp !== null ? `${weather.temp}°` : null;

  return (
    <HeroBody
      weekdayZh={weekday_zh}
      dateDisplay={date_display}
      memoCount={memo_count}
      weatherTemp={weatherTemp}
      location={data.location}
    />
  );
}

function HeroBody({
  weekdayZh,
  dateDisplay,
  memoCount,
  weatherTemp,
  location,
}: {
  weekdayZh: string;
  dateDisplay: string;
  memoCount: number;
  weatherTemp: string | null;
  location: string | null;
}) {
  const reduced = useReducedMotion();
  return (
    <motion.div
      initial="hidden"
      animate="show"
      variants={
        reduced
          ? undefined
          : {
              hidden: {},
              show: { transition: { staggerChildren: 0.06 } },
            }
      }
      style={{ paddingTop: 4, paddingBottom: 18 }}
    >
      <motion.h1
        variants={
          reduced
            ? undefined
            : {
                hidden: { opacity: 0, y: 8 },
                show: {
                  opacity: 1,
                  y: 0,
                  transition: { duration: 0.42, ease: [0.22, 1, 0.36, 1] },
                },
              }
        }
        style={{
          fontFamily: "var(--font-serif)",
          fontSize: 56,
          lineHeight: 1,
          letterSpacing: -0.8,
          fontWeight: 600,
          color: "var(--fg-primary)",
          margin: 0,
        }}
      >
        {weekdayZh}
      </motion.h1>

      <motion.div
        variants={
          reduced
            ? undefined
            : {
                hidden: { opacity: 0, y: 4 },
                show: {
                  opacity: 1,
                  y: 0,
                  transition: { duration: 0.32, ease: [0.22, 1, 0.36, 1] },
                },
              }
        }
        style={metaStyle}
      >
        {dateDisplay}
        <Dot />
        <span style={{ color: "var(--accent)" }}>
          {memoCount} {memoCount === 1 ? "NOTE" : "NOTES"}
        </span>
        {weatherTemp && (
          <>
            <Dot />
            <span style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
              <SunIcon />
              {weatherTemp}
            </span>
          </>
        )}
        {location && (
          <>
            <Dot />
            {location}
          </>
        )}
      </motion.div>
    </motion.div>
  );
}
