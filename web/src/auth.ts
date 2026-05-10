import NextAuth from "next-auth";
import Apple from "next-auth/providers/apple";
import Nodemailer from "next-auth/providers/nodemailer";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export const { handlers, auth, signIn, signOut } = NextAuth({
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
  ],
  callbacks: {
    async signIn({ user, account }) {
      if (!user.email) return false;
      const existing = await db
        .select({ id: users.id })
        .from(users)
        .where(eq(users.email, user.email))
        .limit(1);
      if (existing.length === 0) {
        await db.insert(users).values({
          email: user.email,
          name: user.name ?? null,
          avatarUrl: user.image ?? null,
          appleSub:
            account?.provider === "apple"
              ? (account.providerAccountId ?? null)
              : null,
        });
      }
      return true;
    },
    async session({ session }) {
      return session;
    },
  },
  pages: {
    signIn: "/login",
  },
});
