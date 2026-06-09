import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { eq } from "drizzle-orm";
import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";

// US-008: Claude Code connector — read a CC session's recent transcript so the
// Gateway/Suggester can reason about what the agent has been doing locally.
//
// Claude Code stores per-project session transcripts as JSONL under
// `~/.claude/projects/<encoded>/<sessionId>.jsonl`, one event per line. The
// directory name is the project's absolute path with `/` and `.` collapsed to
// `-` (e.g. `/Users/me/dev/daypage` → `-Users-me-dev-daypage`). Each line is a
// self-contained JSON object; user/assistant turns carry a `message` with a
// `role` and `content` (a string, or an array of typed blocks).

// One parsed turn from the transcript.
export interface TranscriptTurn {
  role: "user" | "assistant";
  text: string;
  at: string | null;
}

export interface ProgressSummary {
  project: string;
  // Human-readable digest: recent user messages + assistant summaries.
  summary: string;
  // ISO timestamp of the most recent transcript event, or null if unknown.
  lastActivityAt: string | null;
}

export interface ReadProgressOptions {
  // Absolute project path (its cwd). Used to derive the encoded directory.
  project: string;
  // How many of the most recent user+assistant turns to include. Default 10.
  maxTurns?: number;
  // Override the Claude home root; primarily for tests. Defaults to
  // `<homedir>/.claude`.
  claudeHome?: string;
}

const DEFAULT_MAX_TURNS = 10;

// Map an absolute project path to Claude Code's on-disk directory name. CC
// replaces every `/` and `.` in the path with `-`.
export function encodeProjectDir(project: string): string {
  return project.replace(/[/.]/g, "-");
}

// Pull plain text out of a message `content`, which is either a raw string or a
// list of typed blocks. We only surface `text`-type blocks; tool calls/results
// are intentionally dropped to keep the digest readable.
function extractText(content: unknown): string {
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";

  const parts: string[] = [];
  for (const block of content) {
    if (
      block &&
      typeof block === "object" &&
      "type" in block &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string"
    ) {
      const t = (block as { text: string }).text.trim();
      if (t) parts.push(t);
    }
  }
  return parts.join("\n").trim();
}

// Locate the most-recently-modified `.jsonl` transcript in `dir`, or null when
// the directory is missing/empty.
async function latestTranscript(dir: string): Promise<string | null> {
  let entries: string[];
  try {
    entries = await fs.readdir(dir);
  } catch {
    // Missing directory (ENOENT) or otherwise unreadable: graceful degradation.
    return null;
  }

  const jsonl = entries.filter((e) => e.endsWith(".jsonl"));
  if (jsonl.length === 0) return null;

  let newest: { file: string; mtimeMs: number } | null = null;
  for (const name of jsonl) {
    const full = path.join(dir, name);
    try {
      const stat = await fs.stat(full);
      if (!newest || stat.mtimeMs > newest.mtimeMs) {
        newest = { file: full, mtimeMs: stat.mtimeMs };
      }
    } catch {
      // A file that vanished between readdir and stat — skip it.
      continue;
    }
  }
  return newest?.file ?? null;
}

// Parse a transcript's lines into ordered user/assistant turns. A line that
// fails to parse (or isn't a recognized turn) is skipped, not fatal: a single
// malformed line must never sink the whole read.
function parseTurns(raw: string): TranscriptTurn[] {
  const turns: TranscriptTurn[] = [];
  const lines = raw.split("\n");

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let event: unknown;
    try {
      event = JSON.parse(trimmed);
    } catch {
      // Non-silent per the spec: warn and continue rather than failing the read
      // or dropping everything.
      console.warn("[claude-code] skipping unparseable transcript line");
      continue;
    }

    if (!event || typeof event !== "object") continue;
    const e = event as {
      type?: unknown;
      timestamp?: unknown;
      message?: { role?: unknown; content?: unknown };
    };
    if (e.type !== "user" && e.type !== "assistant") continue;

    const message = e.message;
    if (!message || typeof message !== "object") continue;
    const role = e.type; // type and message.role agree in practice; trust type.

    const text = extractText(message.content);
    if (!text) continue;

    turns.push({
      role,
      text,
      at: typeof e.timestamp === "string" ? e.timestamp : null,
    });
  }

  return turns;
}

// Build the digest string from the last `maxTurns` turns.
function buildSummary(turns: TranscriptTurn[], maxTurns: number): string {
  const recent = turns.slice(-maxTurns);
  return recent
    .map((t) => {
      const label = t.role === "user" ? "User" : "Assistant";
      return `${label}: ${t.text}`;
    })
    .join("\n\n");
}

/**
 * Read a Claude Code session's recent progress for a given project.
 *
 * Returns the latest transcript digested into recent user messages + assistant
 * summaries, plus when the session was last active. Returns `null` (never
 * throws) when there is no readable transcript, so callers can treat "no CC
 * activity" as a normal, expected state.
 */
export async function readProgress(
  options: ReadProgressOptions
): Promise<ProgressSummary | null> {
  const { project } = options;
  const maxTurns = options.maxTurns ?? DEFAULT_MAX_TURNS;
  const claudeHome =
    options.claudeHome ?? path.join(os.homedir(), ".claude");

  const dir = path.join(claudeHome, "projects", encodeProjectDir(project));

  const file = await latestTranscript(dir);
  if (!file) return null;

  let raw: string;
  try {
    raw = await fs.readFile(file, "utf8");
  } catch {
    return null;
  }

  const turns = parseTurns(raw);
  if (turns.length === 0) return null;

  // Most recent event timestamp across all parsed turns.
  const lastActivityAt = turns.reduce<string | null>((acc, t) => {
    if (!t.at) return acc;
    if (!acc || t.at > acc) return t.at;
    return acc;
  }, null);

  return {
    project,
    summary: buildSummary(turns, maxTurns),
    lastActivityAt,
  };
}

// US-015: dispatch a WorkOrder to a Claude Code session.
//
// MVP shape: rather than spawning a live CC process, we materialize the order as
// a task file (YAML front-matter + Markdown prompt) under a conventional drop
// directory and register an `agent_sessions` row pointing at that file via
// `external_ref`. A separate runner (out of scope here) picks the file up. This
// keeps dispatch durable, inspectable, and testable without a live backend.

// Default drop directory for materialized task files. Overridable for tests.
const DEFAULT_DISPATCH_DIR = path.join(
  os.homedir(),
  ".daypage",
  "work-orders"
);

export interface DispatchResult {
  // The registered `agent_sessions` row id, or null when dispatch failed.
  sessionId: string | null;
  status: "active" | "failed";
  // The materialized task-file path on success; the error message on failure.
  externalRef?: string;
  error?: string;
}

export interface DispatchOptions {
  // Override the drop directory; primarily for tests.
  dir?: string;
  // Inject the dispatch timestamp for deterministic task files; defaults to now.
  now?: Date;
}

// Render a WorkOrder row into a task file: YAML front-matter (machine fields) +
// a Markdown prompt body (intent + the Suggester's context). Kept hand-rolled to
// match the repo convention of no external YAML/Markdown deps.
function renderTaskFile(order: WorkOrderRow, dispatchedAt: string): string {
  const ctx = (order.context ?? {}) as Record<string, unknown>;
  const rationale =
    typeof ctx.rationale === "string" ? ctx.rationale : "";
  const treeTitle =
    typeof ctx.tree_title === "string" ? ctx.tree_title : null;
  const nodeTitle =
    typeof ctx.node_title === "string" ? ctx.node_title : null;

  const front = [
    "---",
    `work_order_id: ${order.id}`,
    `gate: ${order.gate}`,
    `budget_tokens: ${order.budget_tokens ?? "null"}`,
    `dispatched_at: ${dispatchedAt}`,
    "---",
  ].join("\n");

  const bodyLines = [`# ${order.intent}`, ""];
  if (treeTitle) bodyLines.push(`Goal: ${treeTitle}`);
  if (nodeTitle) bodyLines.push(`Branch: ${nodeTitle}`);
  if (rationale) bodyLines.push("", rationale);
  if (order.output_spec) bodyLines.push("", "## Output", order.output_spec);

  return `${front}\n\n${bodyLines.join("\n")}\n`;
}

/**
 * Dispatch a WorkOrder to a Claude Code session.
 *
 * Writes the order out as a task file under the drop directory and registers an
 * `agent_sessions` row (`backend='claude-code'`, `external_ref=<task path>`),
 * then records a `change_log` entry (`action_kind='dispatch_workorder'`,
 * `performed_by='agent'`). On any failure the work order is marked
 * `status='failed'` and the error is returned — this never throws, so callers
 * can branch on `result.status` rather than wrapping in try/catch.
 */
export async function dispatch(
  order: WorkOrderRow,
  opts: DispatchOptions = {}
): Promise<DispatchResult> {
  const dir = opts.dir ?? DEFAULT_DISPATCH_DIR;
  const dispatchedAt = (opts.now ?? new Date()).toISOString();
  const filePath = path.join(dir, `${order.id}.md`);

  // Lazily pull in the db client + tables so that importing this module for the
  // fs-only `readProgress` path never forces a DB connection (the client throws
  // at import time when DATABASE_URL is unset).
  const { db } = await import("@/lib/db/client");
  const { agent_sessions, change_log, work_orders } = await import(
    "@/lib/db/schema"
  );

  try {
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(filePath, renderTaskFile(order, dispatchedAt), "utf8");

    const inserted = await db
      .insert(agent_sessions)
      .values({
        user_id: order.user_id,
        backend: "claude-code",
        external_ref: filePath,
        project: dir,
        status: "active",
      })
      .returning({ id: agent_sessions.id });

    const sessionId = inserted[0].id;

    await db
      .update(work_orders)
      .set({ status: "running" })
      .where(eq(work_orders.id, order.id));

    await db.insert(change_log).values({
      user_id: order.user_id,
      action_kind: "dispatch_workorder",
      target_type: "work_order",
      target_id: order.id,
      before: { status: order.status },
      after: {
        status: "running",
        session_id: sessionId,
        external_ref: filePath,
      },
      reason: `dispatched to claude-code: ${order.intent}`,
      performed_by: "agent",
    });

    return { sessionId, status: "active", externalRef: filePath };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    // Best-effort: flip the order to failed so it isn't stuck pending. A failure
    // here must not mask the original error, so swallow it.
    try {
      await db
        .update(work_orders)
        .set({ status: "failed" })
        .where(eq(work_orders.id, order.id));
    } catch {
      // ignore — original error is what matters
    }
    return { sessionId: null, status: "failed", error: message };
  }
}
