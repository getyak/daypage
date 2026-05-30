"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import type { MarkerType, WeekFeedItem } from "@/app/api/today/week-feed/route";

// ─── helpers ────────────────────────────────────────────────────────────────

function dayAbbr(dateSlug: string): string {
  const days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
  const d = new Date(dateSlug + "T00:00:00");
  return days[d.getDay()] ?? "---";
}

function dateDisplay(dateSlug: string): string {
  // "2026-05-27" → "05 · 27"
  const parts = dateSlug.split("-");
  if (parts.length < 3) return dateSlug;
  return `${parts[1]} · ${parts[2]}`;
}

// ─── sub-components ──────────────────────────────────────────────────────────

const SPINE_X = 86; // vertical spine x-coordinate (px)
const HALO = "0 0 0 4px var(--surface-white)"; // sits the marker on top of the spine

// Four timeline markers, all in accent brown, each horizontally centered on the
// spine. Vertical anchor matches the original SpineDot (top:2 first, else 32).
function SpineMarker({ type, isFirst }: { type: MarkerType; isFirst: boolean }) {
  const baseTop = isFirst ? 2 : 30 + 2; // anchor row of the original 7px dot

  if (type === "week") {
    // Horizontal bar: 14×3, centered on spine, vertically nudged onto the dot row.
    const w = 14;
    const h = 3;
    return (
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          left: SPINE_X - w / 2,
          top: baseTop + (7 - h) / 2,
          width: w,
          height: h,
          borderRadius: 1.5,
          background: "var(--accent)",
          boxShadow: HALO,
          zIndex: 1,
        }}
      />
    );
  }

  if (type === "month") {
    // Hollow ring: 9×9 white fill with accent stroke.
    const s = 9;
    return (
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          left: SPINE_X - s / 2,
          top: baseTop + (7 - s) / 2,
          width: s,
          height: s,
          borderRadius: "50%",
          background: "var(--surface-white)",
          border: "1.5px solid var(--accent)",
          boxSizing: "border-box",
          boxShadow: HALO,
          zIndex: 1,
        }}
      />
    );
  }

  if (type === "year") {
    // Concentric circle: 9×9 ring + nested 3×3 solid accent dot.
    const s = 9;
    const inner = 3;
    return (
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          left: SPINE_X - s / 2,
          top: baseTop + (7 - s) / 2,
          width: s,
          height: s,
          borderRadius: "50%",
          background: "var(--surface-white)",
          border: "1.5px solid var(--accent)",
          boxSizing: "border-box",
          boxShadow: HALO,
          zIndex: 1,
        }}
      >
        <span
          style={{
            position: "absolute",
            left: "50%",
            top: "50%",
            width: inner,
            height: inner,
            transform: "translate(-50%, -50%)",
            borderRadius: "50%",
            background: "var(--accent)",
          }}
        />
      </span>
    );
  }

  // "day" (default): solid 7×7 accent dot.
  const s = 7;
  return (
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        left: SPINE_X - s / 2,
        top: baseTop,
        width: s,
        height: s,
        borderRadius: "50%",
        background: "var(--accent)",
        boxShadow: HALO,
        zIndex: 1,
      }}
    />
  );
}

function FeedEntry({ item, index }: { item: WeekFeedItem; index: number }) {
  const isFirst = index === 0;
  const day = item.day || dayAbbr(item.date_slug);
  const display = item.date_display || dateDisplay(item.date_slug);

  return (
    <article style={{ position: "relative" }}>
      <SpineMarker type={item.marker_type ?? "day"} isFirst={isFirst} />
      <Link
        href={`/wiki/${item.date_slug}`}
        style={{ textDecoration: "none", color: "inherit", display: "block" }}
      >
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "52px 1fr",
            columnGap: 24,
            paddingTop: isFirst ? 0 : 30,
            paddingBottom: 30,
          }}
        >
          {/* Left: date tag */}
          <div
            style={{
              textAlign: "right",
              paddingTop: 2,
            }}
          >
            <div
              style={{
                fontFamily: "var(--font-mono), var(--font-family-mono), monospace",
                fontSize: 10,
                fontWeight: 700,
                lineHeight: 1.8,
                letterSpacing: "0.08em",
                textTransform: "uppercase",
                color: "var(--fg-muted)",
              }}
            >
              {day}
            </div>
            <div
              style={{
                fontFamily: "var(--font-mono), var(--font-family-mono), monospace",
                fontSize: 14,
                fontWeight: 600,
                lineHeight: 1.2,
                color: "var(--fg-primary)",
              }}
            >
              {display}
            </div>
          </div>

          {/* Right: content */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <h3
              style={{
                fontFamily: "var(--font-serif), Georgia, serif",
                fontSize: 21,
                fontWeight: 500,
                lineHeight: 1.26,
                letterSpacing: "-0.4px",
                margin: 0,
                color: "var(--fg-primary)",
              }}
            >
              {item.title}
            </h3>

            {item.lede && (
              <p
                style={{
                  margin: 0,
                  fontSize: 14.5,
                  lineHeight: 1.7,
                  opacity: 0.86,
                  color: "var(--fg-secondary)",
                  display: "-webkit-box",
                  WebkitLineClamp: 3,
                  WebkitBoxOrient: "vertical",
                  overflow: "hidden",
                }}
              >
                {item.lede}
              </p>
            )}

            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
                marginTop: 4,
              }}
            >
              <span
                style={{
                  fontFamily: "var(--font-mono), var(--font-family-mono), monospace",
                  fontSize: 10,
                  fontWeight: 600,
                  letterSpacing: "0.06em",
                  textTransform: "uppercase",
                  color: "var(--fg-muted)",
                }}
              >
                {item.tags.join(" · ")}
              </span>
              <span
                style={{
                  fontFamily: "var(--font-mono), var(--font-family-mono), monospace",
                  fontSize: 10,
                  fontWeight: 600,
                  letterSpacing: "0.06em",
                  textTransform: "uppercase",
                  color: "var(--fg-muted)",
                }}
              >
                {item.word_count} WORDS
              </span>
            </div>
          </div>
        </div>
      </Link>
    </article>
  );
}

function Terminus() {
  return (
    <div
      aria-hidden="true"
      style={{
        position: "absolute",
        left: 86 - 3 - 4,
        bottom: 18,
        width: 7,
        height: 7,
        borderRadius: "50%",
        background: "transparent",
        border: "1px solid var(--accent)",
        boxSizing: "border-box",
      }}
    />
  );
}

// ─── main export ─────────────────────────────────────────────────────────────

export function WeekFeedSpine() {
  const [items, setItems] = useState<WeekFeedItem[]>([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    fetch("/api/today/week-feed?limit=7")
      .then((r) => r.json())
      .then((d: { items: WeekFeedItem[] }) => {
        if (Array.isArray(d.items)) setItems(d.items);
      })
      .catch(() => {})
      .finally(() => setLoaded(true));
  }, []);

  if (!loaded) return null;

  if (items.length === 0) {
    return (
      <div
        style={{
          padding: "12px 22px 14px",
          fontFamily: "var(--font-family-body), ui-sans-serif, sans-serif",
          fontSize: 13,
          color: "var(--fg-muted)",
          lineHeight: 1.6,
        }}
      >
        本周还未成稿 — 多记几条今日会自动生成
      </div>
    );
  }

  return (
    <section
      aria-label="本周日记"
      style={{
        position: "relative",
        padding: "12px 22px 14px",
      }}
    >
      {/* Vertical spine line */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          left: 86,
          top: 18,
          bottom: 18,
          width: 1,
          background: "var(--accent-border)",
        }}
      />

      {items.map((item, i) => (
        <FeedEntry key={item.id} item={item} index={i} />
      ))}

      <Terminus />
    </section>
  );
}
