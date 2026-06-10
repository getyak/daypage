import { describe, it, expect, vi, beforeEach } from "vitest";

// session-lifecycle.ts imports db/client (and "server-only") at module load,
// which would otherwise need a real DATABASE_URL. The reaper itself takes its
// DB-facing operations via injected deps, so we stub the module-load side
// effects and drive `runSessionReaper` directly with mocks.
vi.mock("server-only", () => ({}));
vi.mock("@/lib/db/client", () => ({ db: {} }));

import {
  runSessionReaper,
  SESSION_TIMEOUT_MINUTES,
  type SessionReaperDeps,
  type StaleSession,
} from "@/lib/gateway/session-lifecycle";

// Fixed clock so the cutoff window is deterministic across the suite.
const NOW = 1_700_000_000_000;

function makeDeps(
  over: Partial<SessionReaperDeps> & {
    stale?: StaleSession[];
    // session ids the DB refuses to transition (e.g. already terminal)
    notTransitioned?: string[];
    // session ids that have NO associated work order (orphans)
    orphanIds?: string[];
    workOrdersFailed?: number;
  } = {}
): {
  deps: SessionReaperDeps;
  calls: {
    findStaleSessions: ReturnType<typeof vi.fn>;
    markTimedOut: ReturnType<typeof vi.fn>;
    failInFlightForSessions: ReturnType<typeof vi.fn>;
    hasAssociatedWorkOrder: ReturnType<typeof vi.fn>;
    closeOrphan: ReturnType<typeof vi.fn>;
  };
} {
  const {
    stale = [],
    notTransitioned = [],
    orphanIds = [],
    workOrdersFailed = 0,
    ...rest
  } = over;

  const findStaleSessions = vi.fn(async () => stale);
  const markTimedOut = vi.fn(async (ids: string[]) =>
    ids.filter((id) => !notTransitioned.includes(id))
  );
  const failInFlightForSessions = vi.fn(async () => workOrdersFailed);
  const hasAssociatedWorkOrder = vi.fn(
    async (id: string) => !orphanIds.includes(id)
  );
  const closeOrphan = vi.fn(async () => {});

  const deps: SessionReaperDeps = {
    findStaleSessions,
    markTimedOut,
    failInFlightForSessions,
    hasAssociatedWorkOrder,
    closeOrphan,
    now: () => NOW,
    ...rest,
  };

  return {
    deps,
    calls: {
      findStaleSessions,
      markTimedOut,
      failInFlightForSessions,
      hasAssociatedWorkOrder,
      closeOrphan,
    },
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
});

describe("runSessionReaper — cutoff window", () => {
  it("computes the cutoff as now minus the timeout window", async () => {
    const { deps, calls } = makeDeps({ stale: [] });
    await runSessionReaper(deps);

    expect(calls.findStaleSessions).toHaveBeenCalledTimes(1);
    const cutoff = calls.findStaleSessions.mock.calls[0][0] as Date;
    expect(cutoff.getTime()).toBe(NOW - SESSION_TIMEOUT_MINUTES * 60 * 1000);
  });
});

describe("runSessionReaper — no stale sessions", () => {
  it("short-circuits and touches nothing when no session is stale", async () => {
    const { deps, calls } = makeDeps({ stale: [] });
    const result = await runSessionReaper(deps);

    expect(result).toEqual({
      stale: 0,
      timedOut: 0,
      workOrdersFailed: 0,
      orphansClosed: 0,
    });
    expect(calls.markTimedOut).not.toHaveBeenCalled();
    expect(calls.failInFlightForSessions).not.toHaveBeenCalled();
    expect(calls.closeOrphan).not.toHaveBeenCalled();
  });
});

describe("runSessionReaper — timeout reclaim", () => {
  it("marks stale sessions timed_out and fails their in-flight work orders", async () => {
    const { deps, calls } = makeDeps({
      stale: [{ id: "s1" }, { id: "s2" }],
      workOrdersFailed: 3,
      orphanIds: [], // both sessions own work orders
    });

    const result = await runSessionReaper(deps);

    expect(calls.markTimedOut).toHaveBeenCalledWith(["s1", "s2"]);
    expect(calls.failInFlightForSessions).toHaveBeenCalledWith(["s1", "s2"]);
    expect(result.stale).toBe(2);
    expect(result.timedOut).toBe(2);
    expect(result.workOrdersFailed).toBe(3);
    expect(result.orphansClosed).toBe(0);
    expect(calls.closeOrphan).not.toHaveBeenCalled();
  });

  it("does not fail work orders when no session actually transitions", async () => {
    // e.g. another reaper raced us and the rows are already terminal.
    const { deps, calls } = makeDeps({
      stale: [{ id: "s1" }],
      notTransitioned: ["s1"],
    });

    const result = await runSessionReaper(deps);

    expect(result).toEqual({
      stale: 1,
      timedOut: 0,
      workOrdersFailed: 0,
      orphansClosed: 0,
    });
    expect(calls.failInFlightForSessions).not.toHaveBeenCalled();
    expect(calls.closeOrphan).not.toHaveBeenCalled();
  });
});

describe("runSessionReaper — orphan cleanup", () => {
  it("closes timed-out sessions that have no associated work order", async () => {
    const { deps, calls } = makeDeps({
      stale: [{ id: "orphan1" }, { id: "withWO" }],
      orphanIds: ["orphan1"],
      workOrdersFailed: 1,
    });

    const result = await runSessionReaper(deps);

    expect(calls.closeOrphan).toHaveBeenCalledTimes(1);
    expect(calls.closeOrphan).toHaveBeenCalledWith("orphan1");
    expect(result.orphansClosed).toBe(1);
    expect(result.timedOut).toBe(2);
    // in-flight work orders still failed for the non-orphan batch
    expect(result.workOrdersFailed).toBe(1);
  });

  it("closes every orphan when the whole batch is orphaned", async () => {
    const { deps, calls } = makeDeps({
      stale: [{ id: "o1" }, { id: "o2" }],
      orphanIds: ["o1", "o2"],
      workOrdersFailed: 0,
    });

    const result = await runSessionReaper(deps);

    expect(calls.closeOrphan).toHaveBeenCalledTimes(2);
    expect(result.orphansClosed).toBe(2);
    expect(result.workOrdersFailed).toBe(0);
  });
});
