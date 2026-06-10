// US-027: a uniform executor-adapter interface.
//
// Different backends execute work very differently — a "light" job runs in our
// own sandbox, a "heavy" job is outsourced to Claude Code / OpenClaw / Ralph —
// but the Gateway only ever needs three verbs: hand a WorkOrder off (`dispatch`),
// ask how it's going (`poll`), and pull the produced artifact (`collect`). This
// module defines that contract so the Gateway can stay backend-agnostic and the
// registry (`getAdapter`) can swap implementations behind it.

import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";

// The executor backends an adapter can target. Mirrors `agent_backend` pgEnum.
export type AdapterBackend = "claude-code" | "openclaw" | "ralph" | "sandbox";

// Outcome of handing a WorkOrder to a backend. `ref` is the backend-specific
// handle (a session id, a task-file path, a remote job id) that `poll`/`collect`
// later resolve against; it is null only when dispatch failed.
export interface DispatchOutcome {
  status: "active" | "failed";
  // Backend handle for subsequent poll/collect (session id, file path, …).
  ref: string | null;
  error?: string;
}

// A snapshot of an in-flight (or finished) job. `state` is normalized across
// backends; `detail` carries an optional human-readable note.
export interface PollResult {
  state: "running" | "done" | "failed" | "unknown";
  detail?: string;
}

// The produced artifact once a job is done. `ref` points at the artifact
// (a file path, a result_ref, a URL); `ready` is false while still running.
export interface CollectResult {
  ready: boolean;
  ref: string | null;
  detail?: string;
}

/**
 * Uniform interface every executor backend implements.
 *
 * `dispatch` takes the full WorkOrder row (the only thing that carries the
 * intent + context); `poll`/`collect` take the backend handle returned by
 * `dispatch` (or otherwise stored on the order's session) so they don't need to
 * re-load the order. Implementations should be resilient — prefer returning a
 * `failed`/`unknown` state over throwing.
 */
export interface ExecutorAdapter {
  readonly backend: AdapterBackend;
  dispatch(wo: WorkOrderRow): Promise<DispatchOutcome>;
  poll(id: string): Promise<PollResult>;
  collect(id: string): Promise<CollectResult>;
}
