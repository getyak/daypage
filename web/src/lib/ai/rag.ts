// ─── RAG retrieval helper ─────────────────────────────────────────────────────
// Server-only. Embeds a query via the unified LLM façade (OpenAI
// text-embedding-3-small) and retrieves the most relevant pages from the
// user's wiki using native pgvector approximate-nearest-neighbour search.
//
// Embeddings are stored as a native vector(1536) column (migration
// 0006_pgvector_hnsw.sql). Retrieval is a single
//   ORDER BY embedding <=> $query::vector LIMIT k
// query backed by the HNSW index (vector_cosine_ops), so there is no JS-side
// full-table scan / cosine computation.

import "server-only";
import { db } from "@/lib/db/client";
import { sql } from "drizzle-orm";
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
  /**
   * Restrict recall to a single domain by its id. Used by US-031 agents whose
   * retrieval scope is pinned to one knowledge area. When set, only pages whose
   * `domain_id` matches are returned. Takes precedence over the legacy
   * `domain` boolean-ish flag.
   */
  domainId?: string;
  excludePrivate?: boolean;
}

/** Format a JS number[] as a pgvector literal, e.g. "[0.1,0.2,0.3]". */
function toVectorLiteral(vec: number[]): string {
  return `[${vec.join(",")}]`;
}

/**
 * Retrieve the most relevant wiki pages for a natural-language query using the
 * native pgvector HNSW index (cosine distance).
 *
 * @param userId  - Scopes the search to a single user's pages.
 * @param queryText - Free-form text to embed and compare against page embeddings.
 * @param opts.topK - Maximum results to return (default 8).
 * @param opts.domain - If set, only pages whose domain_id is present are returned
 *   (advisory; a full slug join is deferred until a /api/domains lookup is wired in).
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

  // Native pgvector ANN: ORDER BY embedding <=> $query::vector LIMIT topK,
  // backed by the HNSW index (vector_cosine_ops) from 0006_pgvector_hnsw.sql.
  // score = 1 - cosine_distance, so higher is more similar.
  const queryLiteral = toVectorLiteral(queryVec);
  // A specific domain id pins recall to that knowledge area (US-031 agents);
  // the legacy `domain` flag only filters to "has any domain".
  const hasDomainId = typeof opts.domainId === "string" && opts.domainId.length > 0;
  const domainOnly = !hasDomainId && opts.domain !== undefined;

  const rows = await db.execute<{
    page_id: string;
    slug: string;
    title: string;
    type: string;
    body_md: string | null;
    score: number;
  }>(sql`
    SELECT
      "id" AS page_id,
      "slug",
      "title",
      "type",
      "body_md",
      1 - ("embedding" <=> ${queryLiteral}::vector) AS score
    FROM "pages"
    WHERE "user_id" = ${userId}
      AND "status" <> 'archived'
      AND "embedding" IS NOT NULL
      ${hasDomainId ? sql`AND "domain_id" = ${opts.domainId}` : sql``}
      ${domainOnly ? sql`AND "domain_id" IS NOT NULL` : sql``}
    ORDER BY "embedding" <=> ${queryLiteral}::vector
    LIMIT ${topK}
  `);

  return rows.map((r) => ({
    page_id: r.page_id,
    slug: r.slug,
    title: r.title,
    type: r.type,
    body_md: r.body_md,
    score: Number(r.score),
  }));
}
