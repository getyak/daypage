import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, prompt_log, activities } from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";
import { Code2, Plug } from "lucide-react";

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

export async function DevActivityCard({ range }: { range: string }) {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  let claudeCodeCalls = 0;
  let claudeCodeTokensIn = 0;
  let claudeCodeTokensOut = 0;

  // "claude_code" activities: verbs that indicate code work
  let devActivities: { verb: string; count: number }[] = [];

  if (userId) {
    const since = new Date(Date.now() - rangeToMs(range));
    try {
      // prompt_log rows where kind = 'claude_code' (Claude Code MCP sessions)
      const logRows = await db
        .select({
          calls: sql<number>`count(*)::int`,
          tokens_in: sql<number>`coalesce(sum(${prompt_log.tokens_in}), 0)::int`,
          tokens_out: sql<number>`coalesce(sum(${prompt_log.tokens_out}), 0)::int`,
        })
        .from(prompt_log)
        .where(
          and(
            eq(prompt_log.user_id, userId),
            eq(prompt_log.kind, "claude_code"),
            gte(prompt_log.created_at, since)
          )
        );

      claudeCodeCalls = logRows[0]?.calls ?? 0;
      claudeCodeTokensIn = logRows[0]?.tokens_in ?? 0;
      claudeCodeTokensOut = logRows[0]?.tokens_out ?? 0;

      // Activities that look like dev actions (create_page, compile, etc.)
      const actRows = await db
        .select({
          verb: activities.verb,
          count: sql<number>`count(*)::int`,
        })
        .from(activities)
        .where(and(eq(activities.user_id, userId), gte(activities.created_at, since)))
        .groupBy(activities.verb)
        .orderBy(sql`count(*) desc`)
        .limit(8);

      devActivities = actRows;
    } catch {
      // empty
    }
  }

  const hasData = claudeCodeCalls > 0;

  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
    }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 20 }}>
        <Code2 size={16} strokeWidth={1.7} style={{ color: "var(--accent)" }} />
        <span style={{ fontWeight: 600, fontSize: "0.9375rem" }}>Development Activity</span>
        <span className="ds-section-label" style={{ marginLeft: "auto" }}>{range}</span>
      </div>

      {!hasData ? (
        <Placeholder />
      ) : (
        <div>
          {/* Claude Code stats */}
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 16, marginBottom: 24 }}>
            <StatBox label="CC sessions" value={claudeCodeCalls.toLocaleString()} />
            <StatBox label="Tokens in" value={fmtTokens(claudeCodeTokensIn)} />
            <StatBox label="Tokens out" value={fmtTokens(claudeCodeTokensOut)} />
          </div>

          {/* Activity breakdown */}
          {devActivities.length > 0 && (
            <div>
              <div style={{ fontSize: "0.75rem", color: "var(--fg-subtle)", marginBottom: 10 }}>Activity breakdown</div>
              <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                {devActivities.map(({ verb, count }) => {
                  const maxCount = devActivities[0]?.count ?? 1;
                  const pct = Math.round((count / maxCount) * 100);
                  return (
                    <div key={verb} style={{ display: "flex", alignItems: "center", gap: 10 }}>
                      <span style={{ fontSize: "0.8125rem", color: "var(--fg-muted)", minWidth: 140, flexShrink: 0 }}>
                        {verb.replace(/_/g, " ")}
                      </span>
                      <div style={{ flex: 1, height: 6, background: "var(--surface-sunken)", borderRadius: 3 }}>
                        <div style={{
                          width: `${pct}%`,
                          height: "100%",
                          background: "var(--accent)",
                          borderRadius: 3,
                          transition: "width 300ms ease-out",
                        }} />
                      </div>
                      <span style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)", minWidth: 28, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
                        {count}
                      </span>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function Placeholder() {
  return (
    <div style={{
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 12,
      padding: "32px 16px",
      textAlign: "center",
      background: "var(--surface-sunken)",
      borderRadius: "var(--radius-small)",
    }}>
      <Plug size={28} strokeWidth={1.4} style={{ color: "var(--fg-subtle)", opacity: 0.5 }} />
      <p style={{ margin: 0, fontWeight: 500, color: "var(--fg-primary)" }}>
        Connect Claude Code to see Dev Activity
      </p>
      <p style={{ margin: 0, fontSize: "0.8125rem", color: "var(--fg-subtle)", maxWidth: 320 }}>
        Install the DayPage MCP server in Claude Code to track AI-assisted development sessions here.
        See <code style={{ fontSize: "0.75rem", background: "var(--surface-white)", padding: "1px 4px", borderRadius: 4 }}>docs/claude-code-hook.md</code> to get started.
      </p>
    </div>
  );
}

function StatBox({ label, value }: { label: string; value: string }) {
  return (
    <div style={{
      background: "var(--surface-sunken)",
      borderRadius: "var(--radius-small)",
      padding: "12px 16px",
    }}>
      <div style={{ fontSize: "1.375rem", fontWeight: 700, fontFamily: "var(--font-display)", lineHeight: 1 }}>
        {value}
      </div>
      <div style={{ fontSize: "0.75rem", color: "var(--fg-muted)", marginTop: 4 }}>{label}</div>
    </div>
  );
}

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return n.toString();
}
