import NextAuth from "next-auth";
import Apple from "next-auth/providers/apple";
import Credentials from "next-auth/providers/credentials";
import Nodemailer from "next-auth/providers/nodemailer";
import { DrizzleAdapter } from "@auth/drizzle-adapter";
import { eq } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  users,
  accounts,
  sessions,
  verificationTokens,
} from "@/lib/db/schema";
import { seedDevUser } from "@/lib/seed-dev";

// Dev-only credentials login for E2E. Toggle with NODE_ENV=development
// or E2E_DEV_LOGIN=1. Never enabled in production builds.
const isDevLogin =
  process.env.NODE_ENV === "development" || process.env.E2E_DEV_LOGIN === "1";

export const { handlers, auth, signIn, signOut } = NextAuth({
  adapter: DrizzleAdapter(db, {
    usersTable: users,
    accountsTable: accounts,
    sessionsTable: sessions,
    verificationTokensTable: verificationTokens,
  }),
  // NextAuth v5 + Credentials provider requires JWT sessions; the DrizzleAdapter
  // cannot persist a session row from a Credentials authorize() callback.
  // Production keeps the database strategy so magic-link / Apple flows are
  // untouched; dev flips to JWT only so the E2E shortcut works.
  session: { strategy: isDevLogin ? "jwt" : "database" },
  providers: [
    Apple({
      clientId: process.env.APPLE_CLIENT_ID ?? "",
      clientSecret: process.env.APPLE_CLIENT_SECRET ?? "",
    }),
    Nodemailer({
      server: {
        host: process.env.SUPABASE_SMTP_HOST ?? "localhost",
        port: Number(process.env.SUPABASE_SMTP_PORT ?? "2500"),
        auth: {
          user: process.env.SUPABASE_SMTP_USER ?? "",
          pass: process.env.SUPABASE_SMTP_PASS ?? "",
        },
      },
      from: process.env.SUPABASE_SMTP_FROM ?? "noreply@daypage.local",
    }),
    ...(isDevLogin
      ? [
          Credentials({
            id: "dev",
            name: "Dev Login",
            credentials: {
              email: { label: "Email", type: "email" },
            },
            async authorize(credentials) {
              const email = String(credentials?.email ?? "")
                .trim()
                .toLowerCase();
              if (!email) return null;
              const found = await db
                .select()
                .from(users)
                .where(eq(users.email, email))
                .limit(1);
              if (found[0]) {
                return {
                  id: found[0].id,
                  email: found[0].email ?? email,
                  name: found[0].name ?? null,
                };
              }
              const inserted = await db
                .insert(users)
                .values({ email, name: email.split("@")[0] })
                .returning();
              return {
                id: inserted[0].id,
                email: inserted[0].email ?? email,
                name: inserted[0].name ?? null,
              };
            },
          }),
        ]
      : []),
  ],
  callbacks: {
    async session({ session, token, user }) {
      // JWT mode (dev): user comes via token.sub
      // Database mode (prod): user is the DB row
      if (session.user) {
        if (token?.sub) session.user.id = token.sub;
        else if (user?.id) session.user.id = user.id;
      }
      return session;
    },
  },
  pages: {
    signIn: "/login",
  },
});
