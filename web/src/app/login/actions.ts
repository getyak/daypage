"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { safeNextPath } from "@/lib/auth/safe-next";

export type MagicLinkState =
  | { status: "idle" }
  | { status: "sent"; email: string }
  | { status: "error"; message: string };

export type PasswordState =
  | { status: "idle" }
  | { status: "error"; message: string };

// Generic safe copy only: never the typed password, the typed email, raw
// Supabase Auth errors, or anything from the request/logs.
const PASSWORD_GENERIC_ERROR =
  "Unable to sign in with that email and password. Please try again.";
const PASSWORD_MISSING_ERROR = "Please enter your email address and password.";

/**
 * Standard email/password sign-in: the typed credentials go straight to the
 * ordinary SSR Supabase password flow (cookie-bound client — the session
 * persists via cookies). No fixed password, no default account and no dev
 * bypass; failures return a single generic message and success redirects to
 * the safe same-origin callback (default `/memos`).
 */
export async function passwordSignIn(
  _prev: PasswordState,
  formData: FormData,
): Promise<PasswordState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const next = safeNextPath(
    typeof formData.get("callbackUrl") === "string"
      ? String(formData.get("callbackUrl"))
      : undefined,
    "/memos",
  );

  if (!email || !password) {
    return { status: "error", message: PASSWORD_MISSING_ERROR };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    return { status: "error", message: PASSWORD_GENERIC_ERROR };
  }
  redirect(next);
}

// Supabase magic-link replacement for the legacy NextAuth nodemailer path.
// Signature preserved so EmailSignInForm useActionState keeps working.
export async function sendMagicLink(
  _prev: MagicLinkState,
  formData: FormData,
): Promise<MagicLinkState> {
  const email = (formData.get("email") as string | null)?.trim() ?? "";
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return { status: "error", message: "Please enter a valid email address." };
  }

  const supabase = await createClient();
  const callbackUrl = safeNextPath(
    typeof formData.get("callbackUrl") === "string"
      ? String(formData.get("callbackUrl"))
      : undefined,
    "/memos",
  );
  const h = await headers();
  const host =
    h.get("x-forwarded-host") ?? h.get("host") ?? "localhost:13000";
  const proto = h.get("x-forwarded-proto") ?? "http";
  const emailRedirectTo = `${proto}://${host}/api/auth/callback?next=${encodeURIComponent(callbackUrl)}`;

  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo, shouldCreateUser: true },
  });

  if (error) {
    return {
      status: "error",
      message: "Failed to send sign-in link. Please try again.",
    };
  }
  return { status: "sent", email };
}
