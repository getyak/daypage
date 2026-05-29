import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import {
  users,
  memos,
  pages,
  page_links,
  domains,
  change_log,
  embed_cache,
} from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";
import { llm, ProviderError } from "@/lib/ai";
import { chunkText, averageEmbeddings, hashText } from "@/lib/ai/embed-utils";
import { promoteByWeave } from "@/lib/pages/promote";
import { dispatchPageWebhooks, type PageWebhookEvent } from "@/lib/webhooks/dispatch";
import {
  cosineSim,
  knnCluster,
  MIN_CLUSTER_SIZE,
  CLUSTER_SIMILARITY_THRESHOLD,
} from "@/lib/inngest/functions/schema-detect";

// ─── Constants ────────────────────────────────────────────────────────────────

const PAGE_FETCH_LIMIT = 400;
const TRIGGER_EVERY_N = 25; // event-driven: run weave every 25th new memo for a user
const EMBED_CACHE_TTL_DAYS = 7;
const MAX_CLUSTERS_PER_RUN = 8;
const MAX_ENTITIES_PER_CLUSTER = 6;

// ─── Slug helpers ─────────────────────────────────────────────────────────────

function slugify(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .slice(0, 60);
}

// ─── Page-body embedding (cached, best-effort) ──────────────────────────────────
// Mirrors compile-memo's embedPageBody: reuses embed_cache (body_hash + TTL) and
// never throws — embedding is best-effort and must not break the pipeline.

async function embedBody(text: string): Promise<number[] | null> {
  const trimmed = text.trim();
  if (!trimmed) return null;

  try {
    const bodyHash = hashText(trimmed);
    const cacheCutoff = new Date(
      Date.now() - EMBED_CACHE_TTL_DAYS * 24 * 60 * 60 * 1000
    );

    const [cached] = await db
      .select({ embedding: embed_cache.embedding })
      .from(embed_cache)
      .where(
        and(
          eq(embed_cache.body_hash, bodyHash),
          gte(embed_cache.created_at, cacheCutoff)
        )
      )
      .limit(1);

    if (cached) {
      return JSON.parse(cached.embedding) as number[];
    }

    const chunks = chunkText(trimmed);
    const embeddings: number[][] = [];
    for (const chunk of chunks) {
      const result = await llm.embed(chunk);
      embeddings.push(result.embedding);
    }
    const embedding = averageEmbeddings(embeddings);

    await db
      .insert(embed_cache)
      .values({ body_hash: bodyHash, embedding: JSON.stringify(embedding) })
      .onConflictDoUpdate({
        target: embed_cache.body_hash,
        set: { embedding: JSON.stringify(embedding), created_at: new Date() },
      });

    return embedding;
  } catch (err: unknown) {
    const msg =
      err instanceof ProviderError ? `${err.code}: ${err.message}` : String(err);
    console.warn(`[weave-graph] embedBody: error (non-fatal) — ${msg}`);
    return null;
  }
}

// ─── LLM synthesis of a cluster into a concept/synthesis page ──────────────────

type Synthesis = {
  page_type: "concept" | "synthesis";
  title: string;
  body_md: string;
  domain: string | null;
  entities: string[];
};

function buildSynthesisPrompt(
  sources: { title: string; body_md: string | null }[]
): string {
  const list = sources
    .slice(0, 24)
    .map(
      (s, i) =>
        `[${i + 1}] ${s.title}\n${(s.body_md ?? "").trim().slice(0, 600)}`
    )
    .join("\n\n");

  return `You are a knowledge weaver for a personal notes app. You are given a CLUSTER of related source/draft pages. Synthesize them into ONE higher-level page.

Decide the page type:
- "concept" — an evergreen idea/topic that ties these notes together.
- "synthesis" — a narrative that connects several distinct threads into one insight.

Also suggest a short domain name (2-4 words) the page belongs to, and extract up to ${MAX_ENTITIES_PER_CLUSTER} named entities (people, places, projects, products, organizations) that recur across the sources.

Cluster sources:
${list}

Respond with JSON only:
{"page_type":"concept","title":"...","body_md":"## ...\\n...","domain":"Domain Name","entities":["Entity A","Entity B"]}`;
}

function parseSynthesis(raw: string): Synthesis {
  const stripped = raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;

  const pageType =
    parsed.page_type === "synthesis" ? "synthesis" : "concept";

  if (typeof parsed.title !== "string" || typeof parsed.body_md !== "string") {
    throw new Error("Invalid synthesis shape from LLM");
  }

  const entities = Array.isArray(parsed.entities)
    ? parsed.entities
        .filter((e): e is string => typeof e === "string" && e.trim().length > 0)
        .slice(0, MAX_ENTITIES_PER_CLUSTER)
    : [];

  return {
    page_type: pageType,
    title: parsed.title,
    body_md: parsed.body_md,
    domain:
      typeof parsed.domain === "string" && parsed.domain.trim().length > 0
        ? parsed.domain.trim()
        : null,
    entities,
  };
}

// ─── Upsert a domain by suggested name, returning its id ────────────────────────

async function upsertDomain(
  userId: string,
  label: string
): Promise<string | null> {
  const slug = slugify(label) || "general";
  if (!slug) return null;

  const [domain] = await db
    .insert(domains)
    .values({ user_id: userId, slug, label })
    .onConflictDoUpdate({
      target: [domains.user_id, domains.slug],
      set: { label },
    })
    .returning({ id: domains.id });

  return domain?.id ?? null;
}

// ─── Create (or reuse) a link between two pages, bumping target backlink_count ──

async function createLink(
  userId: string,
  fromPageId: string,
  toPageId: string,
  rationale: string
): Promise<boolean> {
  if (fromPageId === toPageId) return false;

  // Avoid duplicate links (same direction) — weave runs periodically.
  const [existing] = await db
    .select({ id: page_links.id })
    .from(page_links)
    .where(
      and(
        eq(page_links.from_page_id, fromPageId),
        eq(page_links.to_page_id, toPageId)
      )
    )
    .limit(1);

  if (existing) return false;

  await db.insert(page_links).values({
    user_id: userId,
    from_page_id: fromPageId,
    to_page_id: toPageId,
    weight: 1,
    rationale,
  });

  await db
    .update(pages)
    .set({
      backlink_count: sql`${pages.backlink_count} + 1`,
      updated_at: new Date(),
    })
    .where(eq(pages.id, toPageId));

  await db.insert(change_log).values({
    user_id: userId,
    action_kind: "create_link",
    target_type: "page_link",
    target_id: `${fromPageId}→${toPageId}`,
    before: null,
    after: { from_page_id: fromPageId, to_page_id: toPageId },
    reason: rationale,
    performed_by: "agent",
    agent_action_id: "weave-graph",
  });

  return true;
}

// ─── Upsert an entity page by title, returning its id ───────────────────────────

async function upsertEntityPage(
  userId: string,
  name: string
): Promise<string | null> {
  const base = slugify(name);
  if (!base) return null;
  const slug = `entity/${base}`;

  const [page] = await db
    .insert(pages)
    .values({
      user_id: userId,
      slug,
      type: "entity",
      title: name,
      status: "draft",
      body_md: `# ${name}\n\n_Entity surfaced by graph weaving._`,
      last_compiled_at: new Date(),
    })
    .onConflictDoUpdate({
      target: [pages.user_id, pages.slug],
      set: { last_compiled_at: new Date(), updated_at: new Date() },
    })
    .returning({ id: pages.id });

  return page?.id ?? null;
}

// ─── Per-user weave ─────────────────────────────────────────────────────────────

export async function weaveGraphForUser(userId: string): Promise<{
  user_id: string;
  clusters_found: number;
  pages_synthesized: number;
  entities_extracted: number;
  links_created: number;
  domains_upserted: number;
}> {
  // Fetch source/draft pages that carry an embedding.
  const candidatePages = await db
    .select({
      id: pages.id,
      title: pages.title,
      body_md: pages.body_md,
      embedding: pages.embedding,
    })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        sql`${pages.type} IN ('source', 'concept')`,
        sql`${pages.status} != 'archived'`,
        sql`${pages.embedding} IS NOT NULL`
      )
    )
    .orderBy(sql`${pages.updated_at} DESC`)
    .limit(PAGE_FETCH_LIMIT);

  const items: { id: string; vec: number[] }[] = [];
  for (const p of candidatePages) {
    const vec = p.embedding;
    if (Array.isArray(vec) && vec.length > 0) {
      items.push({ id: p.id, vec });
    }
  }

  if (items.length < MIN_CLUSTER_SIZE) {
    console.log(
      `[weave-graph] user ${userId}: only ${items.length} embedded source pages, skipping`
    );
    return {
      user_id: userId,
      clusters_found: 0,
      pages_synthesized: 0,
      entities_extracted: 0,
      links_created: 0,
      domains_upserted: 0,
    };
  }

  const pageById = new Map(candidatePages.map((p) => [p.id, p]));

  const clusters = knnCluster(items, CLUSTER_SIMILARITY_THRESHOLD)
    .filter((c) => c.length >= MIN_CLUSTER_SIZE)
    .slice(0, MAX_CLUSTERS_PER_RUN);

  console.log(
    `[weave-graph] user ${userId}: ${clusters.length} large cluster(s) from ${items.length} pages`
  );

  let pagesSynthesized = 0;
  let entitiesExtracted = 0;
  let linksCreated = 0;
  const domainsUpserted = new Set<string>();
  // US-004: synthesized concept/synthesis pages graduate draft → live.
  const synthesizedPageIds: string[] = [];
  // US-013: lifecycle events to push to webhook targets after the run.
  const webhookEvents: PageWebhookEvent[] = [];

  // Centroid of an item set, used to rank a cluster's sources by centrality.
  const centroidOf = (ids: string[]): number[] => {
    const vecs = ids
      .map((id) => items.find((it) => it.id === id)?.vec)
      .filter((v): v is number[] => Array.isArray(v) && v.length > 0);
    return vecs.length > 0 ? averageEmbeddings(vecs) : [];
  };

  for (const cluster of clusters) {
    // Order sources by cosine similarity to the cluster centroid so the most
    // representative pages lead the synthesis prompt (reuses schema-detect's cosineSim).
    const centroid = centroidOf(cluster);
    const sources = cluster
      .map((id) => pageById.get(id))
      .filter((p): p is NonNullable<typeof p> => Boolean(p))
      .map((p) => {
        const vec = items.find((it) => it.id === p.id)?.vec ?? [];
        const score =
          centroid.length > 0 && vec.length > 0 ? cosineSim(centroid, vec) : 0;
        return { page: p, score };
      })
      .sort((a, b) => b.score - a.score)
      .map((s) => s.page);

    if (sources.length === 0) continue;

    let synthesis: Synthesis;
    try {
      const res = await llm.chat(
        [
          {
            role: "system",
            content:
              "You are a knowledge weaver. Respond with valid JSON only.",
          },
          {
            role: "user",
            content: buildSynthesisPrompt(
              sources.map((s) => ({ title: s.title, body_md: s.body_md }))
            ),
          },
        ],
        { jsonMode: true, temperature: 0.3, maxTokens: 1024 }
      );
      synthesis = parseSynthesis(res.content);
    } catch (err: unknown) {
      const msg =
        err instanceof ProviderError
          ? `${err.code}: ${err.message}`
          : String(err);
      console.warn(
        `[weave-graph] user ${userId}: synthesis error (non-fatal) — ${msg}`
      );
      continue;
    }

    // Upsert domain suggestion.
    let domainId: string | null = null;
    if (synthesis.domain) {
      domainId = await upsertDomain(userId, synthesis.domain);
      if (domainId) domainsUpserted.add(domainId);
    }

    // Synthesize the concept/synthesis page from this cluster.
    const titleSlug = slugify(synthesis.title) || `cluster-${cluster.length}`;
    const conceptSlug = `${synthesis.page_type}/${titleSlug}`;
    const embedding = await embedBody(synthesis.body_md);

    const [conceptPage] = await db
      .insert(pages)
      .values({
        user_id: userId,
        slug: conceptSlug,
        type: synthesis.page_type,
        domain_id: domainId,
        title: synthesis.title,
        status: "draft",
        body_md: synthesis.body_md,
        embedding: embedding ?? undefined,
        source_count: sources.length,
        metadata: { woven_from: cluster },
        last_compiled_at: new Date(),
      })
      .onConflictDoUpdate({
        target: [pages.user_id, pages.slug],
        set: {
          title: synthesis.title,
          body_md: synthesis.body_md,
          ...(domainId ? { domain_id: domainId } : {}),
          ...(embedding ? { embedding } : {}),
          source_count: sources.length,
          metadata: { woven_from: cluster },
          last_compiled_at: new Date(),
          updated_at: new Date(),
          version: sql`${pages.version} + 1`,
        },
      })
      .returning({ id: pages.id });

    if (!conceptPage) continue;
    pagesSynthesized++;
    synthesizedPageIds.push(conceptPage.id);

    await db.insert(change_log).values({
      user_id: userId,
      action_kind: "create_page",
      target_type: "page",
      target_id: conceptPage.id,
      before: null,
      after: {
        slug: conceptSlug,
        title: synthesis.title,
        type: synthesis.page_type,
      },
      reason: `Woven from ${sources.length} related source pages.`,
      performed_by: "agent",
      agent_action_id: "weave-graph",
    });

    webhookEvents.push({
      action_kind: "create_page",
      target_type: "page",
      target_id: conceptPage.id,
      after: {
        slug: conceptSlug,
        title: synthesis.title,
        type: synthesis.page_type,
      },
      reason: `Woven from ${sources.length} related source pages.`,
      performed_by: "agent",
    });

    // Link each source page → the synthesized concept page (backlink_count++).
    for (const src of sources) {
      const created = await createLink(
        userId,
        src.id,
        conceptPage.id,
        "Source contributes to woven concept."
      );
      if (created) linksCreated++;
    }

    // Extract recurring entities → entity pages, link concept ↔ entity.
    for (const entityName of synthesis.entities) {
      const entityId = await upsertEntityPage(userId, entityName);
      if (!entityId) continue;
      entitiesExtracted++;

      const created = await createLink(
        userId,
        conceptPage.id,
        entityId,
        `Concept references entity "${entityName}".`
      );
      if (created) linksCreated++;
    }
  }

  // US-004: a page synthesized by weave-graph graduates to `live`.
  // (promoteByWeave fires its own `promote_page` webhooks.)
  const promoted = await promoteByWeave(userId, synthesizedPageIds);

  // US-013: push the synthesized-page create events to webhook targets.
  await dispatchPageWebhooks(userId, webhookEvents);

  console.log(
    `[weave-graph] user ${userId}: ${pagesSynthesized} page(s), ${entitiesExtracted} entit(y/ies), ${linksCreated} link(s), ${domainsUpserted.size} domain(s), ${promoted.length} promoted`
  );

  return {
    user_id: userId,
    clusters_found: clusters.length,
    pages_synthesized: pagesSynthesized,
    entities_extracted: entitiesExtracted,
    links_created: linksCreated,
    domains_upserted: domainsUpserted.size,
  };
}

// ─── Inngest function: cron + event-gated ───────────────────────────────────────
// Two triggers:
//   - cron "0 3 * * *": nightly full weave across all users.
//   - event "memo/created": run the owner's weave every TRIGGER_EVERY_N memos.

export const weaveGraph = inngest.createFunction(
  { id: "weave-graph", name: "Graph Weaving Pipeline" },
  [{ cron: "0 3 * * *" }, { event: "memo/created" }],
  async ({ event, step }) => {
    // ── Event-driven path: gate on every Nth memo for that user ───────────────
    if (event?.name === "memo/created") {
      const { memo_id } = (event.data ?? {}) as { memo_id?: string };
      if (!memo_id) return { skipped: true, reason: "no_memo_id" };

      const gated = await step.run("gate", async () => {
        const [memo] = await db
          .select({ user_id: memos.user_id })
          .from(memos)
          .where(eq(memos.id, memo_id))
          .limit(1);

        if (!memo) return null;

        const [countRow] = await db
          .select({ count: sql<number>`count(*)::int` })
          .from(memos)
          .where(eq(memos.user_id, memo.user_id));

        const total = countRow?.count ?? 0;
        if (total % TRIGGER_EVERY_N !== 0) {
          return { user_id: memo.user_id, skip: true, total };
        }
        return { user_id: memo.user_id, skip: false, total };
      });

      if (!gated || gated.skip) {
        return {
          skipped: true,
          reason: gated ? "not_at_threshold" : "memo_not_found",
        };
      }

      const result = await step.run(`weave-${gated.user_id}`, () =>
        weaveGraphForUser(gated.user_id)
      );
      return result;
    }

    // ── Cron path: weave every user ───────────────────────────────────────────
    const allUsers = await step.run("fetch-users", () =>
      db.select({ id: users.id }).from(users)
    );

    const results: Awaited<ReturnType<typeof weaveGraphForUser>>[] = [];
    for (const user of allUsers) {
      const result = await step.run(`weave-${user.id}`, () =>
        weaveGraphForUser(user.id)
      );
      results.push(result);
    }

    return {
      processed_users: results.length,
      total_pages: results.reduce((s, r) => s + r.pages_synthesized, 0),
      total_links: results.reduce((s, r) => s + r.links_created, 0),
      results,
    };
  }
);
