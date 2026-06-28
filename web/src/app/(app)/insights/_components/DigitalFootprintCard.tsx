import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, memos, pages, annotations } from "@/lib/db/schema";
import { eq, and, gte, sql, count } from "drizzle-orm";
import { Footprints } from "lucide-react";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

function rangeToMs(range: string): number {
  switch (range) {
    case "7d":  return 7  * 24 * 60 * 60 * 1000;
    case "30d": return 30 * 24 * 60 * 60 * 1000;
    case "90d": return 90 * 24 * 60 * 60 * 1000;
    case "1y":  return 365 * 24 * 60 * 60 * 1000;
    default:    return 30 * 24 * 60 * 60 * 1000;
  }
}

function fmtDate(iso: string): string {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  } catch {
    return iso;
  }
}

function rangeLabel(range: string): string {
  switch (range) {
    case "7d":  return "7 days";
    case "30d": return "30 days";
    case "90d": return "90 days";
    case "1y":  return "1 year";
    default:    return range;
  }
}

export async function DigitalFootprintCard({ range }: { range: string }) {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  // Lifetime aggregates
  let lifetimeMemos = 0;
  let lifetimePages = 0;
  let lifetimeAnnotations = 0;

  // Range-scoped: active days + heatmap
  let daysActive = 0;
  let heatmap: { date: string; count: number }[] = [];

  if (userId) {
    const since = new Date(Date.now() - rangeToMs(range));

    try {
      // Lifetime counts
      const [memoCount] = await db
        .select({ n: count() })
        .from(memos)
        .where(eq(memos.user_id, userId));
      lifetimeMemos = memoCount?.n ?? 0;

      const [pageCount] = await db
        .select({ n: count() })
        .from(pages)
        .where(eq(pages.user_id, userId));
      lifetimePages = pageCount?.n ?? 0;

      const [annCount] = await db
        .select({ n: count() })
        .from(annotations)
        .where(eq(annotations.user_id, userId));
      lifetimeAnnotations = annCount?.n ?? 0;

      // Range: memos per day (heatmap)
      const rows = await db
        .select({
          date: sql<string>`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date::text`,
          count: sql<number>`count(*)::int`,
        })
        .from(memos)
        .where(and(eq(memos.user_id, userId), gte(memos.created_at, since)))
        .groupBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`)
        .orderBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`);

      heatmap = rows;
      daysActive = rows.filter((r) => r.count > 0).length;
    } catch {
      // empty — DB unavailable or no data
    }
  }

  const maxCount = Math.max(...heatmap.map((r) => r.count), 1);

  return (
    <div
      style={{
        background: "var(--surface-white)",
        borderRadius: "var(--radius-card)",
        border: "1px solid var(--accent-border)",
        padding: 24,
      }}
    >
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 20 }}>
        <Footprints size={16} strokeWidth={1.7} style={{ color: "var(--accent)" }} />
        <span style={{ fontWeight: 600, fontSize: "0.9375rem" }}>Digital Footprint</span>
        <span className="ds-section-label" style={{ marginLeft: "auto" }}>{range}</span>
      </div>

      {/* Lifetime summary stats */}
      <div style={{ marginBottom: 8 }}>
        <div className="ds-section-label" style={{ marginBottom: 10 }}>Lifetime totals</div>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 16 }}>
          <StatBox label="Total memos" value={lifetimeMemos} />
          <StatBox label="Total pages" value={lifetimePages} />
          <StatBox label="Total annotations" value={lifetimeAnnotations} />
        </div>
      </div>

      {/* Range activity */}
      <div style={{ marginTop: 20 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 14 }}>
          <div className="ds-section-label">Life Activity</div>
          <span style={{ fontSize: "0.75rem", color: "var(--fg-subtle)" }}>
            memo activity — last {rangeLabel(range)}
          </span>
          <span
            style={{
              marginLeft: "auto",
              fontSize: "0.8125rem",
              color: "var(--accent)",
              fontWeight: 600,
            }}
          >
            {daysActive} day{daysActive !== 1 ? "s" : ""} active
          </span>
        </div>

        {heatmap.length === 0 ? (
          <EmptyState range={range} />
        ) : (
          <CalendarHeatmap data={heatmap} maxCount={maxCount} range={range} />
        )}
      </div>
    </div>
  );
}

function StatBox({ label, value }: { label: string; value: number }) {
  return (
    <div
      style={{
        background: "var(--surface-sunken)",
        borderRadius: "var(--radius-small)",
        padding: "12px 16px",
      }}
    >
      <div
        style={{
          fontSize: "1.5rem",
          fontWeight: 700,
          fontFamily: "var(--font-display)",
          lineHeight: 1,
        }}
      >
        {value.toLocaleString()}
      </div>
      <div style={{ fontSize: "0.75rem", color: "var(--fg-muted)", marginTop: 4 }}>
        {label}
      </div>
    </div>
  );
}

function CalendarHeatmap({
  data,
  maxCount,
  range,
}: {
  data: { date: string; count: number }[];
  maxCount: number;
  range: string;
}) {
  // For 1y range, render week-columns (GitHub-style); otherwise render day bars
  if (range === "1y") {
    return <WeekHeatmap data={data} maxCount={maxCount} />;
  }
  return <DayBars data={data} maxCount={maxCount} />;
}

function DayBars({
  data,
  maxCount,
}: {
  data: { date: string; count: number }[];
  maxCount: number;
}) {
  const BAR_H = 80;
  return (
    <div>
      <div
        style={{
          display: "flex",
          alignItems: "flex-end",
          gap: 3,
          height: BAR_H,
          overflow: "hidden",
        }}
      >
        {data.map((d) => {
          const pct = d.count / maxCount;
          const h = Math.max(2, Math.round(pct * BAR_H));
          return (
            <div
              key={d.date}
              title={`${fmtDate(d.date)}: ${d.count} memo${d.count !== 1 ? "s" : ""}`}
              style={{
                flex: 1,
                minWidth: 3,
                height: h,
                background:
                  pct > 0.6
                    ? "var(--heatmap-high)"
                    : pct > 0.3
                    ? "var(--heatmap-mid)"
                    : "var(--heatmap-low)",
                borderRadius: "2px 2px 0 0",
                cursor: "default",
              }}
            />
          );
        })}
      </div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          marginTop: 6,
          fontSize: "0.7rem",
          color: "var(--fg-subtle)",
        }}
      >
        <span>{fmtDate(data[0]?.date ?? "")}</span>
        <span>{fmtDate(data[data.length - 1]?.date ?? "")}</span>
      </div>
    </div>
  );
}

function WeekHeatmap({
  data,
  maxCount,
}: {
  data: { date: string; count: number }[];
  maxCount: number;
}) {
  // Build a map date→count
  const byDate = new Map<string, number>(data.map((d) => [d.date, d.count]));

  // Build full year grid: 53 weeks × 7 days
  const today = new Date();
  const yearAgo = new Date(today.getTime() - 365 * 24 * 60 * 60 * 1000);
  // Start on Sunday of the week containing yearAgo
  const startDate = new Date(yearAgo);
  startDate.setDate(startDate.getDate() - startDate.getDay());

  const CELL = 11;
  const GAP = 3;

  const weeks: { date: string; count: number }[][] = [];
  let current = new Date(startDate);

  while (current <= today) {
    const week: { date: string; count: number }[] = [];
    for (let d = 0; d < 7; d++) {
      const iso = current.toISOString().slice(0, 10);
      week.push({ date: iso, count: byDate.get(iso) ?? 0 });
      current.setDate(current.getDate() + 1);
    }
    weeks.push(week);
  }

  function cellColor(count: number): string {
    if (count === 0) return "var(--surface-sunken)";
    const pct = count / maxCount;
    if (pct > 0.6) return "var(--heatmap-high)";
    if (pct > 0.3) return "var(--heatmap-mid)";
    return "var(--heatmap-low)";
  }

  return (
    <div style={{ overflowX: "auto", paddingBottom: 4 }}>
      <div style={{ display: "flex", gap: GAP, alignItems: "flex-start" }}>
        {weeks.map((week, wi) => (
          <div key={wi} style={{ display: "flex", flexDirection: "column", gap: GAP }}>
            {week.map((cell) => (
              <div
                key={cell.date}
                title={`${fmtDate(cell.date)}: ${cell.count} memo${cell.count !== 1 ? "s" : ""}`}
                style={{
                  width: CELL,
                  height: CELL,
                  borderRadius: 2,
                  background: cellColor(cell.count),
                  cursor: "default",
                }}
              />
            ))}
          </div>
        ))}
      </div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          marginTop: 8,
          fontSize: "0.7rem",
          color: "var(--fg-subtle)",
        }}
      >
        <span>{fmtDate(yearAgo.toISOString().slice(0, 10))}</span>
        <span>{fmtDate(today.toISOString().slice(0, 10))}</span>
      </div>
    </div>
  );
}

function EmptyState({ range }: { range: string }) {
  return (
    <div
      style={{
        textAlign: "center",
        padding: "32px 0",
        color: "var(--fg-subtle)",
        fontSize: "0.875rem",
      }}
    >
      No activity recorded in the last {rangeLabel(range)}.
    </div>
  );
}
