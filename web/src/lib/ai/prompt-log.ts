// ─── Token logging side-effect ─────────────────────────────────────────────────
// Every LLM call writes a prompt_log row for cost tracking.
// Failures are silently swallowed so they never block the caller.

import "server-only";
import { db } from "@/lib/db/client";
import { prompt_log } from "@/lib/db/schema";

export type PromptLogEntry = {
  kind: "chat" | "embed" | "transcribe";
  model: string;
  tokens_in: number;
  tokens_out: number;
  user_id?: string;
};

export async function logPrompt(entry: PromptLogEntry): Promise<void> {
  await db.insert(prompt_log).values({
    kind: entry.kind,
    model: entry.model,
    tokens_in: entry.tokens_in,
    tokens_out: entry.tokens_out,
    user_id: entry.user_id ?? null,
  });
}
