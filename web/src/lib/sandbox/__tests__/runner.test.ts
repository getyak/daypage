// US-023: verifies the sandboxed runner's two core guarantees —
//   1. timeout hard-kill (SIGKILL on the whole process group)
//   2. no secrets/credentials injected into the child env
// Uses `node -e` as the child so the test stays runtime-agnostic and needs no
// fixture binaries.
import { describe, it, expect } from "vitest";
import { runSandboxed } from "../runner";

const NODE = process.execPath; // absolute path to the running node binary

describe("runSandboxed", () => {
  it("captures stdout, stderr, and exit code on a normal run", async () => {
    const res = await runSandboxed({
      cmd: NODE,
      args: [
        "-e",
        "process.stdout.write('hi'); process.stderr.write('warn'); process.exit(3)",
      ],
      timeoutMs: 5000,
    });

    expect(res.stdout).toBe("hi");
    expect(res.stderr).toBe("warn");
    expect(res.exitCode).toBe(3);
    expect(res.timedOut).toBe(false);
  });

  it("hard-kills a process that exceeds the timeout", async () => {
    const start = Date.now();
    const res = await runSandboxed({
      cmd: NODE,
      // Busy-block far longer than the timeout so the kill is what ends it.
      args: ["-e", "setTimeout(() => {}, 60000)"],
      timeoutMs: 150,
    });
    const elapsed = Date.now() - start;

    expect(res.timedOut).toBe(true);
    // Killed by signal → exit code is null (not a clean exit).
    expect(res.exitCode).toBeNull();
    // Must have ended near the timeout, not run the full 60s.
    expect(elapsed).toBeLessThan(5000);
  });

  it("does NOT inject any secret/credential env vars into the child", async () => {
    // Plant sensitive values in the parent env; the child must not see them.
    process.env.DASHSCOPE_API_KEY = "sk-should-not-leak";
    process.env.DATABASE_URL = "postgres://secret";
    process.env.TELEGRAM_BOT_TOKEN = "123:should-not-leak";

    const res = await runSandboxed({
      cmd: NODE,
      // Dump the child's view of process.env back to us.
      args: ["-e", "process.stdout.write(JSON.stringify(process.env))"],
      timeoutMs: 5000,
    });

    const childEnv = JSON.parse(res.stdout) as Record<string, string>;

    expect(childEnv.DASHSCOPE_API_KEY).toBeUndefined();
    expect(childEnv.DATABASE_URL).toBeUndefined();
    expect(childEnv.TELEGRAM_BOT_TOKEN).toBeUndefined();
    // PATH is the only inherited var (needed to resolve the binary).
    expect(typeof childEnv.PATH).toBe("string");
  });

  it("forwards explicit non-sensitive env but strips sensitive caller keys", async () => {
    const res = await runSandboxed({
      cmd: NODE,
      args: ["-e", "process.stdout.write(JSON.stringify(process.env))"],
      timeoutMs: 5000,
      env: {
        SANDBOX_TASK_ID: "task-42",
        MY_API_KEY: "should-be-stripped",
        SOME_SECRET: "nope",
      },
    });

    const childEnv = JSON.parse(res.stdout) as Record<string, string>;

    expect(childEnv.SANDBOX_TASK_ID).toBe("task-42");
    expect(childEnv.MY_API_KEY).toBeUndefined();
    expect(childEnv.SOME_SECRET).toBeUndefined();
  });

  it("rejects when the command cannot be spawned", async () => {
    await expect(
      runSandboxed({
        cmd: "/nonexistent/binary/definitely-not-here",
        timeoutMs: 1000,
      }),
    ).rejects.toThrow();
  });
});
