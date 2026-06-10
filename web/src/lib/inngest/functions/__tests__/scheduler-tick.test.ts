import { describe, it, expect, vi, beforeEach } from "vitest";

// scheduler-tick.ts imports db/client and the inngest client at module load,
// both of which would otherwise need a real DATABASE_URL / event key. Stub the
// heavy module-load side effects; the tick itself takes its dependencies via
// injection, so we drive it directly with mocks.
vi.mock("@/lib/db/client", () => ({ db: {} }));
vi.mock("@/lib/inngest/client", () => ({
  inngest: { createFunction: vi.fn(() => ({})) },
  sendEvent: vi.fn(async () => {}),
}));

import {
  runSchedulerTick,
  shouldSuggestUser,
  type SchedulerDeps,
  type UserActivity,
} from "@/lib/inngest/functions/scheduler-tick";

// Fixed clock so the suppression window is deterministic across the suite.
const NOW = 1_700_000_000_000;

function makeDeps(
  over: Partial<SchedulerDeps> & {
    users?: string[];
    activity?: Record<string, UserActivity>;
  } = {}
): SchedulerDeps {
  const { users = [], activity = {}, ...rest } = over;
  return {
    listEvolutionUsers: vi.fn(async () => users),
    getUserActivity: vi.fn(
      async (userId: string) =>
        activity[userId] ?? { hasNewMemo: false, hasTreeChange: false }
    ),
    sendSuggestRequested: vi.fn(async () => {}),
    now: () => NOW,
    ...rest,
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
});

describe("shouldSuggestUser", () => {
  it("suggests when there is a new memo", () => {
    expect(shouldSuggestUser({ hasNewMemo: true, hasTreeChange: false })).toBe(
      true
    );
  });

  it("suggests when the tree changed", () => {
    expect(shouldSuggestUser({ hasNewMemo: false, hasTreeChange: true })).toBe(
      true
    );
  });

  it("suppresses when neither memo nor tree changed", () => {
    expect(shouldSuggestUser({ hasNewMemo: false, hasTreeChange: false })).toBe(
      false
    );
  });
});

describe("runSchedulerTick", () => {
  it("dispatches a suggest event only for users with fresh signal", async () => {
    const deps = makeDeps({
      users: ["active", "quiet", "tree-only"],
      activity: {
        active: { hasNewMemo: true, hasTreeChange: false },
        quiet: { hasNewMemo: false, hasTreeChange: false },
        "tree-only": { hasNewMemo: false, hasTreeChange: true },
      },
    });

    const result = await runSchedulerTick(deps);

    expect(deps.sendSuggestRequested).toHaveBeenCalledTimes(2);
    expect(deps.sendSuggestRequested).toHaveBeenCalledWith("active");
    expect(deps.sendSuggestRequested).toHaveBeenCalledWith("tree-only");
    expect(deps.sendSuggestRequested).not.toHaveBeenCalledWith("quiet");
    expect(result).toEqual({ considered: 3, dispatched: 2, suppressed: 1 });
  });

  it("suppresses (sends nothing) when every user is quiet", async () => {
    const deps = makeDeps({
      users: ["u1", "u2"],
      activity: {
        u1: { hasNewMemo: false, hasTreeChange: false },
        u2: { hasNewMemo: false, hasTreeChange: false },
      },
    });

    const result = await runSchedulerTick(deps);

    expect(deps.sendSuggestRequested).not.toHaveBeenCalled();
    expect(result).toEqual({ considered: 2, dispatched: 0, suppressed: 2 });
    expect(console.log).toHaveBeenCalled();
  });

  it("queries each user's activity against a one-hour suppression window", async () => {
    const deps = makeDeps({
      users: ["u1"],
      activity: { u1: { hasNewMemo: true, hasTreeChange: false } },
    });

    await runSchedulerTick(deps);

    const expectedSince = new Date(NOW - 60 * 60 * 1000);
    expect(deps.getUserActivity).toHaveBeenCalledWith("u1", expectedSince);
  });

  it("does nothing when no users have opted into evolution", async () => {
    const deps = makeDeps({ users: [] });

    const result = await runSchedulerTick(deps);

    expect(deps.getUserActivity).not.toHaveBeenCalled();
    expect(deps.sendSuggestRequested).not.toHaveBeenCalled();
    expect(result).toEqual({ considered: 0, dispatched: 0, suppressed: 0 });
  });
});
