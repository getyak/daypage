import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";
import type {
  AdapterBackend,
  CollectResult,
  DispatchOutcome,
  ExecutorAdapter,
  PollResult,
} from "./types";

// US-027: Ralph backend adapter.
//
// Ralph is an autonomous agent that drives itself off a `prd.json` whose
// `userStories[]` are the work-list. To outsource a mature `tree_node`/WorkOrder
// to Ralph we translate it into ONE legal Ralph story and write it as a prd.json
// fragment to a conventional drop location. A separate Ralph runner (out of
// scope) merges the fragment into its prd.json and executes it. Keeping dispatch
// file-only (no DB, no live process) makes it durable, inspectable, and testable.

// A single Ralph prd.json story. Field shape mirrors scripts/ralph/prd.json's
// `userStories[]` element exactly so the fragment is mergeable as-is.
export interface RalphStory {
  id: string;
  title: string;
  description: string;
  acceptanceCriteria: string[];
  priority: number;
  passes: boolean;
  notes: string;
}

// A prd.json fragment: just the stories to fold into Ralph's `userStories`.
export interface RalphPrdFragment {
  userStories: RalphStory[];
}

// Default drop directory for Ralph prd.json fragments. Overridable for tests.
const DEFAULT_RALPH_DIR = path.join(os.homedir(), ".daypage", "ralph");

export interface RalphDispatchOptions {
  // Override the drop directory; primarily for tests.
  dir?: string;
}

// Pull a non-empty string off the WorkOrder's opaque context, else null.
function ctxString(ctx: Record<string, unknown>, key: string): string | null {
  const v = ctx[key];
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

// Pull a string[] off the context (e.g. acceptance criteria), dropping blanks.
function ctxStringArray(
  ctx: Record<string, unknown>,
  key: string
): string[] {
  const v = ctx[key];
  if (!Array.isArray(v)) return [];
  return v
    .filter((x): x is string => typeof x === "string")
    .map((x) => x.trim())
    .filter(Boolean);
}

/**
 * Translate a mature WorkOrder (carrying its tree_node context) into a single
 * legal Ralph story.
 *
 * Mapping:
 *  - id            ← `RALPH-<work_order_id>` (stable, dedupe-friendly)
 *  - title         ← tree node/goal title from context, else the intent
 *  - description   ← the WorkOrder intent (the "As a … I want …" ask)
 *  - acceptance    ← context.acceptance_criteria, else the output_spec, else a
 *                    sensible default so the story is never criteria-less
 *  - priority      ← 1 (Ralph runs by ascending priority; a dispatched order is
 *                    something the user just chose, so it's top of the list)
 *  - passes/notes  ← false / "" (Ralph fills these as it works)
 */
export function toRalphStory(order: WorkOrderRow): RalphStory {
  const ctx = (order.context ?? {}) as Record<string, unknown>;

  const title =
    ctxString(ctx, "node_title") ??
    ctxString(ctx, "tree_title") ??
    order.intent;

  const acceptance = ctxStringArray(ctx, "acceptance_criteria");
  if (acceptance.length === 0 && order.output_spec?.trim()) {
    acceptance.push(order.output_spec.trim());
  }
  if (acceptance.length === 0) {
    acceptance.push(`Deliver: ${order.intent}`);
  }

  return {
    id: `RALPH-${order.id}`,
    title,
    description: order.intent,
    acceptanceCriteria: acceptance,
    priority: 1,
    passes: false,
    notes: "",
  };
}

/**
 * Dispatch a WorkOrder to Ralph by writing a prd.json fragment to the drop dir.
 *
 * Returns a `DispatchOutcome` whose `ref` is the fragment path (used by
 * `poll`/`collect`). Never throws — on a write failure it returns
 * `{status: 'failed', ref: null, error}` so callers branch on status.
 */
export async function dispatch(
  order: WorkOrderRow,
  opts: RalphDispatchOptions = {}
): Promise<DispatchOutcome> {
  const dir = opts.dir ?? DEFAULT_RALPH_DIR;
  const filePath = path.join(dir, `${order.id}.prd.json`);

  const fragment: RalphPrdFragment = { userStories: [toRalphStory(order)] };

  try {
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(
      filePath,
      `${JSON.stringify(fragment, null, 2)}\n`,
      "utf8"
    );
    return { status: "active", ref: filePath };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { status: "failed", ref: null, error: message };
  }
}

// Read a dispatched fragment's first story to derive a normalized job state.
// Ralph writes `passes: true` back into the fragment once the story is done.
async function readFragment(filePath: string): Promise<RalphStory | null> {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    const parsed = JSON.parse(raw) as RalphPrdFragment;
    return parsed.userStories?.[0] ?? null;
  } catch {
    return null;
  }
}

/**
 * Poll a dispatched Ralph job by `ref` (the fragment path). `passes: true` →
 * done; a readable but unfinished fragment → running; an unreadable/missing
 * fragment → unknown.
 */
export async function poll(id: string): Promise<PollResult> {
  const story = await readFragment(id);
  if (!story) return { state: "unknown", detail: "fragment not found" };
  if (story.passes) return { state: "done" };
  return { state: "running" };
}

/**
 * Collect a dispatched Ralph job's artifact by `ref`. The artifact is the
 * fragment file itself (Ralph mutates it in place); `ready` flips true once the
 * story `passes`.
 */
export async function collect(id: string): Promise<CollectResult> {
  const story = await readFragment(id);
  if (!story) return { ready: false, ref: null, detail: "fragment not found" };
  return { ready: story.passes, ref: id };
}

const backend: AdapterBackend = "ralph";

// The Ralph adapter, conforming to the uniform ExecutorAdapter interface.
export const ralphAdapter: ExecutorAdapter = {
  backend,
  dispatch,
  poll,
  collect,
};
