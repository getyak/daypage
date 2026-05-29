import { NextRequest, NextResponse } from "next/server";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";
import { retrievePages } from "@/lib/ai/rag";

// rag.ts / drizzle-postgres need the Node.js runtime (not Edge).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// ─── Public retrieval API (US-012) ────────────────────────────────────────────
// GET /api/v1/search?q=<query>&top_k=<n>
//
// Part of the key-auth /api/v1 namespace — distinct from the internal
// session-auth API under /api/pages, /api/memos, … This namespace is for
// external developers / agents and authenticates with a DayPage API key
// (Authorization: Bearer <key>) carrying the "read" scope.
//   • invalid / missing key → 401
//   • valid key lacking "read" → 403
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

function snippet(body: string | null, max = 280): string {
  if (!body) return "";
  const trimmed = body.trim();
  return trimmed.length > max ? `${trimmed.slice(0, max)}…` : trimmed;
}

export async function GET(req: NextRequest) {
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

  const query = (req.nextUrl.searchParams.get("q") ?? "").trim();
  if (!query) {
    return NextResponse.json(
      { error: "Bad Request: 'q' query parameter is required" },
      { status: 400 }
    );
  }

  let topK = 8;
  const rawTopK = req.nextUrl.searchParams.get("top_k");
  if (rawTopK !== null) {
    const n = Number(rawTopK);
    if (!Number.isFinite(n) || n < 1) {
      return NextResponse.json(
        { error: "Bad Request: 'top_k' must be an integer >= 1" },
        { status: 400 }
      );
    }
    topK = Math.min(20, Math.floor(n));
  }

  const hits = await retrievePages(auth.userId, query, { topK });

  const results = hits.map((p) => ({
    slug: p.slug,
    title: p.title,
    type: p.type,
    score: Number(p.score.toFixed(4)),
    snippet: snippet(p.body_md),
    url: pageUrl(p.slug),
  }));

  return NextResponse.json({ query, results });
}
