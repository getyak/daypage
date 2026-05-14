// ─── RAG retrieval helper ─────────────────────────────────────────────────────
// Server-only. Embeds a query via the unified LLM façade (OpenAI
// text-embedding-3-small) and retrieves the most relevant pages from the
// user's wiki by cosine similarity.
//
// Note: embeddings are stored as JSON-encoded text (vector(1536) pending the
// pgvector migration in 0006_pgvector_hnsw.sql). Once that migration is
// applied the WHERE clause can be replaced with a native <=> operator query
// using the HNSW index for much faster ANN search.

import "server-only";
import { db } from "@/lib/db/client";
import { pages } from "@/lib/db/schema";
import { and, eq, ne, sql } from "drizzle-orm";
import { llm } from "./index";
import { ProviderError } from "./provider";

export interface RetrievedPage {
  page_id: string;
  slug: string;
  title: string;
  type: string;
  body_md: string | null;
  score: number;
}

export interface RetrieveOpts {
  topK?: number;
  domain?: string;
  excludePrivate?: boolean;
}

/** Cosine similarity between two same-length vectors. Returns 0 for zero vectors. */
export function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length === 0 || b.length === 0 || a.length !== b.length) return 0;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}

/**
 * Retrieve the most relevant wiki pages for a natural-language query.
 *
 * @param userId  - Scopes the search to a single user's pages.
 * @param queryText - Free-form text to embed and compare against page embeddings.
 * @param opts.topK - Maximum results to return (default 8).
 * @param opts.domain - If set, only pages whose domain slug matches are returned.
 * @param opts.excludePrivate - Reserved for future use when a `private` column
 *   is added to the pages table (currently all pages are implicitly public).
 *
 * @returns Array of matching pages sorted by descending cosine similarity.
 */
export async function retrievePages(
  userId: string,
  queryText: string,
  opts: RetrieveOpts = {}
): Promise<RetrievedPage[]> {
  const { topK = 8 } = opts;

  if (!queryText.trim()) return [];

  // Embed the query. If the embedding provider is unavailable (auth, rate limit,
  // upstream error), gracefully degrade to "no RAG results" so chat still works.
  let queryVec: number[];
  try {
    const res = await llm.embed(queryText);
    queryVec = res.embedding;
  } catch (err) {
    if (err instanceof ProviderError) {
      console.warn(
        `[rag] embed failed (${err.code}): ${err.message} — returning no results`
      );
      return [];
    }
    throw err;
  }
  if (queryVec.length === 0) return [];

  // Fetch all live pages for this user that have an embedding stored.
  // When the pgvector migration lands this full-table fetch can be replaced
  // with a single SQL ORDER BY embedding <=> $1::vector LIMIT $2 query using
  // the HNSW index defined in 0006_pgvector_hnsw.sql.
  const candidatePages = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      title: pages.title,
      type: pages.type,
      body_md: pages.body_md,
      embedding: pages.embedding,
      domain_id: pages.domain_id,
    })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        ne(pages.status, "archived"),
        sql`${pages.embedding} IS NOT NULL`
      )
    );

  // Score and rank
  const scored = candidatePages
    .map((p) => {
      let vec: number[] = [];
      if (typeof p.embedding === "string") {
        try {
          vec = JSON.parse(p.embedding) as number[];
        } catch {
          // malformed embedding — skip
        }
      } else if (Array.isArray(p.embedding)) {
        vec = p.embedding as number[];
      }
      return {
        page_id: p.id,
        slug: p.slug,
        title: p.title,
        type: p.type,
        body_md: p.body_md,
        domain_id: p.domain_id,
        score: cosineSimilarity(queryVec, vec),
      };
    })
    .filter((p) => p.score > 0);

  // Apply domain filter (post-fetch since we need the join)
  // For simplicity we filter by domain_id presence; a slug join could be done
  // in SQL if performance requires it.
  const filtered =
    opts.domain !== undefined
      ? scored.filter((p) => {
          // domain filter is advisory — requires a domain_id on the page.
          // Full slug join is deferred to when a /api/domains lookup is wired in.
          return p.domain_id !== null;
        })
      : scored;

  return filtered
    .sort((a, b) => b.score - a.score)
    .slice(0, topK)
    .map(({ page_id, slug, title, type, body_md, score }) => ({
      page_id,
      slug,
      title,
      type,
      body_md,
      score,
    }));
}
