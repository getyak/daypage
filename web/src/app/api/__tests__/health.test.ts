import { describe, it, expect, vi } from "vitest";

// Mock DB: default healthy
const mockExecute = vi.fn().mockResolvedValue([{ "?column?": 1 }]);
vi.mock("@/lib/db/client", () => ({
  db: { execute: mockExecute },
}));
vi.mock("drizzle-orm", async (importOriginal) => {
  const real = await importOriginal<typeof import("drizzle-orm")>();
  return { ...real, sql: real.sql };
});

describe("GET /api/health", () => {
  it("returns 200 with expected shape when DB is connected", async () => {
    mockExecute.mockResolvedValueOnce([{ "?column?": 1 }]);
    const { GET } = await import("../health/route");
    const res = await GET();
    expect(res.status).toBe(200);

    const body = await res.json() as { status: string; timestamp: string; db: string };
    expect(body.status).toBe("ok");
    expect(body.db).toBe("connected");
    expect(typeof body.timestamp).toBe("string");
    expect(new Date(body.timestamp).getTime()).not.toBeNaN();
  });

  it("returns 503 with db:error when DB is unreachable", async () => {
    mockExecute.mockRejectedValueOnce(new Error("connection refused"));
    const { GET } = await import("../health/route");
    const res = await GET();
    expect(res.status).toBe(503);

    const body = await res.json() as { status: string; db: string };
    expect(body.status).toBe("degraded");
    expect(body.db).toBe("error");
  });
});
