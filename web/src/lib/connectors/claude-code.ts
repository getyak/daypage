import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

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
