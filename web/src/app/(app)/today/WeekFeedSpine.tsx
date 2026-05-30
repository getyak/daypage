"use client";

import { Fragment, useEffect, useState } from "react";
import Link from "next/link";
import type {
  DayItem,
  MonthItem,
  WeekFeedResponse,
  WeekItem,
  YearItem,
} from "@/app/api/today/week-feed/route";

// ─── Timeline — daily / weekly / monthly / yearly compiled feed ──────────────
// One continuous kakejiku spine. Granularity coarsens as we scroll back:
// 本周 BY DAY · 本月 BY WEEK · 今年 BY MONTH · 历年 BY YEAR. All sections share the
// same vertical 0.5px hairline (fixed left coord); the marker shape on the spine
// changes (dot → bar → ring → concentric) to signal the unit without words.
// Design source of truth: .design-handoff/v8/app.jsx:590-720.

// Spine x-coordinate inside a section: section pad-left (22) + left col (52) +
// half the 24px gap (12) = 86. Matches app.jsx:607 `const SPINE = 22 + 52 + 12`.
const SPINE = 86;
// Marker x-offset relative to a row's own coordinate space. Rows are a
// 52px | 1fr grid with a 24px gap, so the gap-center sits at 52 + 12.
const ROW_SPINE = 52 + 12; // 64
const HALO = "0 0 0 4px var(--bg-warm)"; // sits the marker on top of the spine

// ─── shared row scaffold: left-margin label | spine marker | content ─────────

function TimelineRow({
  href,
  leftTop,
  leftBot,
  leftBotFont,
  marker,
  children,
  first,
  last,
}: {
  href: string;
  leftTop: string;
  leftBot?: string;
  leftBotFont: "display" | "serif";
  marker: React.ReactNode;
  children: React.ReactNode;
  first: boolean;
  last: boolean;
}) {
  return (
    <Link
      href={href}
      className="dp-spine-row"
      style={{
        display: "grid",
        gridTemplateColumns: "52px 1fr",
        columnGap: 24,
        paddingTop: first ? 0 : 26,
        paddingBottom: last ? 6 : 26,
        position: "relative",
        textDecoration: "none",
        color: "inherit",
        borderRadius: 8,
      }}
    >
      {/* Left: granularity label */}
      <div style={{ textAlign: "right", paddingTop: 6 }}>
        <div
          style={{
            fontFamily: "var(--font-mono), ui-monospace, monospace",
            fontSize: 9.5,
            fontWeight: 700,
            letterSpacing: "1.8px",
            textTransform: "uppercase",
            color: "var(--fg-subtle)",
          }}
        >
          {leftTop}
        </div>
        {leftBot && (
          <div
            style={{
              fontFamily:
                leftBotFont === "serif"
                  ? "var(--font-serif), Georgia, serif"
                  : "var(--font-display), ui-sans-serif, sans-serif",
              fontSize: 13,
              fontWeight: 600,
              letterSpacing: "-0.1px",
              marginTop: 4,
              lineHeight: 1,
              color: "var(--fg-primary)",
            }}
          >
            {leftBot}
          </div>
        )}
      </div>

      {marker}

      {/* Right: content */}
      <div style={{ paddingLeft: 6, minWidth: 0 }}>{children}</div>
    </Link>
  );
}

function RowTitle({
  children,
  size,
}: {
  children: React.ReactNode;
  size: 20 | 22 | 24;
}) {
  // letterSpacing tightens as the title grows: 20→-0.4, 22→-0.5, 24→-0.6.
  const ls = size === 24 ? -0.6 : size === 22 ? -0.5 : -0.4;
  return (
    <h3
      style={{
        margin: 0,
        fontFamily: "var(--font-serif), Georgia, serif",
        fontSize: size,
        fontWeight: 600,
        lineHeight: size === 24 ? 1.22 : size === 22 ? 1.25 : 1.28,
        letterSpacing: `${ls}px`,
        color: "var(--fg-primary)",
      }}
    >
      {children}
    </h3>
  );
}

function RowLede({ children }: { children: React.ReactNode }) {
  return (
    <p
      style={{
        margin: "10px 0 0",
        fontFamily: "var(--font-body), ui-sans-serif, sans-serif",
        fontSize: 14,
        lineHeight: 1.7,
        letterSpacing: "0.1px",
        color: "var(--fg-primary)",
        opacity: 0.85,
        display: "-webkit-box",
        WebkitLineClamp: 3,
        WebkitBoxOrient: "vertical",
        overflow: "hidden",
      }}
    >
      {children}
    </p>
  );
}

function RowMeta({
  tags,
  right,
}: {
  tags: string[];
  right: React.ReactNode;
}) {
  return (
    <div
      style={{
        marginTop: 14,
        display: "flex",
        flexWrap: "wrap",
        alignItems: "center",
        gap: "6px 9px",
        fontFamily: "var(--font-mono), ui-monospace, monospace",
        fontSize: 9.5,
        fontWeight: 700,
        letterSpacing: "1.6px",
        color: "var(--fg-subtle)",
      }}
    >
      {tags.map((tag, i) => (
        <Fragment key={tag}>
          {i > 0 && <span style={{ opacity: 0.55 }}>·</span>}
          <span>{tag}</span>
        </Fragment>
      ))}
      <span style={{ flex: 1, minWidth: 12 }} />
      <span style={{ color: "var(--fg-muted)", letterSpacing: "1.3px" }}>{right}</span>
    </div>
  );
}

// ─── Markers — shape encodes the granularity ─────────────────────────────────

function DayMarker() {
  // solid 7px accent dot
  return (
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        left: ROW_SPINE - 3,
        top: 11,
        width: 7,
        height: 7,
        borderRadius: 999,
        background: "var(--accent)",
        boxShadow: HALO,
        zIndex: 1,
      }}
    />
  );
}

function WeekMarker() {
  // short horizontal bar — denotes a span, not a point
  return (
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        left: ROW_SPINE - 9,
        top: 13,
        width: 18,
        height: 3,
        borderRadius: 2,
        background: "var(--accent)",
        boxShadow: HALO,
        zIndex: 1,
      }}
    />
  );
}

function MonthMarker() {
  // hollow accent ring (medium)
  return (
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        left: ROW_SPINE - 5,
        top: 9,
        width: 11,
        height: 11,
        borderRadius: 999,
        background: "var(--bg-warm)",
        border: "1.6px solid var(--accent)",
        boxSizing: "border-box",
        boxShadow: "0 0 0 3px var(--bg-warm)",
        zIndex: 1,
      }}
    />
  );
}

function YearMarker() {
  // concentric ring (ring + nested solid dot), largest
  return (
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        left: ROW_SPINE - 7,
        top: 7,
        width: 15,
        height: 15,
        borderRadius: 999,
        background: "var(--bg-warm)",
        border: "1.6px solid var(--accent)",
        boxSizing: "border-box",
        boxShadow: "0 0 0 3px var(--bg-warm)",
        zIndex: 1,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <span
        style={{ width: 5, height: 5, borderRadius: 999, background: "var(--accent)" }}
      />
    </span>
  );
}

// ─── Per-granularity rows ────────────────────────────────────────────────────

function DayRow({ item, first, last }: { item: DayItem; first: boolean; last: boolean }) {
  return (
    <TimelineRow
      href={`/wiki/${item.date_slug}`}
      leftTop={item.day}
      leftBot={item.date}
      leftBotFont="display"
      marker={<DayMarker />}
      first={first}
      last={last}
    >
      <RowTitle size={20}>{item.title}</RowTitle>
      {item.lede && <RowLede>{item.lede}</RowLede>}
      <RowMeta
        tags={item.tags}
        right={
          <>
            <b style={{ color: "var(--fg-muted)", fontWeight: 700 }}>{item.words}</b>{" "}
            <span style={{ opacity: 0.6 }}>WORDS</span>
          </>
        }
      />
    </TimelineRow>
  );
}

function WeekRowItem({ item, first, last }: { item: WeekItem; first: boolean; last: boolean }) {
  return (
    <TimelineRow
      href={`/wiki/weekly/${item.weekNo}`}
      leftTop={`W·${item.weekNo}`}
      leftBot={item.rangeStart}
      leftBotFont="display"
      marker={<WeekMarker />}
      first={first}
      last={last}
    >
      <RowTitle size={20}>{item.title}</RowTitle>
      {item.lede && <RowLede>{item.lede}</RowLede>}
      <RowMeta
        tags={item.tags}
        right={
          <>
            <span style={{ marginRight: 8 }}>{item.range}</span>
            <b style={{ color: "var(--fg-muted)", fontWeight: 700 }}>{item.entries}</b>
            <span style={{ opacity: 0.6, marginLeft: 2 }}>条</span>
          </>
        }
      />
    </TimelineRow>
  );
}

function MonthRow({ item, first, last }: { item: MonthItem; first: boolean; last: boolean }) {
  return (
    <TimelineRow
      href={`/wiki/monthly/${item.year}-${item.label}`}
      leftTop={item.label.slice(0, 3)}
      leftBot={item.year}
      leftBotFont="display"
      marker={<MonthMarker />}
      first={first}
      last={last}
    >
      <RowTitle size={22}>{item.title}</RowTitle>
      {item.lede && <RowLede>{item.lede}</RowLede>}
      <RowMeta
        tags={item.tags}
        right={
          <>
            <b style={{ color: "var(--fg-muted)", fontWeight: 700 }}>{item.entries}</b>
            <span style={{ opacity: 0.6, marginLeft: 2, marginRight: 8 }}>条</span>
            <b style={{ color: "var(--fg-muted)", fontWeight: 700 }}>{item.words}</b>
            <span style={{ opacity: 0.6, marginLeft: 2 }}>字</span>
          </>
        }
      />
    </TimelineRow>
  );
}

function YearRow({ item, first, last }: { item: YearItem; first: boolean; last: boolean }) {
  return (
    <TimelineRow
      href={`/wiki/yearly/${item.label}`}
      leftTop="YEAR"
      leftBot={item.label}
      leftBotFont="serif"
      marker={<YearMarker />}
      first={first}
      last={last}
    >
      <RowTitle size={24}>{item.title}</RowTitle>
      {item.lede && <RowLede>{item.lede}</RowLede>}
      <RowMeta
        tags={item.tags}
        right={
          <>
            <b style={{ color: "var(--fg-muted)", fontWeight: 700 }}>{item.entries}</b>
            <span style={{ opacity: 0.6, marginLeft: 2, marginRight: 8 }}>条</span>
            <b style={{ color: "var(--fg-muted)", fontWeight: 700 }}>{item.words}</b>
            <span style={{ opacity: 0.6, marginLeft: 2 }}>字</span>
          </>
        }
      />
    </TimelineRow>
  );
}

// ─── Section — header hairline + spine + rows ────────────────────────────────

function SectionHeader({ label, sub }: { label: string; sub: string }) {
  return (
    <div
      style={{
        padding: "10px 22px 14px",
        display: "flex",
        alignItems: "baseline",
        gap: 14,
      }}
    >
      <span
        style={{
          fontFamily: "var(--font-display), ui-sans-serif, sans-serif",
          fontSize: 13,
          fontWeight: 700,
          letterSpacing: "1.5px",
          color: "var(--fg-primary)",
        }}
      >
        {label}
      </span>
      <span style={{ flex: 1, height: 0.5, background: "var(--border-subtle)", marginBottom: 2 }} />
      <span
        style={{
          fontFamily: "var(--font-mono), ui-monospace, monospace",
          fontSize: 9.5,
          fontWeight: 700,
          letterSpacing: "1.6px",
          color: "var(--fg-subtle)",
        }}
      >
        {sub}
      </span>
    </div>
  );
}

function TimelineSection({
  label,
  sub,
  count,
  last,
  children,
}: {
  label: string;
  sub: string;
  count: number;
  last?: boolean;
  children: React.ReactNode;
}) {
  return (
    <section style={{ marginBottom: last ? 12 : 22 }}>
      <SectionHeader label={label} sub={sub} />
      <div style={{ position: "relative", padding: "8px 22px 4px" }}>
        {/* spine hairline — fixed left coord, continuous through this section */}
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            left: SPINE,
            top: 18,
            bottom: last ? 18 : 6,
            width: 0.5,
            background: "var(--border-subtle)",
          }}
        />
        {children}
        {last && count > 0 && (
          // hollow-ring terminus closes the whole spine after the final year row
          <div
            aria-hidden="true"
            style={{
              position: "absolute",
              left: SPINE - 3,
              bottom: 8,
              width: 7,
              height: 7,
              borderRadius: 999,
              border: "0.5px solid var(--border-default)",
              background: "var(--bg-warm)",
              boxSizing: "border-box",
            }}
          />
        )}
      </div>
    </section>
  );
}

// ─── Loading skeleton (tombstone) ────────────────────────────────────────────

function SkeletonRow() {
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "52px 1fr",
        columnGap: 24,
        paddingTop: 26,
        paddingBottom: 26,
        position: "relative",
      }}
    >
      <div style={{ textAlign: "right", paddingTop: 6 }}>
        <div className="shimmer" style={{ height: 8, width: 28, marginLeft: "auto", borderRadius: 3 }} />
      </div>
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          left: ROW_SPINE - 3,
          top: 11,
          width: 7,
          height: 7,
          borderRadius: 999,
          background: "var(--border-default)",
          boxShadow: HALO,
          zIndex: 1,
        }}
      />
      <div style={{ paddingLeft: 6 }}>
        <div className="shimmer" style={{ height: 18, width: "70%", borderRadius: 4 }} />
        <div className="shimmer" style={{ height: 12, width: "94%", marginTop: 12, borderRadius: 4 }} />
        <div className="shimmer" style={{ height: 12, width: "60%", marginTop: 6, borderRadius: 4 }} />
      </div>
    </div>
  );
}

function LoadingSpine() {
  return (
    <div style={{ marginTop: 36 }} aria-busy="true" aria-label="本周日记加载中">
      <SectionHeader label="本周" sub="BY DAY" />
      <div style={{ position: "relative", padding: "8px 22px 4px" }}>
        <div
          aria-hidden="true"
          style={{
            position: "absolute",
            left: SPINE,
            top: 18,
            bottom: 6,
            width: 0.5,
            background: "var(--border-subtle)",
          }}
        />
        <SkeletonRow />
        <SkeletonRow />
      </div>
    </div>
  );
}

// ─── main export ─────────────────────────────────────────────────────────────

const EMPTY: WeekFeedResponse = {
  days: [],
  weeks: [],
  months: [],
  years: [],
  synthesized: false,
};

export function WeekFeedSpine() {
  const [data, setData] = useState<WeekFeedResponse>(EMPTY);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    fetch("/api/today/week-feed?limit=7")
      .then((r) => r.json())
      .then((d: Partial<WeekFeedResponse>) => {
        setData({
          days: Array.isArray(d.days) ? d.days : [],
          weeks: Array.isArray(d.weeks) ? d.weeks : [],
          months: Array.isArray(d.months) ? d.months : [],
          years: Array.isArray(d.years) ? d.years : [],
          synthesized: Boolean(d.synthesized),
        });
      })
      .catch(() => {})
      .finally(() => setLoaded(true));
  }, []);

  if (!loaded) return <LoadingSpine />;

  const { days, weeks, months, years } = data;

  if (days.length === 0 && weeks.length === 0 && months.length === 0 && years.length === 0) {
    return (
      <div
        style={{
          padding: "12px 22px 14px",
          fontFamily: "var(--font-body), ui-sans-serif, sans-serif",
          fontSize: 13,
          color: "var(--fg-muted)",
          lineHeight: 1.6,
        }}
      >
        本周还未成稿 — 多记几条今日会自动生成
      </div>
    );
  }

  // The deepest non-empty granularity owns the terminus.
  const lastLevel =
    years.length > 0 ? "year" : months.length > 0 ? "month" : weeks.length > 0 ? "week" : "day";

  return (
    <nav aria-label="时光轴 — 本周 / 本月 / 今年 / 历年" style={{ marginTop: 36 }}>
      {days.length > 0 && (
        <TimelineSection
          label="本周"
          sub={`BY DAY · ${days.length} 条`}
          count={days.length}
          last={lastLevel === "day"}
        >
          {days.map((it, i) => (
            <DayRow key={it.id} item={it} first={i === 0} last={i === days.length - 1} />
          ))}
        </TimelineSection>
      )}

      {weeks.length > 0 && (
        <TimelineSection
          label="本月"
          sub={`BY WEEK · ${weeks.length} 条`}
          count={weeks.length}
          last={lastLevel === "week"}
        >
          {weeks.map((it, i) => (
            <WeekRowItem key={it.id} item={it} first={i === 0} last={i === weeks.length - 1} />
          ))}
        </TimelineSection>
      )}

      {months.length > 0 && (
        <TimelineSection
          label="今年"
          sub={`BY MONTH · ${months.length} 条`}
          count={months.length}
          last={lastLevel === "month"}
        >
          {months.map((it, i) => (
            <MonthRow key={it.id} item={it} first={i === 0} last={i === months.length - 1} />
          ))}
        </TimelineSection>
      )}

      {years.length > 0 && (
        <TimelineSection
          label="历年"
          sub={`BY YEAR · ${years.length} 条`}
          count={years.length}
          last
        >
          {years.map((it, i) => (
            <YearRow key={it.id} item={it} first={i === 0} last={i === years.length - 1} />
          ))}
        </TimelineSection>
      )}
    </nav>
  );
}
