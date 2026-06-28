import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { recompilePageWithPerspective } from "@/lib/pages/recompile";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type RouteContext = { params: Promise<{ slug: string }> };

const Body = z.object({
  perspective_prompt: z.string().trim().min(1).max(800),
});

// POST /api/pages/:slug/recompile — US-030: re-compile this page through a
// custom perspective prompt and return the new title + body.
export async function POST(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const { slug } = await ctx.params;

  const raw: unknown = await req.json().catch(() => null);
  const parsed = Body.safeParse(raw);
  if (!parsed.success) {
    return badRequest(
      parsed.error.issues[0]?.message ?? "perspective_prompt required"
    );
  }

  try {
    const result = await recompilePageWithPerspective(
      userId,
      slug,
      parsed.data.perspective_prompt
    );
    if (!result.ok) return notFound();
    return NextResponse.json({
      ok: true,
      slug: result.slug,
      title: result.title,
      body_md: result.body_md,
    });
  } catch (err) {
    console.error(`[pages/recompile] ${slug}: ${String(err)}`);
    return NextResponse.json(
      { error: "Recompile failed. Please try again." },
      { status: 502 }
    );
  }
}
