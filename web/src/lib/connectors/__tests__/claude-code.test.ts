import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

import { readProgress, encodeProjectDir } from "../claude-code";

// US-008 tests. The connector reads real JSONL off disk, so we exercise it
// against a real temp `.claude` home seeded with fixture transcripts rather than
// mocking fs — that's the behavior that matters (path encoding, latest-file
// selection, lenient line parsing, graceful degradation).

const PROJECT = "/Users/dev/daypage";

let claudeHome: string;

// Write a fixture transcript into the encoded project dir under our temp home.
async function seedTranscript(fileName: string, lines: string[]): Promise<string> {
  const dir = path.join(claudeHome, "projects", encodeProjectDir(PROJECT));
  await fs.mkdir(dir, { recursive: true });
  const full = path.join(dir, fileName);
  await fs.writeFile(full, lines.join("\n"), "utf8");
  return full;
}

function userLine(text: string, timestamp: string): string {
  return JSON.stringify({
    type: "user",
    timestamp,
    sessionId: "s1",
    message: { role: "user", content: text },
  });
}

function assistantLine(text: string, timestamp: string): string {
  return JSON.stringify({
    type: "assistant",
    timestamp,
    sessionId: "s1",
    message: { role: "assistant", content: [{ type: "text", text }] },
  });
}

beforeEach(async () => {
  claudeHome = await fs.mkdtemp(path.join(os.tmpdir(), "cc-conn-"));
});

afterEach(async () => {
  await fs.rm(claudeHome, { recursive: true, force: true });
  vi.restoreAllMocks();
});

describe("encodeProjectDir", () => {
  it("collapses slashes and dots to dashes", () => {
    expect(encodeProjectDir("/Users/me/dev/daypage")).toBe(
      "-Users-me-dev-daypage"
    );
    expect(encodeProjectDir("/a.b/c")).toBe("-a-b-c");
  });
});

describe("readProgress", () => {
  it("parses user messages + assistant text-block summaries", async () => {
    await seedTranscript("sess.jsonl", [
      userLine("Build the login page", "2026-06-09T10:00:00.000Z"),
      assistantLine("Done — added LoginView", "2026-06-09T10:01:00.000Z"),
    ]);

    const result = await readProgress({ project: PROJECT, claudeHome });

    expect(result).not.toBeNull();
    expect(result!.project).toBe(PROJECT);
    expect(result!.summary).toContain("User: Build the login page");
    expect(result!.summary).toContain("Assistant: Done — added LoginView");
    expect(result!.lastActivityAt).toBe("2026-06-09T10:01:00.000Z");
  });

  it("returns null when the project directory does not exist", async () => {
    const result = await readProgress({
      project: "/Users/dev/nonexistent-project",
      claudeHome,
    });
    expect(result).toBeNull();
  });

  it("returns null when the directory has no transcripts", async () => {
    const dir = path.join(claudeHome, "projects", encodeProjectDir(PROJECT));
    await fs.mkdir(dir, { recursive: true });
    // Drop a non-jsonl file to ensure it's ignored.
    await fs.writeFile(path.join(dir, "notes.txt"), "ignore me", "utf8");

    const result = await readProgress({ project: PROJECT, claudeHome });
    expect(result).toBeNull();
  });

  it("returns null when the transcript has no user/assistant turns", async () => {
    await seedTranscript("sess.jsonl", [
      JSON.stringify({ type: "summary", timestamp: "2026-06-09T10:00:00.000Z" }),
    ]);

    const result = await readProgress({ project: PROJECT, claudeHome });
    expect(result).toBeNull();
  });

  it("skips unparseable lines without aborting the read (warns, not silent)", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    await seedTranscript("sess.jsonl", [
      userLine("first", "2026-06-09T10:00:00.000Z"),
      "{ this is not valid json",
      "", // blank line, silently skipped
      assistantLine("second", "2026-06-09T10:02:00.000Z"),
    ]);

    const result = await readProgress({ project: PROJECT, claudeHome });

    expect(result).not.toBeNull();
    expect(result!.summary).toContain("User: first");
    expect(result!.summary).toContain("Assistant: second");
    // Warned for the malformed line, but did not silently swallow everything.
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it("picks the most-recently-modified transcript when several exist", async () => {
    const older = await seedTranscript("old.jsonl", [
      userLine("old message", "2026-06-01T00:00:00.000Z"),
    ]);
    // Backdate the older file so mtime ordering is deterministic.
    const past = new Date("2026-06-01T00:00:00.000Z");
    await fs.utimes(older, past, past);

    await seedTranscript("new.jsonl", [
      userLine("new message", "2026-06-09T00:00:00.000Z"),
    ]);

    const result = await readProgress({ project: PROJECT, claudeHome });

    expect(result).not.toBeNull();
    expect(result!.summary).toContain("new message");
    expect(result!.summary).not.toContain("old message");
  });

  it("honors maxTurns, keeping only the most recent turns", async () => {
    await seedTranscript("sess.jsonl", [
      userLine("turn 1", "2026-06-09T10:00:00.000Z"),
      assistantLine("turn 2", "2026-06-09T10:01:00.000Z"),
      userLine("turn 3", "2026-06-09T10:02:00.000Z"),
    ]);

    const result = await readProgress({
      project: PROJECT,
      claudeHome,
      maxTurns: 1,
    });

    expect(result).not.toBeNull();
    expect(result!.summary).toBe("User: turn 3");
    // lastActivityAt still reflects the whole transcript, not just the slice.
    expect(result!.lastActivityAt).toBe("2026-06-09T10:02:00.000Z");
  });

  it("ignores non-text blocks (e.g. tool_use) in assistant content", async () => {
    const line = JSON.stringify({
      type: "assistant",
      timestamp: "2026-06-09T10:00:00.000Z",
      message: {
        role: "assistant",
        content: [
          { type: "tool_use", name: "Bash", input: { command: "ls" } },
          { type: "text", text: "ran ls" },
        ],
      },
    });
    await seedTranscript("sess.jsonl", [line]);

    const result = await readProgress({ project: PROJECT, claudeHome });

    expect(result).not.toBeNull();
    expect(result!.summary).toBe("Assistant: ran ls");
  });
});
