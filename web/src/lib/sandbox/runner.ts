// US-023: sandboxed runner for light, side-effect-free work.
//
// Spawns a child process under tight constraints so the gateway can execute
// "light" tasks (parsing, formatting, pure transforms) without trusting the
// command to behave. Two non-negotiable guarantees:
//   1. No secrets/credentials leak into the child's environment. We do NOT
//      inherit `process.env`; instead we build a minimal allow-listed env and
//      explicitly strip anything sensitive that the caller passes in.
//   2. A wall-clock timeout that hard-kills (SIGKILL) the process so a runaway
//      child cannot hold a worker hostage.
import { spawn, type SpawnOptions } from "node:child_process";

export interface RunSandboxedOptions {
  /** Executable to run (resolved via PATH in the minimal env). */
  cmd: string;
  /** Arguments passed to the executable. */
  args?: string[];
  /** Wall-clock budget in milliseconds before the child is hard-killed. */
  timeoutMs: number;
  /** Working directory for the child. Defaults to the current process cwd. */
  cwd?: string;
  /** Extra non-sensitive env vars to inject (sensitive keys are stripped). */
  env?: Record<string, string>;
  /** Cap on captured stdout/stderr bytes to avoid unbounded memory. */
  maxBuffer?: number;
}

export interface SandboxedResult {
  stdout: string;
  stderr: string;
  /** Exit code, or null if the process was killed by a signal. */
  exitCode: number | null;
  /** True when the process was hard-killed because it exceeded timeoutMs. */
  timedOut: boolean;
}

const DEFAULT_MAX_BUFFER = 1024 * 1024; // 1 MiB

// Substrings that mark an env var as a secret/credential. Any matching key is
// dropped from the child env regardless of source.
const SENSITIVE_ENV_PATTERNS = [
  "KEY",
  "SECRET",
  "TOKEN",
  "PASSWORD",
  "PASSWD",
  "CREDENTIAL",
  "AUTH",
  "PRIVATE",
  "SESSION",
  "COOKIE",
  "DATABASE_URL",
  "DSN",
  "WEBHOOK",
  "DASHSCOPE",
  "OPENAI",
  "SUPABASE",
  "UPSTASH",
  "REDIS",
  "SENTRY",
  "TELEGRAM",
];

function isSensitiveKey(key: string): boolean {
  const upper = key.toUpperCase();
  return SENSITIVE_ENV_PATTERNS.some((p) => upper.includes(p));
}

/**
 * Build the minimal environment handed to the child process.
 *
 * We deliberately do NOT spread `process.env` — the parent process holds API
 * keys, DB URLs, and webhook secrets that must never reach sandboxed code. Only
 * a tiny allow-list (PATH so the binary resolves) plus caller-provided
 * non-sensitive vars are forwarded. No network proxy vars are injected.
 */
function buildSandboxEnv(extra?: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};

  // PATH is needed to resolve the executable. Fall back to a sane default.
  env.PATH = process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin";

  if (extra) {
    for (const [key, value] of Object.entries(extra)) {
      if (isSensitiveKey(key)) continue; // never forward secrets
      env[key] = value;
    }
  }

  return env;
}

/**
 * Run a command in a constrained child process.
 *
 * Resolves with the captured output and how the process ended. Never rejects on
 * the child failing or timing out — those are reported via the result object.
 * Rejects only on spawn-level errors (e.g. command not found).
 */
export function runSandboxed(
  opts: RunSandboxedOptions,
): Promise<SandboxedResult> {
  const {
    cmd,
    args = [],
    timeoutMs,
    cwd = process.cwd(),
    env,
    maxBuffer = DEFAULT_MAX_BUFFER,
  } = opts;

  return new Promise((resolve, reject) => {
    const spawnOptions: SpawnOptions = {
      cwd,
      // Cast: the project's ProcessEnv requires NODE_ENV, but the sandbox env is
      // intentionally minimal and child_process accepts a plain string map.
      env: buildSandboxEnv(env) as NodeJS.ProcessEnv,
      // Detached so we can signal the whole process group on timeout, killing
      // any grandchildren the command may have spawned.
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    };
    const child = spawn(cmd, args, spawnOptions);

    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let timedOut = false;
    let settled = false;

    const killProcessTree = (signal: NodeJS.Signals) => {
      try {
        // Negative pid targets the whole process group (requires detached).
        if (child.pid !== undefined) process.kill(-child.pid, signal);
      } catch {
        // Group may already be gone; fall back to killing the child directly.
        try {
          child.kill(signal);
        } catch {
          // Already dead — nothing to do.
        }
      }
    };

    const timer = setTimeout(() => {
      timedOut = true;
      killProcessTree("SIGKILL");
    }, timeoutMs);

    child.stdout?.on("data", (chunk: Buffer) => {
      if (stdoutBytes < maxBuffer) {
        stdoutBytes += chunk.length;
        stdout += chunk.toString("utf8");
      }
    });

    child.stderr?.on("data", (chunk: Buffer) => {
      if (stderrBytes < maxBuffer) {
        stderrBytes += chunk.length;
        stderr += chunk.toString("utf8");
      }
    });

    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(err);
    });

    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ stdout, stderr, exitCode: code, timedOut });
    });
  });
}
