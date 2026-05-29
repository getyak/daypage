import { NextRequest, NextResponse } from "next/server";
import { and, eq } from "drizzle-orm";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";
import { db } from "@/lib/db/client";
import { pages } from "@/lib/db/schema";

// drizzle-postgres needs the Node.js runtime (not Edge).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// ─── Public retrieval API (US-012) ────────────────────────────────────────────
// GET /api/v1/pages/:slug
//
// Part of the key-auth /api/v1 namespace. Returns a single wiki page belonging
// to the API key's owner. Authenticates with a DayPage API key
// (Authorization: Bearer <key>) carrying the "read" scope.
//   • invalid / missing key → 401
//   • valid key lacking "read" → 403
//   • page not found for this user → 404
// A successful authentication refreshes api_keys.last_used_at (handled inside
// authenticateApiKey).

function appBaseUrl(): string {
  const base =
    process.env.NEXT_PUBLIC_APP_URL ||
    process.env.NEXTAUTH_URL ||
    "http://localhost:3000";
  return base.replace(/\/$/, "");
}

function pageUrl(slug: string): string {
  return `${appBaseUrl()}/wiki/${encodeURIComponent(slug)}`;
}

type RouteContext = { params: Promise<{ slug: string }> };

export async function GET(req: NextRequest, ctx: RouteContext) {
  const auth = await authenticateApiKey(req);
  if (!auth) {
    return NextResponse.json(
      { error: "Unauthorized: a valid DayPage API key is required" },
      { status: 401, headers: { "WWW-Authenticate": "Bearer" } }
    );
  }
  if (!hasScope(auth, "read")) {
    return NextResponse.json(
      { error: "Forbidden: API key lacks 'read' scope" },
      { status: 403 }
    );
  }

  const { slug } = await ctx.params;

  const rows = await db
    .select({
      slug: pages.slug,
      title: pages.title,
      type: pages.type,
      status: pages.status,
      domain_id: pages.domain_id,
      body_md: pages.body_md,
      updated_at: pages.updated_at,
    })
    .from(pages)
    .where(and(eq(pages.slug, slug), eq(pages.user_id, auth.userId)))
    .limit(1);

  const page = rows[0];
  if (!page) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }

  return NextResponse.json({
    page: {
      slug: page.slug,
      title: page.title,
      type: page.type,
      status: page.status,
      domain_id: page.domain_id,
      body_md: page.body_md ?? "",
      url: pageUrl(page.slug),
      updated_at:
        page.updated_at instanceof Date
          ? page.updated_at.toISOString()
          : page.updated_at,
    },
  });
}
