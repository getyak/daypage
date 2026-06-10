// US-024: sandbox terminal tool — command whitelist.
//
// The gateway lets "light" tasks run shell commands inside the sandbox, but the
// shell must never be a general-purpose escape hatch. Every command is screened
// by a strict allow-list policy BEFORE anything is executed:
//   - only a fixed set of safe, read-mostly commands are permitted
//     (git status/log/diff, ls, cat, npm run build/test, node <script>)
//   - destructive ops (rm -rf), credential access (cat ~/.ssh/...),
//     out-of-repo writes, and network commands (curl/wget/...) are rejected
//   - on rejection we return a clear error and DO NOT execute the command
//   - every decision (allow or deny) is written to change_log for audit
//
// The policy (`evaluateCommand`) is a pure function so it is exhaustively unit
// testable without a DB or a real child process. `runTerminalCommand` wires the
// policy to the audit log and the sandboxed runner via injectable deps.
import { db } from "@/lib/db/client";
import { change_log } from "@/lib/db/schema";
import { runSandboxed, type SandboxedResult } from "./runner";

// ─── Policy ──────────────────────────────────────────────────────────────────

/** Verdict from screening a single command against the whitelist policy. */
export interface PolicyVerdict {
  allowed: boolean;
  /** The matched whitelist rule, when allowed (for logging). */
  rule?: string;
  /** Human-readable reason the command was denied. Empty when allowed. */
  reason: string;
}

// Allowed leading executables and their permitted sub-commands. An empty Set
// means "any args are fine for this executable" (e.g. `ls`, `cat`); a non-empty
// Set restricts the first argument to the listed sub-commands.
const WHITELIST: Record<string, Set<string>> = {
  // git: read-only inspection only.
  git: new Set(["status", "log", "diff"]),
  // npm: only build/test scripts via `npm run`.
  npm: new Set(["run"]),
  // node: run a script (no flag-only invocations are special-cased here).
  node: new Set(),
  // Filesystem listing / reading.
  ls: new Set(),
  cat: new Set(),
};

// For `npm run`, only these scripts may be invoked.
const NPM_RUN_SCRIPTS = new Set(["build", "test"]);

// Shell metacharacters that allow chaining, redirection, substitution, or
// globbing into something the per-token checks can't reason about. Any of these
// in the raw command is an immediate reject — we only run single, literal
// commands, never composed shell expressions.
const SHELL_METACHARACTERS = [
  "|",
  "&",
  ";",
  ">",
  "<",
  "`",
  "$(",
  "${",
  "\n",
  "\r",
  "\\",
];

// Network-capable executables are never allowed: they can exfiltrate data or
// pull in untrusted code regardless of their args.
const NETWORK_COMMANDS = new Set([
  "curl",
  "wget",
  "nc",
  "ncat",
  "netcat",
  "ssh",
  "scp",
  "sftp",
  "telnet",
  "ftp",
  "rsync",
  "ping",
]);

/**
 * Tokenize a raw command line on whitespace. Returns null when the command
 * contains shell metacharacters (which we refuse to interpret).
 */
function tokenize(raw: string): string[] | null {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return [];
  for (const meta of SHELL_METACHARACTERS) {
    if (trimmed.includes(meta)) return null;
  }
  return trimmed.split(/\s+/);
}

/** True if any token looks like it touches credentials or escapes the repo. */
function hasDangerousPath(tokens: string[]): boolean {
  return tokens.some((tok) => {
    // Credential / secret locations.
    if (/(^|\/)\.ssh(\/|$)/.test(tok)) return true;
    if (/(^|\/)\.aws(\/|$)/.test(tok)) return true;
    if (/(^|\/)\.env($|\.)/.test(tok)) return true;
    if (/\.(pem|key)$/.test(tok)) return true;
    if (/(^|\/)id_rsa($|\.)/.test(tok)) return true;
    // Home-relative or absolute paths can read anything outside the repo.
    if (tok.startsWith("~")) return true;
    if (tok.startsWith("/")) return true;
    // Parent-directory traversal escapes the working tree.
    if (tok === ".." || tok.startsWith("../") || tok.includes("/../")) {
      return true;
    }
    return false;
  });
}

/**
 * Screen a raw command line against the whitelist policy. Pure and deterministic
 * — no I/O — so it can be exhaustively unit tested.
 */
export function evaluateCommand(raw: string): PolicyVerdict {
  const tokens = tokenize(raw);

  if (tokens === null) {
    return {
      allowed: false,
      reason:
        "shell metacharacters are not allowed; only single literal commands are permitted",
    };
  }
  if (tokens.length === 0) {
    return { allowed: false, reason: "empty command" };
  }

  const [exe, ...args] = tokens;

  // Explicit network-command rejection (clearer error than "not whitelisted").
  if (NETWORK_COMMANDS.has(exe)) {
    return {
      allowed: false,
      reason: `network command '${exe}' is not allowed in the sandbox`,
    };
  }

  // Out-of-repo / credential paths are rejected regardless of the executable.
  // This catches `cat ~/.ssh/id_rsa`, `cat /etc/passwd`, `ls ../../secrets`.
  if (hasDangerousPath(args)) {
    return {
      allowed: false,
      reason:
        "command references a path outside the repo or a credential location",
    };
  }

  const allowedArgs = WHITELIST[exe];
  if (allowedArgs === undefined) {
    return {
      allowed: false,
      // `rm` (and anything else off-list) lands here → rm -rf is rejected.
      reason: `command '${exe}' is not on the whitelist`,
    };
  }

  // Executable is allowed; check sub-command constraints if any.
  if (allowedArgs.size > 0) {
    const sub = args[0];
    if (sub === undefined || !allowedArgs.has(sub)) {
      return {
        allowed: false,
        reason: `'${`${exe} ${sub ?? ""}`.trim()}' is not an allowed sub-command of '${exe}'`,
      };
    }
    // Extra constraint for `npm run <script>`.
    if (exe === "npm" && sub === "run") {
      const script = args[1];
      if (script === undefined || !NPM_RUN_SCRIPTS.has(script)) {
        return {
          allowed: false,
          reason: `npm script '${script ?? ""}' is not allowed; only ${[...NPM_RUN_SCRIPTS].join("/")}`,
        };
      }
    }
  }

  return { allowed: true, rule: `${exe} ${args[0] ?? ""}`.trim(), reason: "" };
}

// ─── Audit + execution ───────────────────────────────────────────────────────

/** Writes a single audit row recording a policy decision. */
export type ChangeLogWriter = (entry: {
  userId: string;
  command: string;
  verdict: PolicyVerdict;
}) => Promise<void>;

/** Executes an allowed command. Mirrors the runner's result shape. */
export type SandboxExecutor = (
  exe: string,
  args: string[],
) => Promise<SandboxedResult>;

export interface TerminalDeps {
  recordChangeLog: ChangeLogWriter;
  execute: SandboxExecutor;
}

export interface RunTerminalOptions {
  /** Owner of the audit trail (change_log.user_id). */
  userId: string;
  /** Raw command line, e.g. "git status" or "npm run build". */
  command: string;
  /** Working directory for an allowed command. Defaults to process cwd. */
  cwd?: string;
  /** Wall-clock budget in ms for an allowed command. */
  timeoutMs?: number;
}

export interface TerminalResult {
  allowed: boolean;
  /** Present when denied: the policy reason, also surfaced as the error. */
  error?: string;
  /** Present when allowed and executed. */
  output?: SandboxedResult;
}

const DEFAULT_TIMEOUT_MS = 120_000; // builds/tests can be slow.

/** Default change_log writer: inserts an audit row via the live db. */
const defaultRecordChangeLog: ChangeLogWriter = async ({
  userId,
  command,
  verdict,
}) => {
  await db.insert(change_log).values({
    user_id: userId,
    action_kind: verdict.allowed
      ? "sandbox_terminal_allow"
      : "sandbox_terminal_deny",
    target_type: "sandbox_command",
    target_id: command,
    before: null,
    after: {
      command,
      allowed: verdict.allowed,
      rule: verdict.rule ?? null,
      reason: verdict.reason,
    },
    reason: verdict.reason || null,
    performed_by: "agent",
    agent_action_id: null,
  });
};

/** Default executor: delegate to the sandboxed runner. */
const defaultExecute =
  (cwd: string | undefined, timeoutMs: number): SandboxExecutor =>
  (exe, args) =>
    runSandboxed({ cmd: exe, args, cwd, timeoutMs });

/**
 * Screen a command, audit the decision, and execute it only if allowed.
 *
 * On denial: returns `{ allowed: false, error }` and never touches the executor.
 * On allow: runs the command in the sandbox and returns its captured output.
 * Either way a change_log row is written first.
 */
export async function runTerminalCommand(
  opts: RunTerminalOptions,
  deps?: Partial<TerminalDeps>,
): Promise<TerminalResult> {
  const { userId, command, cwd, timeoutMs = DEFAULT_TIMEOUT_MS } = opts;

  const recordChangeLog = deps?.recordChangeLog ?? defaultRecordChangeLog;
  const execute = deps?.execute ?? defaultExecute(cwd, timeoutMs);

  const verdict = evaluateCommand(command);

  // Audit BEFORE acting on the verdict, so both allows and denies are recorded.
  await recordChangeLog({ userId, command, verdict });

  if (!verdict.allowed) {
    return { allowed: false, error: verdict.reason };
  }

  // Safe to re-tokenize: evaluateCommand already guaranteed no metacharacters.
  const [exe, ...args] = command.trim().split(/\s+/);
  const output = await execute(exe, args);
  return { allowed: true, output };
}
