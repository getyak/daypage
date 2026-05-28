"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

type WeekFeedItem = {
  id: string;
  date_slug: string;
  day: string;
  date_display: string;
  title: string;
  lede: string;
  tags: string[];
  word_count: number;
  memo_count: number;
};

export function WeekFeedSpine() {
  const [items, setItems] = useState<WeekFeedItem[]>([]);

  useEffect(() => {
    fetch("/api/today/week-feed?limit=7")
      .then((r) => r.json())
      .then((d: { items: WeekFeedItem[] }) => {
        if (Array.isArray(d.items)) setItems(d.items);
      })
      .catch(() => {});
  }, []);

  return (
    <section
      aria-label="本周成稿"
      style={{
        position: "relative",
        padding: "12px 22px 14px",
      }}
    >
      {/* Section label */}
      <div
        style={{
          fontFamily: "var(--font-family-mono), monospace",
          fontSize: "var(--font-size-mono-xs)",
          textTransform: "uppercase",
          letterSpacing: "0.08em",
          color: "var(--fg-subtle)",
          fontWeight: 600,
          marginBottom: 20,
        }}
      >
        本周 Wiki
      </div>

      {/* Vertical spine line */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          left: 86,
          top: 18,
          bottom: 18,
          width: 0.5,
          background: "var(--border-subtle)",
        }}
      />

      {items.length === 0 ? (
        <EmptyState />
      ) : (
        <>
          {items.map((item, i) => (
            <FeedEntry key={item.id} item={item} isFirst={i === 0} />
          ))}
          {/* Terminus hollow circle */}
          <Terminus />
        </>
      )}
    </section>
  );
}

function FeedEntry({ item, isFirst }: { item: WeekFeedItem; isFirst: boolean }) {
  return (
    <article
      style={{
        display: "grid",
        gridTemplateColumns: "52px 1fr",
        columnGap: 24,
        paddingTop: isFirst ? 0 : 30,
        paddingBottom: 30,
        position: "relative",
      }}
    >
      {/* Spine dot */}
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          left: 79,
          top: isFirst ? 10 : 40,
          width: 7,
          height: 7,
          borderRadius: "50%",
          background: "var(--accent)",
          boxShadow: "0 0 0 4px var(--bg-warm)",
          zIndex: 1,
        }}
      />

      {/* Left column — date tag */}
      <div
        style={{
          textAlign: "right",
          paddingRight: 0,
          userSelect: "none",
        }}
      >
        <div
          style={{
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: 9.5,
            fontWeight: 700,
            lineHeight: 1.8,
            textTransform: "uppercase",
            letterSpacing: "0.06em",
            color: "var(--fg-muted)",
          }}
        >
          {item.day}
        </div>
        <div
          style={{
            fontFamily: "var(--font-family-mono), monospace",
            fontSize: 14,
            fontWeight: 600,
            color: "var(--fg-primary)",
            lineHeight: 1.2,
          }}
        >
          {item.date_display}
        </div>
      </div>

      {/* Right column — content */}
      <Link
        href={`/wiki/${item.date_slug}`}
        style={{ textDecoration: "none", color: "inherit" }}
      >
        <h3
          style={{
            margin: "0 0 8px",
            fontFamily: `"Fraunces", var(--font-family-serif), Georgia, serif`,
            fontSize: 21,
            fontWeight: 600,
            lineHeight: 1.26,
            letterSpacing: "-0.4px",
            color: "var(--fg-primary)",
          }}
        >
          {item.title}
        </h3>
        <p
          style={{
            margin: "0 0 10px",
            fontSize: 14.5,
            lineHeight: 1.7,
            color: "var(--fg-primary)",
            opacity: 0.86,
            display: "-webkit-box",
            WebkitLineClamp: 3,
            WebkitBoxOrient: "vertical",
            overflow: "hidden",
          }}
        >
          {item.lede}
        </p>
        {/* Footer row */}
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
          }}
        >
          <span
            style={{
              fontFamily: "var(--font-family-mono), monospace",
              fontSize: "var(--font-size-mono-xs)",
              textTransform: "uppercase",
              letterSpacing: "0.05em",
              color: "var(--fg-subtle)",
            }}
          >
            {item.tags.join(" · ")}
          </span>
          <span
            style={{
              fontFamily: "var(--font-family-mono), monospace",
              fontSize: "var(--font-size-mono-xs)",
              textTransform: "uppercase",
              letterSpacing: "0.05em",
              color: "var(--fg-subtle)",
              flexShrink: 0,
              marginLeft: 12,
            }}
          >
            {item.word_count} WORDS
          </span>
        </div>
      </Link>
    </article>
  );
}

function EmptyState() {
  return (
    <div
      style={{
        paddingLeft: 76,
        paddingTop: 8,
        paddingBottom: 24,
        fontFamily: "var(--font-family-body), sans-serif",
        fontSize: 14,
        lineHeight: 1.6,
        color: "var(--fg-subtle)",
      }}
    >
      本周还未成稿 — 多记几条今日会自动生成
    </div>
  );
}

function Terminus() {
  return (
    <div
      aria-hidden="true"
      style={{
        position: "absolute",
        left: 79,
        bottom: 14,
        width: 7,
        height: 7,
        borderRadius: "50%",
        border: "0.5px solid var(--border-default)",
        background: "var(--bg-warm)",
      }}
    />
  );
}
