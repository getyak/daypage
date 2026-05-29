import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { users, pages, page_links, inbox_items } from "@/lib/db/schema";
import { eq, and, isNull, sql } from "drizzle-orm";
import { llm, ProviderError } from "@/lib/ai";
import { cosineSim } from "@/lib/inngest/functions/schema-detect";
import { createHash } from "crypto";

// ─── Constants ────────────────────────────────────────────────────────────────

const PAGE_FETCH_LIMIT = 400;
// A cluster must hold at least this many pages to be a meaningful "topic".
export const MIN_GAP_CLUSTER_SIZE = 3;
// Two clusters are "should-connect" candidates only if their centroids are at
// least this similar — they are clearly about related things…
export const GAP_SIMILARITY_THRESHOLD = 0.6;
// …yet NOT so similar that they're really one topic that just hasn't woven yet.
export const GAP_SIMILARITY_CEILING = 0.92;
// Both clusters must have been written about over a span of at least this many
// days — "for weeks", not a single afternoon's burst.
export const MIN_SPAN_DAYS = 14;
// Cap LLM calls / inbox noise per run.
const MAX_GAPS_PER_USER = 3;
const IDEMPOTENCY_WINDOW_DAYS = 30;

const DAY_MS = 24 * 60 * 60 * 1000;

// ─── Types ──────────────────────────────────────────────────────────────────

interface GraphPage {
  id: string;
  title: string;
  vec: number[] | null;
  updated_at: Date;
  created_at: Date;
}

interface Cluster {
  pageIds: string[];
  titles: string[];
  centroid: number[];
  firstSeen: number; // ms
  lastSeen: number; // ms
}

interface GapPair {
  a: Cluster;
  b: Cluster;
  similarity: number;
}

// ─── Community detection ──────────────────────────────────────────────────────
// Connected components over the (undirected) page-link graph. Each component is
// a community: pages the user has *already* connected to one another.

export function detectCommunities(
  pageIds: string[],
  edges: { from: string; to: string }[]
): string[][] {
  const index = new Map<string, number>();
  pageIds.forEach((id, i) => index.set(id, i));

  const parent = pageIds.map((_, i) => i);

  function find(i: number): number {
    while (parent[i] !== i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  function union(i: number, j: number) {
    const pi = find(i);
    const pj = find(j);
    if (pi !== pj) parent[pi] = pj;
  }

  for (const e of edges) {
    const i = index.get(e.from);
    const j = index.get(e.to);
    if (i === undefined || j === undefined) continue;
    union(i, j);
  }

  const groups = new Map<number, string[]>();
  for (let i = 0; i < pageIds.length; i++) {
    const root = find(i);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root)!.push(pageIds[i]);
  }

  return Array.from(groups.values());
}

// ─── Centroid ─────────────────────────────────────────────────────────────────

function centroidOf(vecs: number[][]): number[] | null {
  if (vecs.length === 0) return null;
  const dim = vecs[0].length;
  const out = new Array(dim).fill(0);
  for (const v of vecs) {
    if (v.length !== dim) continue;
    for (let i = 0; i < dim; i++) out[i] += v[i];
  }
  for (let i = 0; i < dim; i++) out[i] /= vecs.length;
  return out;
}

// ─── Stable signature for a gap (order-independent) ────────────────────────────

export function gapSignature(aIds: string[], bIds: string[]): string {
  const keyA = [...aIds].sort().join(",");
  const keyB = [...bIds].sort().join(",");
  const ordered = keyA < keyB ? `${keyA}|${keyB}` : `${keyB}|${keyA}`;
  return createHash("sha256").update(ordered).digest("hex").slice(0, 16);
}

// ─── LLM: bridging question ─────────────────────────────────────────────────

async function generateBridge(
  aTitles: string[],
  bTitles: string[]
): Promise<{ title: string; question: string }> {
  const fmt = (ts: string[]) =>
    ts
      .slice(0, 8)
      .map((t, i) => `${i + 1}. ${t}`)
      .join("\n");

  const prompt = `You are a reflective thinking partner for a personal knowledge wiki. The user has written extensively about two separate topic clusters but has NEVER linked them together.

Cluster A:
${fmt(aTitles)}

Cluster B:
${fmt(bTitles)}

These two areas of their life/thinking seem related but disconnected. Write a single thought-provoking "bridging question" that invites them to explore the connection between A and B. It should feel like a curious friend noticing a pattern, not an interrogation. Be concrete and reference the actual themes.

Respond with JSON only: {"title": "short label (max 8 words) naming the connection", "question": "the bridging question (1-2 sentences)"}`;

  const res = await llm.chat(
    [
      {
        role: "system",
        content:
          "You are a reflective thinking partner. Respond with valid JSON only.",
      },
      { role: "user", content: prompt },
    ],
    { jsonMode: true, temperature: 0.7, maxTokens: 200 }
  );

  const stripped = res.content
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;
  if (typeof parsed.title !== "string" || typeof parsed.question !== "string") {
    throw new Error("Invalid bridge shape from LLM");
  }
  return { title: parsed.title, question: parsed.question };
}

// ─── Per-user gap detection ────────────────────────────────────────────────────

export async function detectGapsForUser(userId: string): Promise<{
  user_id: string;
  communities_found: number;
  gaps_found: number;
  suggestions: number;
}> {
  // Fetch live pages with embeddings.
  const rawPages = await db
    .select({
      id: pages.id,
      title: pages.title,
      embedding: pages.embedding,
      updated_at: pages.updated_at,
      created_at: pages.created_at,
    })
    .from(pages)
    .where(
      and(eq(pages.user_id, userId), sql`${pages.status} != 'archived'`)
    )
    .limit(PAGE_FETCH_LIMIT);

  if (rawPages.length < MIN_GAP_CLUSTER_SIZE * 2) {
    return {
      user_id: userId,
      communities_found: 0,
      gaps_found: 0,
      suggestions: 0,
    };
  }

  const pageMap = new Map<string, GraphPage>();
  for (const p of rawPages) {
    const vec = Array.isArray(p.embedding) && p.embedding.length > 0 ? p.embedding : null;
    pageMap.set(p.id, {
      id: p.id,
      title: p.title,
      vec,
      updated_at: p.updated_at,
      created_at: p.created_at,
    });
  }

  // Currently-valid links only (US-040: valid_to IS NULL = still holds).
  const links = await db
    .select({ from: page_links.from_page_id, to: page_links.to_page_id })
    .from(page_links)
    .where(and(eq(page_links.user_id, userId), isNull(page_links.valid_to)));

  const pageIds = Array.from(pageMap.keys());
  const components = detectCommunities(pageIds, links);

  // Build clusters with centroid + temporal span. Only keep communities that are
  // sizable AND have embeddings (so we can compare them).
  const clusters: Cluster[] = [];
  for (const comp of components) {
    if (comp.length < MIN_GAP_CLUSTER_SIZE) continue;
    const members = comp.map((id) => pageMap.get(id)!).filter(Boolean);
    const vecs = members.map((m) => m.vec).filter((v): v is number[] => !!v);
    if (vecs.length < MIN_GAP_CLUSTER_SIZE) continue;
    const centroid = centroidOf(vecs);
    if (!centroid) continue;

    let firstSeen = Infinity;
    let lastSeen = 0;
    for (const m of members) {
      firstSeen = Math.min(firstSeen, m.created_at.getTime());
      lastSeen = Math.max(lastSeen, m.updated_at.getTime());
    }

    clusters.push({
      pageIds: members.map((m) => m.id),
      titles: members.map((m) => m.title),
      centroid,
      firstSeen,
      lastSeen,
    });
  }

  if (clusters.length < 2) {
    return {
      user_id: userId,
      communities_found: components.filter((c) => c.length >= MIN_GAP_CLUSTER_SIZE)
        .length,
      gaps_found: 0,
      suggestions: 0,
    };
  }

  // Find should-connect cluster pairs: related (centroid similarity in the
  // sweet-spot band) but with NO link between them (guaranteed — they are
  // separate connected components) and each written about over a span of weeks.
  const gaps: GapPair[] = [];
  for (let i = 0; i < clusters.length; i++) {
    for (let j = i + 1; j < clusters.length; j++) {
      const a = clusters[i];
      const b = clusters[j];
      const spanA = (a.lastSeen - a.firstSeen) / DAY_MS;
      const spanB = (b.lastSeen - b.firstSeen) / DAY_MS;
      if (spanA < MIN_SPAN_DAYS || spanB < MIN_SPAN_DAYS) continue;

      const sim = cosineSim(a.centroid, b.centroid);
      if (sim < GAP_SIMILARITY_THRESHOLD || sim > GAP_SIMILARITY_CEILING) continue;

      gaps.push({ a, b, similarity: sim });
    }
  }

  gaps.sort((x, y) => y.similarity - x.similarity);
  const gapsFound = gaps.length;

  if (gapsFound === 0) {
    return {
      user_id: userId,
      communities_found: clusters.length,
      gaps_found: 0,
      suggestions: 0,
    };
  }

  // Idempotency: skip gaps we already surfaced (open or recently resolved).
  const cutoff = new Date(Date.now() - IDEMPOTENCY_WINDOW_DAYS * DAY_MS);
  const existing = await db
    .select({ payload: inbox_items.payload, created_at: inbox_items.created_at })
    .from(inbox_items)
    .where(and(eq(inbox_items.user_id, userId), eq(inbox_items.kind, "gap")));

  const seenSignatures = new Set<string>();
  for (const item of existing) {
    const payload = item.payload as Record<string, unknown> | null;
    const sig = payload && typeof payload.signature === "string" ? payload.signature : null;
    if (!sig) continue;
    // Suppress if still open/snoozed/resolved within the idempotency window.
    if (item.created_at >= cutoff) seenSignatures.add(sig);
  }

  let suggestions = 0;
  for (const gap of gaps) {
    if (suggestions >= MAX_GAPS_PER_USER) break;

    const sig = gapSignature(gap.a.pageIds, gap.b.pageIds);
    if (seenSignatures.has(sig)) continue;

    let bridge: { title: string; question: string };
    try {
      bridge = await generateBridge(gap.a.titles, gap.b.titles);
    } catch (err: unknown) {
      const msg =
        err instanceof ProviderError
          ? `${err.code}: ${err.message}`
          : String(err);
      console.error(`[gap-detect] user ${userId}: LLM error for gap ${sig}: ${msg}`);
      continue;
    }

    await db.insert(inbox_items).values({
      user_id: userId,
      kind: "gap",
      title: bridge.title,
      body: bridge.question,
      payload: {
        signature: sig,
        question: bridge.question,
        similarity: Math.round(gap.similarity * 1000) / 1000,
        cluster_a: {
          page_ids: gap.a.pageIds,
          titles: gap.a.titles.slice(0, 8),
        },
        cluster_b: {
          page_ids: gap.b.pageIds,
          titles: gap.b.titles.slice(0, 8),
        },
      },
      status: "open",
    });

    seenSignatures.add(sig);
    suggestions++;

    console.log(
      `[gap-detect] user ${userId}: bridging "${bridge.title}" across clusters of ${gap.a.pageIds.length}+${gap.b.pageIds.length} pages (sim ${gap.similarity.toFixed(2)}, sig ${sig})`
    );
  }

  return {
    user_id: userId,
    communities_found: clusters.length,
    gaps_found: gapsFound,
    suggestions,
  };
}

// ─── Inngest scheduled function ───────────────────────────────────────────────
// Daily structural-gap sweep. Runs after orphan-detect (04:00) so the two
// graph-analysis passes don't overlap.

export const gapDetect = inngest.createFunction(
  { id: "gap-detect", name: "Structural Gap Detection" },
  { cron: "0 5 * * *" }, // 05:00 UTC daily
  async ({ step }) => {
    const allUsers = await step.run("fetch-users", async () => {
      return db.select({ id: users.id }).from(users);
    });

    const results: {
      user_id: string;
      communities_found: number;
      gaps_found: number;
      suggestions: number;
    }[] = [];

    for (const user of allUsers) {
      const result = await step.run(`gap-detect-${user.id}`, async () => {
        return detectGapsForUser(user.id);
      });
      results.push(result);
    }

    return {
      processed_users: results.length,
      total_suggestions: results.reduce((sum, r) => sum + r.suggestions, 0),
      results,
    };
  }
);
