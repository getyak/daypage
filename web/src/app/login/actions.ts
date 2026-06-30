"use server";

import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";

export type MagicLinkState =
  | { status: "idle" }
  | { status: "sent"; email: string }
  | { status: "error"; message: string };

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
  const h = await headers();
  const host =
    h.get("x-forwarded-host") ?? h.get("host") ?? "localhost:13000";
  const proto = h.get("x-forwarded-proto") ?? "http";
  const emailRedirectTo = `${proto}://${host}/api/auth/callback?next=/today`;

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
