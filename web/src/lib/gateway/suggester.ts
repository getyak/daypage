import "server-only";
import { z } from "zod";
import { and, desc, eq } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  memos,
  trees,
  tree_nodes,
  task_suggestions,
  type NewTaskSuggestion,
} from "@/lib/db/schema";
import { dashscope } from "@/lib/ai/dashscope";
import { logPrompt } from "@/lib/ai/prompt-log";
import { readProgress } from "@/lib/connectors/claude-code";

// US-009: Suggester — reason candidate tasks from the user's task trees, recent
// Claude Code session progress, and recent memos. Output is a list of
// `TaskSuggestion`s the user later picks from (written to `task_suggestions`).
//
// The LLM is asked for strict JSON; we validate it with zod. A malformed reply
// is retried once, then degraded to an empty array (logged, never thrown) so a
// flaky model can never break the Gateway loop.

const SUGGESTION_MODEL = "qwen-plus";
const MAX_SUGGESTIONS = 5;
const RECENT_MEMOS = 15;
const TOP_NODES = 20;

// ── LLM output contract ────────────────────────────────────────────────────────
// One suggested task. `linked_node_id` cites the tree_node it grew from (the LLM
// echoes back an id we gave it); `estimate`/`suggested_target` hint the executor
// tier. All but title/rationale are optional.
const taskSuggestionSchema = z.object({
  title: z.string().min(1),
  rationale: z.string().min(1),
  linked_node_id: z.string().nullish(),
  estimate: z.string().nullish(),
  suggested_target: z.string().nullish(),
});

const suggestionsEnvelopeSchema = z.object({
  suggestions: z.array(taskSuggestionSchema),
});

export type TaskSuggestionDraft = z.infer<typeof taskSuggestionSchema>;

export interface GenerateSuggestionsInput {
  userId: string;
  // Absolute project path whose Claude Code session progress to fold into the
  // prompt. Optional — omit and CC context is simply skipped.
  project?: string;
  // Override the Claude home root; forwarded to the CC connector for tests.
  claudeHome?: string;
}

export interface GenerateSuggestionsResult {
  suggestions: Array<typeof task_suggestions.$inferSelect>;
  tokens_in: number;
  tokens_out: number;
  degraded: boolean;
}

// ── Context assembly ────────────────────────────────────────────────────────────

// Active tree nodes for the user, hottest first, capped — the Suggester's view
// of "what is this person pursuing". node ids are surfaced so the LLM can cite
// them back as `linked_node_id`.
async function summarizeTrees(userId: string): Promise<{
  text: string;
  nodeIds: Set<string>;
}> {
  const rows = await db
    .select({
      nodeId: tree_nodes.id,
      treeTitle: trees.title,
      nodeTitle: tree_nodes.title,
      kind: tree_nodes.kind,
      status: tree_nodes.status,
      heat: tree_nodes.heat,
    })
    .from(tree_nodes)
    .innerJoin(trees, eq(tree_nodes.tree_id, trees.id))
    .where(and(eq(trees.user_id, userId), eq(trees.status, "active")))
    .orderBy(desc(tree_nodes.heat))
    .limit(TOP_NODES);

  const nodeIds = new Set(rows.map((r) => r.nodeId));
  if (rows.length === 0) {
    return { text: "(no active task tree nodes yet)", nodeIds };
  }

  const text = rows
    .map(
      (r) =>
        `- [${r.nodeId}] (${r.kind}/${r.status}, heat ${r.heat.toFixed(1)}) ` +
        `${r.treeTitle} › ${r.nodeTitle}`
    )
    .join("\n");

  return { text, nodeIds };
}

// Most recent memo bodies, newest first — the raw signal of what the user has
// been thinking about lately.
async function summarizeRecentMemos(userId: string): Promise<string> {
  const rows = await db
    .select({ body: memos.body, created_at: memos.created_at })
    .from(memos)
    .where(eq(memos.user_id, userId))
    .orderBy(desc(memos.created_at))
    .limit(RECENT_MEMOS);

  if (rows.length === 0) return "(no recent memos)";

  return rows
    .map((r) => {
      const day = r.created_at.toISOString().slice(0, 10);
      const body = r.body.replace(/\s+/g, " ").trim().slice(0, 400);
      return `- (${day}) ${body}`;
    })
    .join("\n");
}

// Claude Code session digest, if a project was provided and a transcript exists.
async function summarizeCcProgress(
  input: GenerateSuggestionsInput
): Promise<string> {
  if (!input.project) return "(no Claude Code session linked)";
  const progress = await readProgress({
    project: input.project,
    claudeHome: input.claudeHome,
  });
  if (!progress) return "(no recent Claude Code activity)";
  return `Last active: ${progress.lastActivityAt ?? "unknown"}\n${progress.summary}`;
}

function buildPrompt(parts: {
  trees: string;
  ccProgress: string;
  memos: string;
}): { system: string; user: string } {
  const system =
    "You are DayPage's task Suggester. Given a user's task trees, their " +
    "Claude Code session progress, and recent memos, propose concrete next " +
    "tasks that move their goals forward. Each suggestion must be actionable " +
    "and grounded in the provided context. When a task continues a specific " +
    "tree node, set `linked_node_id` to that node's bracketed id; otherwise " +
    "omit it. `estimate` is a rough size (e.g. \"30m\", \"half a day\"). " +
    "`suggested_target` is the executor tier: \"self\" for light in-app work, " +
    'or "claude-code" / "openclaw" / "ralph" for heavier outsourced work. ' +
    `Propose at most ${MAX_SUGGESTIONS} suggestions. ` +
    'Reply with ONLY a JSON object of the shape ' +
    '{"suggestions": [{"title": string, "rationale": string, ' +
    '"linked_node_id"?: string, "estimate"?: string, ' +
    '"suggested_target"?: string}]}. No prose, no markdown fences.';

  const user =
    `## Task trees (hottest first)\n${parts.trees}\n\n` +
    `## Claude Code progress\n${parts.ccProgress}\n\n` +
    `## Recent memos\n${parts.memos}`;

  return { system, user };
}

// ── Parsing with one retry ──────────────────────────────────────────────────────

// Tolerate a model that wraps JSON in ```fences``` despite instructions.
function stripFences(content: string): string {
  const trimmed = content.trim();
  const fence = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  return fence ? fence[1].trim() : trimmed;
}

function parseSuggestions(content: string): TaskSuggestionDraft[] | null {
  let json: unknown;
  try {
    json = JSON.parse(stripFences(content));
  } catch {
    return null;
  }
  const parsed = suggestionsEnvelopeSchema.safeParse(json);
  if (!parsed.success) return null;
  return parsed.data.suggestions.slice(0, MAX_SUGGESTIONS);
}

// ── Public API ──────────────────────────────────────────────────────────────────

/**
 * Reason task suggestions for a user and persist them to `task_suggestions`.
 *
 * Assembles a prompt from the user's active tree nodes, Claude Code session
 * progress, and recent memos; asks DashScope for a strict-JSON list of
 * suggestions; validates with zod (retrying once on a malformed reply); then
 * writes the rows and logs token usage. On persistent failure it degrades to an
 * empty result (logged) rather than throwing.
 */
export async function generateSuggestions(
  input: GenerateSuggestionsInput
): Promise<GenerateSuggestionsResult> {
  const { userId } = input;

  const [{ text: treeText, nodeIds }, ccProgress, memoText] = await Promise.all([
    summarizeTrees(userId),
    summarizeCcProgress(input),
    summarizeRecentMemos(userId),
  ]);

  const { system, user } = buildPrompt({
    trees: treeText,
    ccProgress,
    memos: memoText,
  });

  let drafts: TaskSuggestionDraft[] | null = null;
  let tokens_in = 0;
  let tokens_out = 0;

  // One attempt + one retry. A non-JSON / schema-mismatched reply triggers the
  // retry; a thrown ProviderError (network/auth/etc.) is caught and degrades.
  for (let attempt = 0; attempt < 2 && drafts === null; attempt++) {
    try {
      const res = await dashscope.chat(
        [
          { role: "system", content: system },
          { role: "user", content: user },
        ],
        { model: SUGGESTION_MODEL, temperature: 0.4, jsonMode: true }
      );
      tokens_in += res.tokens_in;
      tokens_out += res.tokens_out;
      drafts = parseSuggestions(res.content);
      if (drafts === null) {
        console.warn(
          `[suggester] user ${userId}: invalid LLM JSON (attempt ${attempt + 1})`
        );
      }
    } catch (err) {
      console.error(
        `[suggester] user ${userId}: LLM call failed (attempt ${attempt + 1})`,
        err
      );
    }
  }

  // Attribute token usage to the user. dashscope.chat already logged an
  // anonymous row internally; this one carries user_id for per-user budgeting.
  await logPrompt({
    kind: "chat",
    model: SUGGESTION_MODEL,
    tokens_in,
    tokens_out,
    user_id: userId,
  }).catch(() => undefined);

  if (drafts === null) {
    console.error(
      `[suggester] user ${userId}: degraded to 0 suggestions after retry`
    );
    return { suggestions: [], tokens_in, tokens_out, degraded: true };
  }

  if (drafts.length === 0) {
    return { suggestions: [], tokens_in, tokens_out, degraded: false };
  }

  // Only honor a linked_node_id the LLM actually got from our context; a
  // hallucinated id would violate the FK, so drop it to NULL.
  const rows: NewTaskSuggestion[] = drafts.map((d) => ({
    user_id: userId,
    tree_node_id:
      d.linked_node_id && nodeIds.has(d.linked_node_id)
        ? d.linked_node_id
        : null,
    title: d.title,
    rationale: d.rationale,
    estimate: d.estimate ?? null,
    suggested_target: d.suggested_target ?? null,
  }));

  const inserted = await db.insert(task_suggestions).values(rows).returning();

  return { suggestions: inserted, tokens_in, tokens_out, degraded: false };
}
