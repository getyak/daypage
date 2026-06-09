// US-011: Inngest workflow that turns a Gateway "please suggest" signal into a
// Telegram push. Listens for `gateway/suggest.requested` {userId}, generates
// task suggestions, and delivers them as inline-keyboard buttons.
//
// The work is split into independent Inngest steps so a transient failure in
// generation or delivery is retried in isolation rather than re-running the
// whole pipeline (and re-spending LLM tokens):
//   1. check-budget   — policy gate; over budget ⇒ skip + log, no LLM call
//   2. generate       — generateSuggestions (the expensive, LLM-backed step)
//   3. resolve-chat   — map the user to their Telegram chat_id
//   4. notify         — sendSuggestions to Telegram
//
// `sendSuggestions` never throws (it returns a discriminated result), so the
// notify step surfaces delivery failures in its return value instead of forcing
// an Inngest retry on, e.g., a missing bot token.

import { eq, and } from "drizzle-orm";
import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { ingest_sources } from "@/lib/db/schema";
import { decryptConfig } from "@/lib/secret-crypto";
import { checkBudget } from "@/lib/gateway/policy";
import { generateSuggestions } from "@/lib/gateway/suggester";
import {
  sendSuggestions,
  type OutboundSuggestion,
  type SendSuggestionsResult,
} from "@/lib/connectors/outbound/telegram";

// Resolve the Telegram chat the user receives pushes on. Mirrors the inbound
// webhook's linkage: the chat_id lives in the user's enabled `telegram`
// ingest_source config (possibly envelope-encrypted). Returns null when no
// Telegram source is linked.
export async function resolveTelegramChatId(
  userId: string
): Promise<string | null> {
  const sources = await db
    .select({ config: ingest_sources.config })
    .from(ingest_sources)
    .where(
      and(
        eq(ingest_sources.user_id, userId),
        eq(ingest_sources.source_type, "telegram"),
        eq(ingest_sources.enabled, true)
      )
    );

  for (const s of sources) {
    const cfg = decryptConfig(s.config);
    const chatId = cfg.chat_id;
    if (chatId !== undefined && chatId !== null && chatId !== "") {
      return String(chatId);
    }
  }
  return null;
}

// Minimal step runner contract — Inngest's `step.run` and the test fake both
// satisfy it. Each named step is memoized/retried independently by Inngest.
type StepRunner = <T>(id: string, fn: () => Promise<T>) => Promise<T>;

// Dependencies the pipeline calls out to. Injectable so unit tests can mock
// them and assert on call order without an Inngest runtime.
export interface SuggesterDeps {
  checkBudget: typeof checkBudget;
  generateSuggestions: typeof generateSuggestions;
  resolveTelegramChatId: typeof resolveTelegramChatId;
  sendSuggestions: (params: {
    chatId: string;
    suggestions: OutboundSuggestion[];
  }) => Promise<SendSuggestionsResult>;
}

const defaultDeps: SuggesterDeps = {
  checkBudget,
  generateSuggestions,
  resolveTelegramChatId,
  sendSuggestions: (params) => sendSuggestions(params),
};

export type SuggesterRunResult =
  | { skipped: true; reason: string; [k: string]: unknown }
  | {
      skipped: false;
      userId: string;
      suggestions: number;
      delivered: boolean;
      messageId: number | null;
    };

// The pure orchestration: budget gate → generate → resolve chat → notify, each
// wrapped in a named step. Extracted from the Inngest handler so it can be unit
// tested with a fake `step` and mocked `deps`.
export async function runSuggesterPipeline(
  userId: string | undefined,
  step: StepRunner,
  deps: SuggesterDeps = defaultDeps
): Promise<SuggesterRunResult> {
  if (!userId) {
    console.warn("[suggester-run] missing userId in event payload, skipping");
    return { skipped: true, reason: "missing-userId" };
  }

  // ── 1. Budget gate ────────────────────────────────────────────────────────
  const budget = await step("check-budget", async () => {
    return deps.checkBudget(userId);
  });

  if (!budget.allowed) {
    console.log(
      `[suggester-run] over budget for user ${userId} ` +
        `(spent ${budget.spent}/${budget.limit}), skipping suggestion run`
    );
    return {
      skipped: true,
      reason: "over-budget",
      spent: budget.spent,
      limit: budget.limit,
    };
  }

  // ── 2. Generate (LLM-backed, retried in isolation) ────────────────────────
  const generated = await step("generate", async () => {
    const result = await deps.generateSuggestions({ userId });
    return {
      suggestions: result.suggestions.map((s) => ({
        id: s.id,
        title: s.title,
        rationale: s.rationale,
      })),
      degraded: result.degraded,
    };
  });

  if (generated.suggestions.length === 0) {
    console.log(
      `[suggester-run] no suggestions generated for user ${userId}, ` +
        `nothing to notify`
    );
    return {
      skipped: true,
      reason: "no-suggestions",
      degraded: generated.degraded,
    };
  }

  // ── 3. Resolve the user's Telegram chat ───────────────────────────────────
  const chatId = await step("resolve-chat", async () => {
    return deps.resolveTelegramChatId(userId);
  });

  if (!chatId) {
    console.log(
      `[suggester-run] no linked Telegram chat for user ${userId}, ` +
        `skipping notify`
    );
    return {
      skipped: true,
      reason: "no-telegram-chat",
      generated: generated.suggestions.length,
    };
  }

  // ── 4. Notify (never throws — surfaces delivery result) ───────────────────
  const delivery = await step("notify", async () => {
    return deps.sendSuggestions({ chatId, suggestions: generated.suggestions });
  });

  if (!delivery.ok) {
    console.error(
      `[suggester-run] telegram delivery failed for user ${userId}: ${delivery.error}`
    );
  }

  return {
    skipped: false,
    userId,
    suggestions: generated.suggestions.length,
    delivered: delivery.ok,
    messageId: delivery.ok ? delivery.messageId : null,
  };
}

export const suggesterRun = inngest.createFunction(
  { id: "suggester-run", name: "Suggester — generate & notify" },
  { event: "gateway/suggest.requested" },
  async ({ event, step }) => {
    const userId = event.data?.userId as string | undefined;
    // step.run's return type is Inngest's JSON-serialized projection of the
    // thunk result; our StepRunner contract preserves the original shape (the
    // step payloads here are already plain JSON), so bridge with a cast.
    const run: StepRunner = (id, fn) =>
      step.run(id, fn) as Promise<Awaited<ReturnType<typeof fn>>>;
    return runSuggesterPipeline(userId, run);
  }
);
