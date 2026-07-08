import "server-only";
import { redirect } from "next/navigation";
import { eq } from "drizzle-orm";
import { createClient } from "@/lib/supabase/server";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";

// Drop-in replacement for the legacy NextAuth `auth()` helper. Returns a shape
// compatible with the `session.user.email` access pattern used throughout the
// codebase, but the underlying source of truth is Supabase Auth.
//
// Why this shape: 80+ route handlers and pages were written against the
// NextAuth API. Preserving `{ user: { email, id, name } }` lets the migration
// stay an import-path swap instead of a structural rewrite.

export interface SessionUser {
  id: string;
  email: string | null;
  name: string | null;
}

export interface Session {
  user: SessionUser;
}

export async function auth(): Promise<Session | null> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  return {
    user: {
      id: user.id,
      email: user.email ?? null,
      name:
        (user.user_metadata?.name as string | undefined) ??
        (user.user_metadata?.full_name as string | undefined) ??
        null,
    },
  };
}

// Resolve the internal `users.id` for a given auth email. Callers typically
// already hold `session.user.email` from `auth()`; this keeps the DB lookup in
// one place instead of the copy it used to be in every route handler.
export async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

// Convenience: sign out via Supabase. Mirrors NextAuth's `signOut({ redirectTo })`
// signature so the existing server-action call sites work unchanged.
export async function signOut(opts?: { redirectTo?: string }): Promise<void> {
  const supabase = await createClient();
  await supabase.auth.signOut();
  if (opts?.redirectTo) redirect(opts.redirectTo);
}
