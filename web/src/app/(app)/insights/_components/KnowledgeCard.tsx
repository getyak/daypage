import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, memos } from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";
import { BookOpen } from "lucide-react";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db.select({ id: users.id }).from(users).where(eq(users.email, email)).limit(1);
  return rows[0]?.id ?? null;
}

function rangeToMs(range: string): number {
  switch (range) {
    case "7d":  return 7 * 24 * 60 * 60 * 1000;
    case "30d": return 30 * 24 * 60 * 60 * 1000;
    case "90d": return 90 * 24 * 60 * 60 * 1000;
    case "1y":  return 365 * 24 * 60 * 60 * 1000;
    default:    return 30 * 24 * 60 * 60 * 1000;
  }
}

export async function KnowledgeCard({ range }: { range: string }) {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  let daily: { date: string; count: number }[] = [];
  let total = 0;
  let avg = 0;
  let busiest = { date: "", count: 0 };

  if (userId) {
    const since = new Date(Date.now() - rangeToMs(range));
    try {
      const rows = await db
        .select({
          date: sql<string>`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date::text`,
          count: sql<number>`count(*)::int`,
        })
        .from(memos)
        .where(and(eq(memos.user_id, userId), gte(memos.created_at, since)))
        .groupBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`)
        .orderBy(sql`date_trunc('day', ${memos.created_at} AT TIME ZONE 'UTC')::date`);

      daily = rows;
      total = rows.reduce((s, r) => s + r.count, 0);
      const days = rows.length || 1;
      avg = Math.round((total / days) * 10) / 10;
      busiest = rows.reduce((best, r) => (r.count > best.count ? r : best), { date: "", count: 0 });
    } catch {
      // empty
    }
  }

  const maxCount = Math.max(...daily.map((r) => r.count), 1);

  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
    }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 20 }}>
        <BookOpen size={16} strokeWidth={1.7} style={{ color: "var(--accent)" }} />
        <span style={{ fontWeight: 600, fontSize: "0.9375rem" }}>Knowledge Activity</span>
        <span className="ds-section-label" style={{ marginLeft: "auto" }}>{range}</span>
      </div>

      {/* Summary stats */}
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 16, marginBottom: 24 }}>
        <StatBox label="Total memos" value={total} />
        <StatBox label="Daily avg" value={avg} />
        <StatBox
          label="Busiest day"
          value={busiest.count}
          sub={busiest.date ? fmtDate(busiest.date) : "—"}
        />
      </div>

      {/* Bar chart */}
      {daily.length === 0 ? (
        <EmptyState range={range} />
      ) : (
        <BarChart data={daily} maxCount={maxCount} />
      )}
    </div>
  );
}

function StatBox({ label, value, sub }: { label: string; value: number; sub?: string }) {
  return (
    <div style={{
      background: "var(--surface-sunken)",
      borderRadius: "var(--radius-small)",
      padding: "12px 16px",
    }}>
      <div style={{ fontSize: "1.5rem", fontWeight: 700, fontFamily: "var(--font-display)", lineHeight: 1 }}>
        {value}
      </div>
      <div style={{ fontSize: "0.75rem", color: "var(--fg-muted)", marginTop: 4 }}>{label}</div>
      {sub && <div style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

function BarChart({ data, maxCount }: { data: { date: string; count: number }[]; maxCount: number }) {
  const BAR_H = 80;
  const show = data.length > 60 ? data.filter((_, i) => i % 2 === 0) : data;

  return (
    <div>
      <div style={{ display: "flex", alignItems: "flex-end", gap: 3, height: BAR_H, overflow: "hidden" }}>
        {show.map((d) => {
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
                background: pct > 0.6 ? "var(--heatmap-high)" : pct > 0.3 ? "var(--heatmap-mid)" : "var(--heatmap-low)",
                borderRadius: "2px 2px 0 0",
                transition: "height 200ms ease-out",
                cursor: "default",
              }}
            />
          );
        })}
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 6, fontSize: "0.7rem", color: "var(--fg-subtle)" }}>
        <span>{fmtDate(data[0]?.date ?? "")}</span>
        <span>{fmtDate(data[data.length - 1]?.date ?? "")}</span>
      </div>
    </div>
  );
}

function EmptyState({ range }: { range: string }) {
  return (
    <div style={{ textAlign: "center", padding: "32px 0", color: "var(--fg-subtle)", fontSize: "0.875rem" }}>
      No memos recorded in the last {range}. Add some sources to get started.
    </div>
  );
}

function fmtDate(iso: string): string {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  } catch {
    return iso;
  }
}
