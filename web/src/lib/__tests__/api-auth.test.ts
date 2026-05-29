import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const { mockDb } = vi.hoisted(() => ({
  mockDb: { select: vi.fn(), update: vi.fn() },
}));
vi.mock("@/lib/db/client", () => ({ db: mockDb }));

import { authenticateApiKey, hasScope } from "@/lib/api-auth";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRequest(key?: string): Request {
  return new Request("http://localhost/api/v1/search?q=x", {
    method: "GET",
    headers: key ? { Authorization: `Bearer ${key}` } : {},
  });
}

function mockSelectResult(rows: unknown[]) {
  mockDb.select.mockReturnValue({
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(rows),
  });
}

// db.update(...).set(...).where(...) is awaited via .catch — model it as a
// resolved thenable so the fire-and-forget update doesn't reject.
function makeUpdateSpy() {
  const where = vi.fn().mockResolvedValue(undefined);
  const set = vi.fn().mockReturnValue({ where });
  mockDb.update.mockReturnValue({ set });
  return { set, where };
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ── Auth ────────────────────────────────────────────────────────────────────

describe("authenticateApiKey", () => {
  it("returns null without a Bearer header", async () => {
    const auth = await authenticateApiKey(makeRequest());
    expect(auth).toBeNull();
    expect(mockDb.select).not.toHaveBeenCalled();
  });

  it("returns null when no key matches", async () => {
    mockSelectResult([]);
    const auth = await authenticateApiKey(makeRequest("nope"));
    expect(auth).toBeNull();
  });

  it("returns userId + scopes and refreshes last_used_at on a hit", async () => {
    mockSelectResult([
      { id: "key-1", user_id: "user-1", scopes: ["read"] },
    ]);
    const update = makeUpdateSpy();

    const auth = await authenticateApiKey(makeRequest("secret"));

    expect(auth).toEqual({ userId: "user-1", scopes: ["read"] });
    // last_used_at is bumped for the matched key.
    expect(mockDb.update).toHaveBeenCalledTimes(1);
    const setArg = update.set.mock.calls[0][0];
    expect(setArg.last_used_at).toBeInstanceOf(Date);
  });

  it("does not touch last_used_at when the key is invalid", async () => {
    mockSelectResult([]);
    await authenticateApiKey(makeRequest("nope"));
    expect(mockDb.update).not.toHaveBeenCalled();
  });
});

// ── Scope enforcement ─────────────────────────────────────────────────────────

describe("hasScope", () => {
  it("grants the exact scope", () => {
    expect(hasScope({ userId: "u", scopes: ["read"] }, "read")).toBe(true);
  });

  it("denies a missing scope", () => {
    expect(hasScope({ userId: "u", scopes: ["read"] }, "write")).toBe(false);
  });

  it("admin implies every scope", () => {
    expect(hasScope({ userId: "u", scopes: ["admin"] }, "write")).toBe(true);
  });
});
