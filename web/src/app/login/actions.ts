"use server";
import { signIn } from "@/auth";
import { AuthError } from "next-auth";

export type MagicLinkState =
  | { status: "idle" }
  | { status: "sent"; email: string }
  | { status: "error"; message: string };

export async function sendMagicLink(
  _prev: MagicLinkState,
  formData: FormData
): Promise<MagicLinkState> {
  const email = (formData.get("email") as string | null)?.trim() ?? "";
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return { status: "error", message: "Please enter a valid email address." };
  }
  try {
    await signIn("nodemailer", { email, redirectTo: "/home" });
    return { status: "sent", email };
  } catch (error) {
    // NextAuth throws NEXT_REDIRECT when the magic link email is sent
    // successfully and auth wants to redirect to /api/auth/verify-request.
    // Intercept it so we can show our own branded "check your inbox" UI.
    if (
      error != null &&
      typeof error === "object" &&
      "digest" in error &&
      typeof (error as { digest: unknown }).digest === "string" &&
      (error as { digest: string }).digest.startsWith("NEXT_REDIRECT")
    ) {
      return { status: "sent", email };
    }
    if (error instanceof AuthError) {
      return {
        status: "error",
        message: "Failed to send sign-in link. Please try again.",
      };
    }
    throw error;
  }
}
