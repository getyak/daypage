import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { Bot } from "lucide-react";
import { agentCostSummary, type AgentCostSummary } from "@/lib/gateway/cost";

// US-034: Agent dispatch + token cost dimension for /insights. Reads
// `agentCostSummary` over the trailing 7d and 30d windows and surfaces token
// spend, dispatch count, and a per-backend split. Empty state (no agent
// activity) renders a hint instead of erroring.

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db.select({ id: users.id }).from(users).where(eq(users.email, email)).limit(1);
  return rows[0]?.id ?? null;
}

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return n.toString();
}

// Friendly labels for the agentBackendEnum values.
const BACKEND_LABEL: Record<string, string> = {
  sandbox: "Sandbox (轻活)",
  "claude-code": "Claude Code",
  openclaw: "OpenClaw",
  ralph: "Ralph",
};

function backendLabel(backend: string): string {
  return BACKEND_LABEL[backend] ?? backend;
}

export async function AgentCostCard() {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  let week: AgentCostSummary | null = null;
  let month: AgentCostSummary | null = null;

  if (userId) {
    const now = Date.now();
    const since7 = new Date(now - 7 * 24 * 60 * 60 * 1000);
    const since30 = new Date(now - 30 * 24 * 60 * 60 * 1000);
    try {
      [week, month] = await Promise.all([
        agentCostSummary({ userId, since: since7 }),
        agentCostSummary({ userId, since: since30 }),
      ]);
    } catch {
      // Leave summaries null → empty state below.
    }
  }

  const hasData =
    (week?.dispatchCount ?? 0) > 0 ||
    (month?.dispatchCount ?? 0) > 0 ||
    (week?.tokensSpent ?? 0) > 0 ||
    (month?.tokensSpent ?? 0) > 0;

  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
    }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 20 }}>
        <Bot size={16} strokeWidth={1.7} style={{ color: "var(--accent)" }} />
        <span style={{ fontWeight: 600, fontSize: "0.9375rem" }}>Agent 成本</span>
        <span className="ds-section-label" style={{ marginLeft: "auto" }}>dispatch &amp; tokens</span>
      </div>

      {hasData ? (
        <>
          {/* 7d / 30d summary stats */}
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16, marginBottom: 24 }}>
            <WindowBox label="近 7 天" summary={week} />
            <WindowBox label="近 30 天" summary={month} highlight />
          </div>

          {/* Per-backend split (uses the 30d window for the fuller picture) */}
          <div>
            <div style={{ fontSize: "0.75rem", color: "var(--fg-subtle)", marginBottom: 8 }}>
              按后端拆分（近 30 天）
            </div>
            {month && month.byBackend.length > 0 ? (
              <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                {month.byBackend.map((b) => (
                  <BackendRow key={b.backend} backend={b.backend} dispatchCount={b.dispatchCount} tokensSpent={b.tokensSpent} />
                ))}
              </div>
            ) : (
              <div style={{ fontSize: "0.8125rem", color: "var(--fg-subtle)" }}>
                暂无按后端的派发记录。
              </div>
            )}
          </div>
        </>
      ) : (
        <EmptyState />
      )}
    </div>
  );
}

function WindowBox({ label, summary, highlight }: { label: string; summary: AgentCostSummary | null; highlight?: boolean }) {
  const tokens = summary?.tokensSpent ?? 0;
  const dispatches = summary?.dispatchCount ?? 0;
  return (
    <div style={{
      background: highlight ? "var(--accent-soft)" : "var(--surface-sunken)",
      borderRadius: "var(--radius-small)",
      padding: "14px 16px",
      border: highlight ? "1px solid var(--accent-border)" : "none",
    }}>
      <div style={{ fontSize: "0.75rem", color: "var(--fg-muted)", marginBottom: 8 }}>{label}</div>
      <div style={{ display: "flex", gap: 20 }}>
        <Metric value={fmtTokens(tokens)} label="tokens" highlight={highlight} />
        <Metric value={dispatches.toLocaleString()} label="派发次数" highlight={highlight} />
      </div>
    </div>
  );
}

function Metric({ value, label, highlight }: { value: string; label: string; highlight?: boolean }) {
  return (
    <div>
      <div style={{
        fontSize: "1.375rem",
        fontWeight: 700,
        fontFamily: "var(--font-display)",
        lineHeight: 1,
        color: highlight ? "var(--accent)" : "var(--fg-primary)",
      }}>
        {value}
      </div>
      <div style={{ fontSize: "0.7rem", color: "var(--fg-muted)", marginTop: 4 }}>{label}</div>
    </div>
  );
}

function BackendRow({ backend, dispatchCount, tokensSpent }: { backend: string; dispatchCount: number; tokensSpent: number }) {
  return (
    <div style={{
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      padding: "10px 14px",
      background: "var(--surface-sunken)",
      borderRadius: "var(--radius-small)",
    }}>
      <span style={{ fontSize: "0.875rem", fontWeight: 500, color: "var(--fg-primary)" }}>
        {backendLabel(backend)}
      </span>
      <span style={{ display: "flex", gap: 16, fontSize: "0.8125rem", color: "var(--fg-muted)" }}>
        <span>{fmtTokens(tokensSpent)} tokens</span>
        <span>{dispatchCount.toLocaleString()} 次</span>
      </span>
    </div>
  );
}

function EmptyState() {
  return (
    <div style={{ textAlign: "center", padding: "32px 0", color: "var(--fg-subtle)", fontSize: "0.875rem" }}>
      还没有 agent 派发记录。派发任务给执行后端后，token 消耗与次数会显示在这里。
    </div>
  );
}
