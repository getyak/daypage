import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, activities } from "@/lib/db/schema";
import { eq, and, gte, desc, lt, sql } from "drizzle-orm";
import { Activity } from "lucide-react";
import { ActivityStreamClient } from "./ActivityStreamClient";

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

const PAGE_SIZE = 20;

export async function ActivityStreamCard({ range, type, cursor }: { range: string; type?: string; cursor?: string }) {
  const session = await auth();
  const userId = session?.user?.email ? await resolveUserId(session.user.email) : null;

  // Collect available activity verbs for filter UI
  let verbOptions: string[] = [];
  let items: {
    id: string; verb: string; subject: string; target_type: string | null;
    target_id: string | null; created_at: Date;
  }[] = [];
  let hasMore = false;
  let nextCursor: string | null = null;

  if (userId) {
    const since = new Date(Date.now() - rangeToMs(range));
    try {
      // Get distinct verbs for filter chips
      const verbRows = await db
        .selectDistinct({ verb: activities.verb })
        .from(activities)
        .where(and(eq(activities.user_id, userId), gte(activities.created_at, since)));
      verbOptions = verbRows.map((r) => r.verb).sort();

      // Build conditions
      const conds = [eq(activities.user_id, userId), gte(activities.created_at, since)];
      if (type) conds.push(eq(activities.verb, type));
      if (cursor) conds.push(lt(activities.created_at, new Date(cursor)));

      const rows = await db
        .select()
        .from(activities)
        .where(and(...conds))
        .orderBy(desc(activities.created_at))
        .limit(PAGE_SIZE + 1);

      hasMore = rows.length > PAGE_SIZE;
      items = hasMore ? rows.slice(0, PAGE_SIZE) : rows;
      nextCursor = hasMore ? items[items.length - 1].created_at.toISOString() : null;
    } catch {
      // empty
    }
  }

  return (
    <div style={{
      background: "var(--surface-white)",
      borderRadius: "var(--radius-card)",
      border: "1px solid var(--accent-border)",
      padding: 24,
    }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 16 }}>
        <Activity size={16} strokeWidth={1.7} style={{ color: "var(--accent)" }} />
        <span style={{ fontWeight: 600, fontSize: "0.9375rem" }}>Activity Stream</span>
        <span className="ds-section-label" style={{ marginLeft: "auto" }}>{range}</span>
      </div>

      {/* Client-side filter + load-more */}
      <ActivityStreamClient
        initialItems={items.map((i) => ({ ...i, created_at: i.created_at.toISOString() }))}
        verbOptions={verbOptions}
        activeVerb={type ?? null}
        range={range}
        initialNextCursor={nextCursor}
        initialHasMore={hasMore}
      />
    </div>
  );
}
