import { describe, it, expect, vi, beforeEach } from "vitest";

// suggester-run.ts imports db/client, the suggester, policy, and the telegram
// adapter at module load — all of which would otherwise need a real DATABASE_URL
// / network. Stub the heavy module-load side effects; the pipeline itself takes
// its dependencies via injection, so we drive it directly with mocks.
vi.mock("@/lib/db/client", () => ({ db: {} }));
vi.mock("@/lib/inngest/client", () => ({
  inngest: { createFunction: vi.fn(() => ({})) },
}));

import {
  runSuggesterPipeline,
  type SuggesterDeps,
} from "@/lib/inngest/functions/suggester-run";

// A fake step runner that records the order of step ids and just invokes the
// thunk inline (Inngest memoizes/retries; for ordering we only need execution
// order).
function makeFakeStep() {
  const order: string[] = [];
  const step = async <T>(id: string, fn: () => Promise<T>): Promise<T> => {
    order.push(id);
    return fn();
  };
  return { step, order };
}

function makeDeps(over: Partial<SuggesterDeps> = {}): SuggesterDeps {
  return {
    checkBudget: vi.fn(async () => ({
      allowed: true,
      spent: 0,
      limit: 100_000,
      scope: "daily" as const,
    })),
    generateSuggestions: vi.fn(async () => ({
      suggestions: [
        { id: "s1", title: "Write tests", rationale: "coverage gap" },
      ] as never,
      tokens_in: 10,
      tokens_out: 20,
      degraded: false,
      perTreeBudgetTokens: 4000,
      skipped: false,
    })),
    resolveTelegramChatId: vi.fn(async () => "12345"),
    sendSuggestions: vi.fn(async () => ({ ok: true, messageId: 99 }) as const),
    ...over,
  };
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("runSuggesterPipeline", () => {
  it("runs the steps in order: budget → generate → resolve → notify", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps();

    const result = await runSuggesterPipeline("user-1", step, deps);

    expect(order).toEqual([
      "check-budget",
      "generate",
      "resolve-chat",
      "notify",
    ]);
    expect(deps.checkBudget).toHaveBeenCalledWith("user-1");
    expect(deps.generateSuggestions).toHaveBeenCalledWith({ userId: "user-1" });
    expect(deps.sendSuggestions).toHaveBeenCalledWith({
      chatId: "12345",
      suggestions: [
        { id: "s1", title: "Write tests", rationale: "coverage gap" },
      ],
    });
    expect(result).toEqual({
      skipped: false,
      userId: "user-1",
      suggestions: 1,
      delivered: true,
      messageId: 99,
    });
  });

  it("skips before generating when over budget, and logs", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps({
      checkBudget: vi.fn(async () => ({
        allowed: false,
        spent: 200,
        limit: 100,
        scope: "daily" as const,
      })),
    });

    const result = await runSuggesterPipeline("user-1", step, deps);

    // Only the budget step ran — generate/resolve/notify never reached.
    expect(order).toEqual(["check-budget"]);
    expect(deps.generateSuggestions).not.toHaveBeenCalled();
    expect(deps.sendSuggestions).not.toHaveBeenCalled();
    expect(result).toMatchObject({
      skipped: true,
      reason: "over-budget",
      spent: 200,
      limit: 100,
    });
    expect(console.log).toHaveBeenCalled();
  });

  it("skips notify when there are no suggestions", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps({
      generateSuggestions: vi.fn(async () => ({
        suggestions: [] as never,
        tokens_in: 5,
        tokens_out: 5,
        degraded: true,
        perTreeBudgetTokens: 4000,
        skipped: false,
      })),
    });

    const result = await runSuggesterPipeline("user-1", step, deps);

    expect(order).toEqual(["check-budget", "generate"]);
    expect(deps.resolveTelegramChatId).not.toHaveBeenCalled();
    expect(deps.sendSuggestions).not.toHaveBeenCalled();
    expect(result).toMatchObject({ skipped: true, reason: "no-suggestions" });
  });

  it("skips notify when the user has no linked Telegram chat", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps({
      resolveTelegramChatId: vi.fn(async () => null),
    });

    const result = await runSuggesterPipeline("user-1", step, deps);

    expect(order).toEqual(["check-budget", "generate", "resolve-chat"]);
    expect(deps.sendSuggestions).not.toHaveBeenCalled();
    expect(result).toMatchObject({
      skipped: true,
      reason: "no-telegram-chat",
    });
  });

  it("surfaces a failed delivery without throwing", async () => {
    const { step } = makeFakeStep();
    const deps = makeDeps({
      sendSuggestions: vi.fn(async () =>
        ({
          ok: false,
          error: "TELEGRAM_BOT_TOKEN not configured",
        }) as const
      ),
    });

    const result = await runSuggesterPipeline("user-1", step, deps);

    expect(result).toMatchObject({
      skipped: false,
      delivered: false,
      messageId: null,
    });
    expect(console.error).toHaveBeenCalled();
  });

  it("returns early without any steps when userId is missing", async () => {
    const { step, order } = makeFakeStep();
    const deps = makeDeps();

    const result = await runSuggesterPipeline(undefined, step, deps);

    expect(order).toEqual([]);
    expect(deps.checkBudget).not.toHaveBeenCalled();
    expect(result).toEqual({ skipped: true, reason: "missing-userId" });
  });
});
