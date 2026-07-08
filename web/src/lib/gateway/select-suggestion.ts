import "server-only";
import { db } from "@/lib/db/client";
import { task_suggestions, type TaskSuggestion } from "@/lib/db/schema";
import { and, eq } from "drizzle-orm";
import { enqueueJob } from "@/lib/gateway/jobs";

// US-013: a user tapped a Telegram suggestion button (`callback_data='pick:<id>'`).
// This moves the suggestion from `open` → `selected` and enqueues the dispatch
// job that hands it to the executor. Both effects are idempotent so repeated
// taps (Telegram re-delivers, users double-tap) never double-dispatch.

// Discriminated outcome so the webhook can craft the right answerCallbackQuery
// text without re-querying.
export type SelectSuggestionResult =
  | { status: "selected"; suggestion: TaskSuggestion }
  | { status: "already"; suggestion: TaskSuggestion }
  | { status: "not_found" };

// Flip `open` → `selected` only. The WHERE clause guards on the current status,
// so a row already `selected`/`dispatched` (or `dismissed`) is left untouched
// and the UPDATE returns no rows — that is our idempotency signal.
//
// SECURITY (IDOR): `userId` scopes every query to the caller's own suggestions.
// The suggestion id arrives from an untrusted client (a Telegram callback), so
// without this scoping any authenticated user could dispatch another user's
// suggestion by guessing its id. A suggestion owned by a different user reads
// back as `not_found`, exactly as if it did not exist.
export async function selectSuggestion(
  suggestionId: string,
  userId: string
): Promise<SelectSuggestionResult> {
  const updated = await db
    .update(task_suggestions)
    .set({ status: "selected" })
    .where(
      and(
        eq(task_suggestions.id, suggestionId),
        eq(task_suggestions.user_id, userId),
        eq(task_suggestions.status, "open")
      )
    )
    .returning();

  const suggestion = updated[0];

  if (suggestion) {
    // First selection: enqueue the dispatch job. Idempotency key dedupes against
    // any racing/retried enqueue for the same suggestion (see US-007 enqueueJob).
    await enqueueJob({
      userId: suggestion.user_id,
      type: "dispatch",
      payload: { suggestion_id: suggestion.id },
      idempotencyKey: `dispatch:${suggestion.id}`,
    });
    return { status: "selected", suggestion };
  }

  // No row updated: either the suggestion does not exist / is not owned by this
  // user, or it is no longer `open`. Read it back (still user-scoped) to tell an
  // "already queued" apart from a "gone" reply.
  const existing = await db
    .select()
    .from(task_suggestions)
    .where(
      and(
        eq(task_suggestions.id, suggestionId),
        eq(task_suggestions.user_id, userId)
      )
    )
    .limit(1);

  if (existing[0]) {
    return { status: "already", suggestion: existing[0] };
  }
  return { status: "not_found" };
}

// Outcome of a dismiss action — distinct from selection so callers don't have to
// reinterpret a "selected" status that never matches what actually happened.
export type DismissSuggestionResult =
  | { status: "dismissed"; suggestion: TaskSuggestion }
  | { status: "already"; suggestion: TaskSuggestion }
  | { status: "not_found" };

// US-033: the user declined a suggestion in the web workbench. Flip `open` →
// `dismissed`. Idempotent like selectSuggestion: the WHERE clause guards on the
// current status, so a row already acted on is left untouched and the UPDATE
// returns no rows. No dispatch is enqueued — a dismissed suggestion never runs.
export async function dismissSuggestion(
  suggestionId: string
): Promise<DismissSuggestionResult> {
  const updated = await db
    .update(task_suggestions)
    .set({ status: "dismissed" })
    .where(
      and(
        eq(task_suggestions.id, suggestionId),
        eq(task_suggestions.status, "open")
      )
    )
    .returning();

  const suggestion = updated[0];
  if (suggestion) {
    return { status: "dismissed", suggestion };
  }

  const existing = await db
    .select()
    .from(task_suggestions)
    .where(eq(task_suggestions.id, suggestionId))
    .limit(1);

  if (existing[0]) {
    return { status: "already", suggestion: existing[0] };
  }
  return { status: "not_found" };
}
