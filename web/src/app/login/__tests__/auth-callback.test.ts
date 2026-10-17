import { beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

const mocks = vi.hoisted(() => ({ exchange: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ auth: { exchangeCodeForSession: mocks.exchange } }),
}));
import { GET } from "@/app/api/auth/callback/route";

beforeEach(() => mocks.exchange.mockReset());

describe("auth callback safe redirect", () => {
  it.each(["error_description=synthetic-private-detail", "error=access_denied", "error_description="])(
    "converts provider errors to a static verification code (%s)",
    async (query) => {
      const response = await GET(new NextRequest(`http://localhost:13000/api/auth/callback?${query}`));
      const location = new URL(response.headers.get("location")!);
      expect(location.pathname).toBe("/login");
      expect(location.search).toBe("?error=Verification");
      expect(mocks.exchange).not.toHaveBeenCalled();
    },
  );

  it("does not disclose exchange errors in Location", async () => {
    mocks.exchange.mockResolvedValue({ error: { message: "synthetic-private-detail" } });
    const response = await GET(new NextRequest("http://localhost:13000/api/auth/callback?code=synthetic"));
    expect(response.headers.get("location")).toBe("http://localhost:13000/login?error=Verification");
  });

  it("uses the shared reading default after successful exchange", async () => {
    mocks.exchange.mockResolvedValue({ error: null });
    const response = await GET(new NextRequest("http://localhost:13000/api/auth/callback?code=synthetic&next=https%3A%2F%2Fevil.example"));
    expect(response.headers.get("location")).toBe("http://localhost:13000/memos");
  });
});
