// US-012: hourly Gateway scheduler. A cron-driven tick that, every hour, walks
// the set of users who have opted into autonomous evolution and asks the
// Suggester to run for each — by sending the same `gateway/suggest.requested`
// event the US-011 pipeline already listens for.
//
// Event suppression: firing the Suggester is expensive (LLM tokens + a Telegram
// push), so we skip users whose state is unchanged. A user is "quiet" when, in
// the last hour, they have neither created a new memo nor mutated their task
// tree. Only users with fresh signal get an event.
//
// The pure decision (`shouldSuggestUser`) and the activity-window query are
// split from the Inngest handler and injected, so the suppression logic is unit
// testable without an Inngest runtime or a live database.

import { eq, and, gte, sql } from "drizzle-orm";
import { inngest } from "@/lib/inngest/client";
import { sendEvent } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { memos, trees, tree_nodes, user_settings } from "@/lib/db/schema";

// Settings key (under user_settings.settings) that opts a user into the
// autonomous evolution loop. Mirrors the persona settings convention in
// src/lib/ai/persona.ts.
export const EVOLUTION_ENABLED_KEY = "evolution_enabled";

const ONE_HOUR_MS = 60 * 60 * 1000;

// Per-user activity within the suppression window. Either signal is enough to
// justify a suggestion run.
export interface UserActivity {
  hasNewMemo: boolean;
  hasTreeChange: boolean;
}

// Pure suppression rule: only suggest when there is fresh signal. Extracted so
// the rule can be asserted directly in a unit test.
export function shouldSuggestUser(activity: UserActivity): boolean {
  return activity.hasNewMemo || activity.hasTreeChange;
}

// Returns the ids of users who have opted into evolution.
export async function listEvolutionUsers(): Promise<string[]> {
  const rows = await db
    .select({ user_id: user_settings.user_id })
    .from(user_settings)
    .where(
      sql`(${user_settings.settings} ->> ${EVOLUTION_ENABLED_KEY}) = 'true'`
    );
  return rows.map((r) => r.user_id);
}

// Activity for one user inside the last-hour window: did a memo get created, or
// did any node in any of the user's trees change?
export async function getUserActivity(
  userId: string,
  since: Date
): Promise<UserActivity> {
  const [newMemos, treeChanges] = await Promise.all([
    db
      .select({ id: memos.id })
      .from(memos)
      .where(and(eq(memos.user_id, userId), gte(memos.created_at, since)))
      .limit(1),
    db
      .select({ id: tree_nodes.id })
      .from(tree_nodes)
      .innerJoin(trees, eq(tree_nodes.tree_id, trees.id))
      .where(and(eq(trees.user_id, userId), gte(tree_nodes.updated_at, since)))
      .limit(1),
  ]);

  return {
    hasNewMemo: newMemos.length > 0,
    hasTreeChange: treeChanges.length > 0,
  };
}

// Dependencies the tick calls out to. Injectable so unit tests can drive the
// suppression behaviour without a DB or Inngest runtime.
export interface SchedulerDeps {
  listEvolutionUsers: () => Promise<string[]>;
  getUserActivity: (userId: string, since: Date) => Promise<UserActivity>;
  sendSuggestRequested: (userId: string) => Promise<void>;
  now: () => number;
}

const defaultDeps: SchedulerDeps = {
  listEvolutionUsers,
  getUserActivity,
  sendSuggestRequested: (userId) =>
    sendEvent({ name: "gateway/suggest.requested", data: { userId } }),
  now: () => Date.now(),
};

export interface SchedulerTickResult {
  considered: number;
  dispatched: number;
  suppressed: number;
}

// The pure orchestration: list evolution users → for each, check the last-hour
// activity window → dispatch a suggest event unless suppressed. Extracted from
// the Inngest handler so it can be unit tested with mocked deps.
export async function runSchedulerTick(
  deps: SchedulerDeps = defaultDeps
): Promise<SchedulerTickResult> {
  const since = new Date(deps.now() - ONE_HOUR_MS);
  const userIds = await deps.listEvolutionUsers();

  let dispatched = 0;
  let suppressed = 0;

  for (const userId of userIds) {
    const activity = await deps.getUserActivity(userId, since);
    if (!shouldSuggestUser(activity)) {
      suppressed++;
      console.log(
        `[scheduler-tick] suppressed user ${userId}: no new memo and no tree change in the last hour`
      );
      continue;
    }
    await deps.sendSuggestRequested(userId);
    dispatched++;
  }

  return { considered: userIds.length, dispatched, suppressed };
}

export const schedulerTick = inngest.createFunction(
  { id: "scheduler-tick", name: "Scheduler — hourly suggest tick" },
  { cron: "0 * * * *" },
  async () => runSchedulerTick()
);
