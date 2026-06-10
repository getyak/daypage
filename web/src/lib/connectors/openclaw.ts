import type { WorkOrder as WorkOrderRow } from "@/lib/db/schema";
import type {
  AdapterBackend,
  CollectResult,
  DispatchOutcome,
  ExecutorAdapter,
  PollResult,
} from "./types";

// US-028: OpenClaw backend adapter (skeleton).
//
// OpenClaw is a remote executor that runs a per-session agent loop behind an
// HTTP API. Unlike the file-based ralph/claude-code adapters, dispatch here is a
// live remote call: we POST the WorkOrder's intent to OpenClaw's session-create
// endpoint, and poll/collect resolve the returned session id against the same
// API. This is a pluggable backend stub — enough to dispatch/poll/collect over
// the wire — with the endpoint URL + auth token read from the environment so it
// stays a no-op-friendly skeleton until ops wire the real service.
//
// Configuration (both required; missing → a graceful "not configured" failure,
// never a crash):
//   OPENCLAW_API_URL   — base URL of the OpenClaw API (e.g. https://oc.example)
//   OPENCLAW_API_TOKEN — bearer token for authenticating requests

export interface OpenClawOptions {
  // Override the API base URL; defaults to `process.env.OPENCLAW_API_URL`.
  baseUrl?: string;
  // Override the bearer token; defaults to `process.env.OPENCLAW_API_TOKEN`.
  token?: string;
  // Injectable fetch for tests; defaults to the global `fetch`.
  fetchImpl?: typeof fetch;
}

// Read both required env settings. Returns null when either is missing/blank so
// callers degrade gracefully rather than dispatching into a void.
function readConfig(opts: OpenClawOptions): {
  baseUrl: string;
  token: string;
} | null {
  const baseUrl = (opts.baseUrl ?? process.env.OPENCLAW_API_URL)?.trim();
  const token = (opts.token ?? process.env.OPENCLAW_API_TOKEN)?.trim();
  if (!baseUrl || !token) return null;
  // Normalize away a trailing slash so we can join paths uniformly.
  return { baseUrl: baseUrl.replace(/\/+$/, ""), token };
}

// Standard Authorization + JSON headers for every OpenClaw request.
function authHeaders(token: string): Record<string, string> {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
}

// Map an OpenClaw session status string to a normalized poll state. OpenClaw's
// per-session loop reports a coarse lifecycle; anything unrecognized is treated
// as unknown rather than guessed.
function pollStateFromStatus(status: unknown): PollResult["state"] {
  switch (status) {
    case "running":
    case "queued":
    case "active":
      return "running";
    case "done":
    case "completed":
    case "succeeded":
      return "done";
    case "failed":
    case "error":
      return "failed";
    default:
      return "unknown";
  }
}

/**
 * Dispatch a WorkOrder to OpenClaw by creating a per-session loop.
 *
 * POSTs `{ intent, output_spec, context, work_order_id }` to
 * `<baseUrl>/sessions` and returns the created session id as the `ref`. Never
 * throws: a missing config, a network failure, or a non-OK response all resolve
 * to `{ status: 'failed', ref: null, error }` so the Gateway branches on status.
 */
export async function dispatch(
  order: WorkOrderRow,
  opts: OpenClawOptions = {}
): Promise<DispatchOutcome> {
  const config = readConfig(opts);
  if (!config) {
    return {
      status: "failed",
      ref: null,
      error: "OpenClaw not configured (OPENCLAW_API_URL / OPENCLAW_API_TOKEN)",
    };
  }

  const fetchImpl = opts.fetchImpl ?? fetch;
  const url = `${config.baseUrl}/sessions`;
  const requestBody = {
    intent: order.intent,
    output_spec: order.output_spec ?? null,
    context: order.context ?? {},
    work_order_id: order.id,
  };

  let res: Response;
  try {
    res = await fetchImpl(url, {
      method: "POST",
      headers: authHeaders(config.token),
      body: JSON.stringify(requestBody),
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { status: "failed", ref: null, error: `network error: ${message}` };
  }

  if (!res.ok) {
    return {
      status: "failed",
      ref: null,
      error: `OpenClaw dispatch failed: HTTP ${res.status}`,
    };
  }

  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return {
      status: "failed",
      ref: null,
      error: "OpenClaw dispatch: unreadable response body",
    };
  }

  const sessionId =
    body && typeof body === "object" && "session_id" in body
      ? (body as { session_id?: unknown }).session_id
      : undefined;

  if (typeof sessionId !== "string" || !sessionId) {
    return {
      status: "failed",
      ref: null,
      error: "OpenClaw dispatch: response missing session_id",
    };
  }

  return { status: "active", ref: sessionId };
}

// GET a session's current record from OpenClaw, or null when unconfigured /
// unreachable / non-OK / unparseable. Centralizes the read that poll and collect
// share.
async function getSession(
  id: string,
  opts: OpenClawOptions
): Promise<Record<string, unknown> | null> {
  const config = readConfig(opts);
  if (!config) return null;

  const fetchImpl = opts.fetchImpl ?? fetch;
  const url = `${config.baseUrl}/sessions/${encodeURIComponent(id)}`;

  try {
    const res = await fetchImpl(url, {
      method: "GET",
      headers: authHeaders(config.token),
    });
    if (!res.ok) return null;
    const body = (await res.json()) as unknown;
    return body && typeof body === "object"
      ? (body as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

/**
 * Poll a dispatched OpenClaw session by id. A readable session maps its
 * `status` to a normalized state; an unconfigured/unreachable session reports
 * `unknown` so the Gateway can keep waiting or back off.
 */
export async function poll(
  id: string,
  opts: OpenClawOptions = {}
): Promise<PollResult> {
  const session = await getSession(id, opts);
  if (!session) {
    return { state: "unknown", detail: "session unavailable" };
  }
  return { state: pollStateFromStatus(session.status) };
}

/**
 * Collect a dispatched OpenClaw session's artifact by id. `ready` flips true
 * once the session's status is terminal-done; `ref` points at the produced
 * artifact (`result_ref`/`artifact_url`) when present.
 */
export async function collect(
  id: string,
  opts: OpenClawOptions = {}
): Promise<CollectResult> {
  const session = await getSession(id, opts);
  if (!session) {
    return { ready: false, ref: null, detail: "session unavailable" };
  }

  const ready = pollStateFromStatus(session.status) === "done";
  const artifact =
    typeof session.result_ref === "string"
      ? session.result_ref
      : typeof session.artifact_url === "string"
        ? session.artifact_url
        : null;

  return { ready, ref: ready ? artifact : null };
}

const backend: AdapterBackend = "openclaw";

// The OpenClaw adapter, conforming to the uniform ExecutorAdapter interface.
// dispatch/poll/collect delegate to the standalone functions above (which take
// an injectable options bag for tests); the interface methods use env defaults.
export const openclawAdapter: ExecutorAdapter = {
  backend,
  dispatch: (wo: WorkOrderRow) => dispatch(wo),
  poll: (id: string) => poll(id),
  collect: (id: string) => collect(id),
};
