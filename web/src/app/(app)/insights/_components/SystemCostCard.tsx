import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, prompt_log } from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";
import { Cpu } from "lucide-react";
import { Sparkline } from "@/components/ui";

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

// Rough cost estimate per token (USD): input $3/M, output $15/M
function estimateCost(tokensIn: number, tokensOut: number): number {
  return (tokensIn * 3 + tokensOut * 15) / 1_000_000;
}

function fmtCost(usd: number): string {
  if (usd < 0.01) return "<$0.01";
  return `$${usd.toFixed(2)}`;
}

export async function SystemCostCard({ range }: { range: string }) {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  type DailyRow = { date: string; calls: number; tokens_in: number; tokens_out: number };
  let daily: DailyRow[] = [];
  let totalCalls = 0;
  let totalTokensIn = 0;
  let totalTokensOut = 0;
  let estimatedCost = 0;

  if (userId) {
    const since = new Date(Date.now() - rangeToMs(range));
    try {
      const rows = await db
        .select({
          date: sql<string>`date_trunc('day', ${prompt_log.created_at} AT TIME ZONE 'UTC')::date::text`,
          calls: sql<number>`count(*)::int`,
          tokens_in: sql<number>`coalesce(sum(${prompt_log.tokens_in}), 0)::int`,
          tokens_out: sql<number>`coalesce(sum(${prompt_log.tokens_out}), 0)::int`,
        })
        .from(prompt_log)
        .where(and(eq(prompt_log.user_id, userId), gte(prompt_log.created_at, since)))
        .groupBy(sql`date_trunc('day', ${prompt_log.created_at} AT TIME ZONE 'UTC')::date`)
        .orderBy(sql`date_trunc('day', ${prompt_log.created_at} AT TIME ZONE 'UTC')::date`);

      daily = rows;
      totalCalls = rows.reduce((s, r) => s + r.calls, 0);
      totalTokensIn = rows.reduce((s, r) => s + (r.tokens_in ?? 0), 0);
      totalTokensOut = rows.reduce((s, r) => s + (r.tokens_out ?? 0), 0);
      estimatedCost = estimateCost(totalTokensIn, totalTokensOut);
    } catch {
      // empty
    }
  }

  const callsSparkline = daily.map((d) => d.calls);

  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
    }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 20 }}>
        <Cpu size={16} strokeWidth={1.7} style={{ color: "var(--accent)" }} />
        <span style={{ fontWeight: 600, fontSize: "0.9375rem" }}>System &amp; Cost</span>
        <span className="ds-section-label" style={{ marginLeft: "auto" }}>{range}</span>
      </div>

      {/* Summary stats */}
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr 1fr", gap: 16, marginBottom: 24 }}>
        <StatBox label="API calls" value={totalCalls.toLocaleString()} />
        <StatBox label="Est. cost" value={fmtCost(estimatedCost)} highlight />
        <StatBox label="Tokens in" value={fmtTokens(totalTokensIn)} />
        <StatBox label="Tokens out" value={fmtTokens(totalTokensOut)} />
      </div>

      {/* Sparkline trend */}
      {callsSparkline.length >= 2 ? (
        <div>
          <div style={{ fontSize: "0.75rem", color: "var(--fg-subtle)", marginBottom: 6 }}>API calls per day</div>
          <Sparkline values={callsSparkline} w={560} h={40} color="var(--accent)" fill />
          <div style={{ display: "flex", justifyContent: "space-between", fontSize: "0.7rem", color: "var(--fg-subtle)", marginTop: 4 }}>
            <span>{fmtDate(daily[0]?.date ?? "")}</span>
            <span>{fmtDate(daily[daily.length - 1]?.date ?? "")}</span>
          </div>
        </div>
      ) : (
        <EmptyState />
      )}

      <p style={{ fontSize: "0.7rem", color: "var(--fg-subtle)", marginTop: 16, marginBottom: 0 }}>
        * Cost estimated at $3/M input tokens, $15/M output tokens. Actual billing may differ.
      </p>
    </div>
  );
}

function StatBox({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div style={{
      background: highlight ? "var(--accent-soft)" : "var(--surface-sunken)",
      borderRadius: "var(--radius-small)",
      padding: "12px 16px",
      border: highlight ? "1px solid var(--accent-border)" : "none",
    }}>
      <div style={{
        fontSize: "1.375rem",
        fontWeight: 700,
        fontFamily: "var(--font-display)",
        lineHeight: 1,
        color: highlight ? "var(--accent)" : "var(--fg-primary)",
      }}>
        {value}
      </div>
      <div style={{ fontSize: "0.75rem", color: "var(--fg-muted)", marginTop: 4 }}>{label}</div>
    </div>
  );
}

function EmptyState() {
  return (
    <div style={{ textAlign: "center", padding: "24px 0", color: "var(--fg-subtle)", fontSize: "0.875rem" }}>
      No AI usage recorded in this period.
    </div>
  );
}

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return n.toString();
}

function fmtDate(iso: string): string {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  } catch {
    return iso;
  }
}
