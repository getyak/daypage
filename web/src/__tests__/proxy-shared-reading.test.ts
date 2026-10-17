// Proxy contract for the shared reading surface (issue #884 P2 + /memos gate).
//
// 1. The forwarded REQUEST header `x-pathname` carries the actual canonical
//    pathname+query on every response recreation (Supabase cookie refresh), and
//    a client-supplied `x-pathname` is never trusted.
// 2. Anonymous /memos and /memos/[id] deep links redirect to /login with a safe
//    FULL callback (path + query).
// 3. Rotated Supabase cookies survive every response recreation, including the
//    gate redirects.

import { describe, it, expect, vi, beforeEach, afterAll } from "vitest";
import { NextRequest } from "next/server";

const mocks = vi.hoisted(() => ({
  getUser: vi.fn(),
}));

vi.mock("@supabase/ssr", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@supabase/ssr")>();
  return {
    ...actual,
    createServerClient: (
      _url: string,
      _key: string,
      options: { cookies: { getAll(): unknown; setAll(cookies: unknown[]): void } },
    ) => ({
      auth: {
        getUser: () => mocks.getUser(options),
      },
    }),
  };
});

import { proxy } from "@/proxy";

const PREVIOUS_ENV = {
  url: process.env.NEXT_PUBLIC_SUPABASE_URL,
  key: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
};
process.env.NEXT_PUBLIC_SUPABASE_URL = "https://synthetic-project.supabase.co";
process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "synthetic-anon-key";

afterAll(() => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = PREVIOUS_ENV.url;
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = PREVIOUS_ENV.key;
});

interface SetCookieBatch {
  name: string;
  value: string;
  options?: Record<string, unknown>;
}

function request(
  path: string,
  init: { user?: { id: string } | null; headers?: Record<string, string>; rotate?: SetCookieBatch[][] } = {},
): NextRequest {
  const { user = { id: "11111111-2222-4333-8444-555555555555" }, headers = {}, rotate = [] } = init;
  mocks.getUser.mockImplementation(
    async (options: { cookies: { setAll(cookies: SetCookieBatch[]): void } }) => {
      for (const batch of rotate) options.cookies.setAll(batch);
      return { data: { user }, error: null };
    },
  );
  return new NextRequest(`http://127.0.0.1:13000${path}`, { headers });
}

beforeEach(() => {
  vi.clearAllMocks();
});

function forwardedPathname(res: Response): string | null {
  return res.headers.get("x-middleware-request-x-pathname");
}

describe("proxy: forwarded request header", () => {
  it("forwards the actual canonical pathname+query and ignores a client-supplied x-pathname", async () => {
    const res = await proxy(
      request("/memos?tag=%23a%2Cb", {
        headers: { "x-pathname": "/evil", cookie: "sb-old=stale" },
      }),
    );
    // `NextResponse.next({ request: { headers } })` delivers these to the app
    // router; the layout reads `x-pathname` from the request headers.
    expect(forwardedPathname(res)).toBe("/memos?tag=%23a%2Cb");
    expect(res.headers.get("x-middleware-override-headers") ?? "").toContain("x-pathname");
  });

  it("re-applies the canonical header across every Supabase cookie-refresh recreation", async () => {
    const res = await proxy(
      request("/memos/11111111-2222-4333-8444-555555555555?x=1", {
        rotate: [
          [{ name: "sb-rot-1", value: "v1", options: { path: "/", maxAge: 3600 } }],
          [{ name: "sb-rot-2", value: "v2", options: { path: "/", maxAge: 3600 } }],
        ],
      }),
    );
    expect(forwardedPathname(res)).toBe(
      "/memos/11111111-2222-4333-8444-555555555555?x=1",
    );
    // Both rotation batches survive the response recreation — none dropped.
    const setCookies = res.headers.getSetCookie();
    expect(setCookies.some((c) => c.startsWith("sb-rot-1=v1"))).toBe(true);
    expect(setCookies.some((c) => c.startsWith("sb-rot-2=v2"))).toBe(true);
  });

  it("lets authenticated /memos requests and public routes pass through", async () => {
    const app = await proxy(request("/memos"));
    expect(app.headers.get("x-middleware-next")).toBe("1");

    const login = await proxy(request("/login", { user: null }));
    expect(login.headers.get("x-middleware-next")).toBe("1");
  });
});

describe("proxy: /memos gate with safe full callback", () => {
  it("preserves rotated cookies during the Chinese first-visit redirect", async () => {
    const res = await proxy(request("/", {
      headers: { "accept-language": "zh-CN,zh;q=0.9" },
      rotate: [[{ name: "sb-refreshed", value: "rotated", options: { path: "/", httpOnly: true } }]],
    }));
    expect(res.status).toBe(307);
    expect(new URL(res.headers.get("location")!).pathname).toBe("/zh");
    expect(res.headers.getSetCookie().some((c) => c.startsWith("sb-refreshed=rotated"))).toBe(true);
    expect(res.headers.getSetCookie().some((c) => c.startsWith("daypage-lang=zh"))).toBe(true);
    expect(res.headers.get("vary")).toContain("Accept-Language, Cookie");
  });
  it("redirects anonymous /memos?tag=… deep links to /login with the full callback", async () => {
    const res = await proxy(
      request("/memos?tag=%23a%2Cb&cursor=abc", {
        user: null,
        headers: { "x-pathname": "/evil" },
      }),
    );
    expect(res.status).toBe(307);
    const target = new URL(res.headers.get("location") ?? "", "http://127.0.0.1:13000");
    expect(target.pathname).toBe("/login");
    // Full path + query preserved; the spoofed header is not used.
    expect(target.searchParams.get("callbackUrl")).toBe("/memos?tag=%23a%2Cb&cursor=abc");
  });

  it("redirects anonymous memo detail deep links with their query intact", async () => {
    const detailId = "11111111-2222-4333-8444-555555555555";
    const res = await proxy(
      request(`/memos/${detailId}?x=1`, { user: null }),
    );
    expect(res.status).toBe(307);
    const target = new URL(res.headers.get("location") ?? "", "http://127.0.0.1:13000");
    expect(target.pathname).toBe("/login");
    expect(target.searchParams.get("callbackUrl")).toBe(`/memos/${detailId}?x=1`);
  });

  it("preserves rotated Supabase cookies on the gate redirect", async () => {
    const res = await proxy(
      request("/memos", {
        user: null,
        rotate: [[{ name: "sb-rot-3", value: "v3", options: { path: "/", maxAge: 3600 } }]],
      }),
    );
    expect(res.status).toBe(307);
    expect(res.headers.getSetCookie().some((c) => c.startsWith("sb-rot-3=v3"))).toBe(true);
  });

  it("does not gate the tag catalogue behind a fixed account — no cookie means login, never auto-sign-in", async () => {
    const res = await proxy(request("/memos?tag=%23unused", { user: null }));
    expect(res.status).toBe(307);
    const location = res.headers.get("location") ?? "";
    expect(location).toContain("/login");
    expect(location).not.toContain("password");
  });
});
