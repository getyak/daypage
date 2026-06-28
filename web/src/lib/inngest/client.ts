import { Inngest } from "inngest";

export const inngest = new Inngest({ id: "daypage" });

type InngestEvent = Parameters<typeof inngest.send>[0];

// Local Inngest dev server (`npm run dev:inngest`). The SDK auto-routes events
// here in dev when no INNGEST_EVENT_KEY is set, so its availability is the real
// signal for whether compilation will run locally.
const DEV_SERVER_URL = "http://localhost:8288/dev";

/**
 * In production (or whenever INNGEST_EVENT_KEY is set) the compile pipeline is
 * always reachable via Inngest Cloud, so we never probe the local dev server.
 */
function pipelineConfiguredForCloud(): boolean {
  const isDev =
    process.env.NODE_ENV === "development" ||
    process.env.E2E_DEV_LOGIN === "1";
  const hasEventKey = Boolean(process.env.INNGEST_EVENT_KEY);
  return !isDev || hasEventKey;
}

// Probe results are cached briefly so a burst of requests (e.g. status banner +
// a save) doesn't fan out into multiple round-trips to the dev server.
let devProbeCache: { at: number; up: boolean } | null = null;
const DEV_PROBE_TTL_MS = 5_000;

async function devServerUp(): Promise<boolean> {
  const now = Date.now();
  if (devProbeCache && now - devProbeCache.at < DEV_PROBE_TTL_MS) {
    return devProbeCache.up;
  }
  let up = false;
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 1_000);
    const res = await fetch(DEV_SERVER_URL, { signal: ctrl.signal });
    clearTimeout(timer);
    up = res.ok;
  } catch {
    up = false;
  }
  devProbeCache = { at: now, up };
  return up;
}

/**
 * Whether sendEvent() will actually dispatch to Inngest, or silently no-op.
 *
 * - Cloud (prod, or any env with INNGEST_EVENT_KEY): always connected.
 * - Local dev: the Inngest SDK auto-routes events to the local dev server
 *   (`npm run dev:inngest`, :8288) — no EVENT_KEY required. So the honest
 *   answer is "is the dev server actually up?", which we probe directly rather
 *   than inferring from env vars. This fixes the false-negative where the
 *   banner claimed "not connected" while the dev server was running fine and
 *   able to compile.
 */
export async function isCompileServiceConnected(): Promise<boolean> {
  if (pipelineConfiguredForCloud()) return true;
  return devServerUp();
}

/**
 * Wraps inngest.send() with a dev-mode fallback.
 *
 * In dev without INNGEST_EVENT_KEY, sending only works when the local Inngest
 * dev server is running — the SDK then auto-routes to :8288. If it's *not*
 * running, inngest.send() would throw, so we no-op (the memo is still persisted;
 * compilation simply never runs, which is acceptable for local dev). In cloud /
 * with an event key we always send.
 */
export async function sendEvent(event: InngestEvent): Promise<void> {
  if (!(await isCompileServiceConnected())) {
    return;
  }

  await inngest.send(event);
}
