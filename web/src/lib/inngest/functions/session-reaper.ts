import { inngest } from "@/lib/inngest/client";
import {
  defaultSessionReaperDeps,
  runSessionReaper,
  SESSION_TIMEOUT_MINUTES,
} from "@/lib/gateway/session-lifecycle";

// US-030: session reaper cron. Every 5 minutes, reclaim agent sessions that
// have missed their heartbeat window (`SESSION_TIMEOUT_MINUTES`): mark them
// `timed_out`, fail any in-flight work orders they were driving, and close out
// orphan sessions (no associated work order). The reclaim logic lives in
// `runSessionReaper` (pure, injectable, unit tested); this is the thin Inngest
// wrapper that drives it with the live-DB deps.

export const sessionReaper = inngest.createFunction(
  { id: "session-reaper", name: "Agent Session Reaper" },
  { cron: "*/5 * * * *" },
  async () => {
    const result = await runSessionReaper(defaultSessionReaperDeps);
    console.log(
      `[session-reaper] timeout=${SESSION_TIMEOUT_MINUTES}m stale=${result.stale} ` +
        `timed_out=${result.timedOut} work_orders_failed=${result.workOrdersFailed} ` +
        `orphans_closed=${result.orphansClosed}`
    );
    return result;
  }
);
