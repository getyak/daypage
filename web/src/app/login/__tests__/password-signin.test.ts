// Password/magic-link sign-in contract (issue #884 shared-backend cutover).
//
// The typed user password must reach the ordinary SSR Supabase password flow
// verbatim; failures return ONE generic safe message; the landing default is
// /memos with the existing safe callback rules; and no fixed password, default
// account or dev shortcut may exist anywhere in the login surface.

import { describe, it, expect, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

const mocks = vi.hoisted(() => ({
  signInWithPassword: vi.fn(),
  signInWithOtp: vi.fn(),
  redirect: vi.fn(),
}));

vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({
    auth: {
      signInWithPassword: mocks.signInWithPassword,
      signInWithOtp: mocks.signInWithOtp,
    },
  }),
}));

vi.mock("next/headers", () => ({
  headers: async () =>
    new Headers({ host: "127.0.0.1:13000", "x-forwarded-proto": "http" }),
}));

vi.mock("next/navigation", () => ({
  redirect: (to: string) => {
    mocks.redirect(to);
    throw new Error(`__redirect__:${to}`);
  },
  notFound: () => {
    throw new Error("__notFound__");
  },
}));

import { passwordSignIn, sendMagicLink, type PasswordState } from "../actions";
import { PasswordSignInForm } from "../PasswordSignInForm";
import LoginPage from "../page";

const IDLE: PasswordState = { status: "idle" };

function form(fields: Record<string, string>): FormData {
  const fd = new FormData();
  for (const [key, value] of Object.entries(fields)) fd.append(key, value);
  return fd;
}

async function expectRedirect(pending: Promise<unknown>): Promise<string> {
  try {
    await pending;
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    expect(message).toContain("__redirect__:");
    return message.slice("__redirect__:".length);
  }
  throw new Error("expected a redirect, but the action returned");
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.signInWithPassword.mockResolvedValue({ error: null });
  mocks.signInWithOtp.mockResolvedValue({ error: null });
});

describe("login page query boundaries", () => {
  it("renders repeated callback parameters using the safe default", async () => {
    const tree = await LoginPage({
      searchParams: Promise.resolve({ callbackUrl: ["/memos", "/home"] }),
    });
    const html = renderToStaticMarkup(tree);
    expect(html).toContain('name="callbackUrl" value="/memos"');
  });

  it.each(["__proto__", "constructor", ["Verification", "OAuthSignin"]])(
    "renders only a static generic error for untrusted error keys (%s)",
    async (error) => {
      const tree = await LoginPage({ searchParams: Promise.resolve({ error }) });
      const html = renderToStaticMarkup(tree);
      expect(html).toContain("Something went wrong. Please try again.");
    },
  );
});

describe("passwordSignIn server action", () => {
  it("sends the typed user password to the standard Supabase password flow and redirects to the safe callback", async () => {
    const target = await expectRedirect(
      passwordSignIn(
        IDLE,
        form({
          email: "person@example.com",
          password: "typed-secret-#1",
          callbackUrl: "/memos?tag=%23a%2Cb",
        }),
      ),
    );

    expect(mocks.signInWithPassword).toHaveBeenCalledTimes(1);
    expect(mocks.signInWithPassword).toHaveBeenCalledWith({
      email: "person@example.com",
      password: "typed-secret-#1",
    });
    // Safe same-origin callback preserved exactly.
    expect(target).toBe("/memos?tag=%23a%2Cb");
    expect(mocks.redirect).toHaveBeenCalledWith("/memos?tag=%23a%2Cb");
  });

  it("returns one generic safe error on auth failure and echoes nothing sensitive", async () => {
    mocks.signInWithPassword.mockResolvedValue({
      error: new Error("Invalid login credentials for person@example.com raw-detail"),
    });

    const state = await passwordSignIn(
      IDLE,
      form({ email: "person@example.com", password: "top-secret-pw", callbackUrl: "/memos" }),
    );

    expect(state.status).toBe("error");
    if (state.status !== "error") return;
    expect(state.message).toBe(
      "Unable to sign in with that email and password. Please try again.",
    );
    // No password, no typed email, no raw Auth error, no URL/log echo.
    expect(state.message).not.toContain("top-secret-pw");
    expect(state.message).not.toContain("person@example.com");
    expect(state.message).not.toContain("Invalid login");
    expect(state.message).not.toContain("raw-detail");
    expect(mocks.redirect).not.toHaveBeenCalled();
  });

  it("lands on /memos by default and rejects unsafe callbacks", async () => {
    // No callback → default /memos.
    expect(
      await expectRedirect(
        passwordSignIn(IDLE, form({ email: "a@b.co", password: "pw", callbackUrl: "" })),
      ),
    ).toBe("/memos");

    // Absolute and protocol-relative callbacks fall back to /memos.
    expect(
      await expectRedirect(
        passwordSignIn(
          IDLE,
          form({ email: "a@b.co", password: "pw", callbackUrl: "https://evil.example/x" }),
        ),
      ),
    ).toBe("/memos");
    expect(
      await expectRedirect(
        passwordSignIn(IDLE, form({ email: "a@b.co", password: "pw", callbackUrl: "//evil.example" })),
      ),
    ).toBe("/memos");
  });

  it("never falls back to a fixed password or default account", async () => {
    const missingEmail = await passwordSignIn(IDLE, form({ email: "", password: "typed-pw" }));
    expect(missingEmail.status).toBe("error");
    expect(mocks.signInWithPassword).not.toHaveBeenCalled();

    const missingPassword = await passwordSignIn(
      IDLE,
      form({ email: "person@example.com", password: "" }),
    );
    expect(missingPassword.status).toBe("error");
    expect(mocks.signInWithPassword).not.toHaveBeenCalled();
    expect(mocks.redirect).not.toHaveBeenCalled();
  });
});

describe("magic-link landing", () => {
  it("defaults the confirmation landing to /memos with the safe callback rules", async () => {
    await sendMagicLink(
      { status: "idle" },
      form({ email: "person@example.com", callbackUrl: "" }),
    );
    const first = mocks.signInWithOtp.mock.calls[0][0] as {
      options: { emailRedirectTo: string };
    };
    const redirectTo = new URL(first.options.emailRedirectTo);
    expect(redirectTo.pathname).toBe("/api/auth/callback");
    expect(redirectTo.searchParams.get("next")).toBe("/memos");

    await sendMagicLink(
      { status: "idle" },
      form({ email: "person@example.com", callbackUrl: "/memos?tag=%23a%2Cb" }),
    );
    const second = mocks.signInWithOtp.mock.calls[1][0] as {
      options: { emailRedirectTo: string };
    };
    expect(new URL(second.options.emailRedirectTo).searchParams.get("next")).toBe(
      "/memos?tag=%23a%2Cb",
    );

    await sendMagicLink(
      { status: "idle" },
      form({ email: "person@example.com", callbackUrl: "https://evil.example" }),
    );
    const third = mocks.signInWithOtp.mock.calls[2][0] as {
      options: { emailRedirectTo: string };
    };
    expect(new URL(third.options.emailRedirectTo).searchParams.get("next")).toBe("/memos");
  });
});

describe("login surface markup and fixed-credential removal", () => {
  it("renders an accessible email/password form with proper labels and autocomplete", () => {
    const html = renderToStaticMarkup(createElement(PasswordSignInForm, {}));
    expect(html).toContain('type="password"');
    expect(html).toContain('name="password"');
    expect(html).toContain('autoComplete="current-password"');
    expect(html).toContain('autoComplete="email"');
    expect(html).toContain('for="login-password"');
    expect(html).toContain('for="login-password-email"');
    expect(html).toContain('type="hidden"');
    expect(html).toContain('value="/memos"');
  });

  it("login page: password + Apple + magic link, default landing /memos, no dev shortcut", async () => {
    const el = await LoginPage({ searchParams: Promise.resolve({}) });
    const html = renderToStaticMarkup(el);
    expect(html).toContain('type="password"');
    expect(html).toContain("Continue with Apple");
    expect(html).toContain("Send magic link");
    expect(html).toContain('value="/memos"');
    // The fixed-password dev shortcut is gone — source of truth, not a mock.
    expect(html).not.toContain("devpassword");
    expect(html).not.toContain("dev@daypage.local");
    expect(html).not.toContain("Dev login");
  });

  it("login page keeps a safe requested callback in the hidden fields", async () => {
    const el = await LoginPage({
      searchParams: Promise.resolve({ callbackUrl: "/memos/123?x=1" }),
    });
    const html = renderToStaticMarkup(el);
    expect(html).toContain('value="/memos/123?x=1"');
  });

  it("has no fixed credentials, default account or dev bypass anywhere in login source", () => {
    for (const file of ["page.tsx", "actions.ts", "PasswordSignInForm.tsx", "EmailSignInForm.tsx"]) {
      const source = readFileSync(fileURLToPath(new URL(`../${file}`, import.meta.url)), "utf8");
      expect(source, file).not.toContain("devpassword");
      expect(source, file).not.toContain("dev@daypage.local");
      expect(source, file).not.toContain("ENABLE_E2E_DEV_LOGIN");
    }
  });
});
