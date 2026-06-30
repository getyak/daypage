"use server";

import { signOut } from "@/lib/auth/session";

export async function signOutAction(): Promise<void> {
  await signOut({ redirectTo: "/" });
}
