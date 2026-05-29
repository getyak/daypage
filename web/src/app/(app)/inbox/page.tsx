import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { users, inbox_items } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import type { InboxItem } from "@/lib/db/schema";
import { InboxClient } from "./InboxClient";

type Kind = "contradiction" | "schema" | "orphan" | "compiled" | "gap";

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

async function fetchInboxData(userId: string): Promise<{
  items: InboxItem[];
  counts: Record<Kind | "all", number>;
}> {
  try {
    const [items, kindCounts] = await Promise.all([
      db
        .select()
        .from(inbox_items)
        .where(
          and(eq(inbox_items.user_id, userId), eq(inbox_items.status, "open"))
        )
        .orderBy(
          sql`${inbox_items.created_at} desc`
        )
        .limit(100),
      db
        .select({
          kind: inbox_items.kind,
          count: sql<number>`count(*)::int`,
        })
        .from(inbox_items)
        .where(
          and(eq(inbox_items.user_id, userId), eq(inbox_items.status, "open"))
        )
        .groupBy(inbox_items.kind),
    ]);

    const counts: Record<Kind | "all", number> = {
      all: 0,
      contradiction: 0,
      schema: 0,
      orphan: 0,
      compiled: 0,
      gap: 0,
    };
    for (const row of kindCounts) {
      counts[row.kind as Kind] = row.count;
      counts.all += row.count;
    }

    return { items, counts };
  } catch {
    return {
      items: [],
      counts: { all: 0, contradiction: 0, schema: 0, orphan: 0, compiled: 0, gap: 0 },
    };
  }
}

export default async function InboxPage() {
  const session = await auth();

  let items: InboxItem[] = [];
  let counts: Record<Kind | "all", number> = {
    all: 0,
    contradiction: 0,
    schema: 0,
    orphan: 0,
    compiled: 0,
    gap: 0,
  };

  if (session?.user?.email) {
    const userId = await resolveUserId(session.user.email);
    if (userId) {
      const data = await fetchInboxData(userId);
      items = data.items;
      counts = data.counts;
    }
  }

  return <InboxClient items={items} counts={counts} />;
}
