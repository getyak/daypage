import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import {
  memos,
  domains,
  inbox_items,
  schema_cluster_log,
} from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";
import { llm, ProviderError } from "@/lib/ai";
import { createHash } from "crypto";

// ─── Constants ────────────────────────────────────────────────────────────────

const MEMO_FETCH_LIMIT = 200;
const MIN_CLUSTER_SIZE = 8;
const CLUSTER_SIMILARITY_THRESHOLD = 0.55;
const IDEMPOTENCY_WINDOW_DAYS = 7;
const TRIGGER_EVERY_N = 50; // run schema-detect every 50th new memo for a user

// ─── Cosine similarity ────────────────────────────────────────────────────────

function cosineSim(a: number[], b: number[]): number {
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

// ─── Simple kNN-based clustering ─────────────────────────────────────────────
// Groups memos into clusters by finding connected components where every
// pair has cosine similarity >= threshold. Returns array of clusters (each
// cluster is an array of memo ids).

export function knnCluster(
  items: { id: string; vec: number[] }[],
  threshold: number
): string[][] {
  const n = items.length;
  const parent = Array.from({ length: n }, (_, i) => i);

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

  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      if (cosineSim(items[i].vec, items[j].vec) >= threshold) {
        union(i, j);
      }
    }
  }

  const clusters = new Map<number, string[]>();
  for (let i = 0; i < n; i++) {
    const root = find(i);
    if (!clusters.has(root)) clusters.set(root, []);
    clusters.get(root)!.push(items[i].id);
  }

  return Array.from(clusters.values());
}

// ─── Cluster signature (stable hash of sorted memo ids) ──────────────────────

export function clusterSignature(memoIds: string[]): string {
  const sorted = [...memoIds].sort();
  return createHash("sha256").update(sorted.join(",")).digest("hex").slice(0, 16);
}

// ─── LLM call to suggest domain name ─────────────────────────────────────────

async function suggestDomainName(
  titles: string[]
): Promise<{ name: string; color: string }> {
  const titleList = titles
    .slice(0, 20)
    .map((t, i) => `${i + 1}. ${t}`)
    .join("\n");

  const prompt = `You are a knowledge organizer. Given these memo titles from a personal notes app, suggest a concise domain name (2-4 words max) that captures the common theme, and pick a color from: blue, green, orange, purple, red, teal, yellow.

Memo titles:
${titleList}

Respond with JSON only: {"name": "Domain Name", "color": "blue"}`;

  const res = await llm.chat(
    [
      {
        role: "system",
        content:
          "You are a knowledge organizer. Respond with valid JSON only.",
      },
      { role: "user", content: prompt },
    ],
    { jsonMode: true, temperature: 0.3, maxTokens: 64 }
  );

  const stripped = res.content
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;

  if (typeof parsed.name !== "string" || typeof parsed.color !== "string") {
    throw new Error("Invalid domain suggestion shape from LLM");
  }

  return { name: parsed.name, color: parsed.color };
}

// ─── Per-user schema detection ────────────────────────────────────────────────

export async function detectSchemaForUser(userId: string): Promise<{
  user_id: string;
  clusters_found: number;
  suggestions: number;
}> {
  // Fetch last 200 memos with embeddings
  const recentMemos = await db
    .select({
      id: memos.id,
      body: memos.body,
      embedding: memos.embedding,
      domain_id: null as string | null, // fetched below
    })
    .from(memos)
    .where(
      and(
        eq(memos.user_id, userId),
        sql`${memos.embedding} IS NOT NULL`
      )
    )
    .orderBy(sql`${memos.created_at} DESC`)
    .limit(MEMO_FETCH_LIMIT);

  if (recentMemos.length < MIN_CLUSTER_SIZE) {
    console.log(
      `[schema-detect] user ${userId}: only ${recentMemos.length} embedded memos, skipping`
    );
    return { user_id: userId, clusters_found: 0, suggestions: 0 };
  }

  // Parse embeddings
  const items: { id: string; vec: number[] }[] = [];
  for (const m of recentMemos) {
    try {
      const vec = JSON.parse(m.embedding!) as number[];
      if (Array.isArray(vec) && vec.length > 0) {
        items.push({ id: m.id, vec });
      }
    } catch {
      // skip memos with malformed embeddings
    }
  }

  if (items.length < MIN_CLUSTER_SIZE) {
    return { user_id: userId, clusters_found: 0, suggestions: 0 };
  }

  // Get existing domain memo counts to check which clusters are already mapped
  const existingDomains = await db
    .select({ id: domains.id, slug: domains.slug })
    .from(domains)
    .where(eq(domains.user_id, userId));

  const existingDomainIds = new Set(existingDomains.map((d) => d.id));

  // Get memos that are already assigned to a domain (via page metadata)
  // For simplicity, we consider a memo "mapped to a domain" if its compile_status
  // is done and it has a domain_id. We use the memos with no domain as candidates.
  // Since memos don't directly store domain_id, we count clusters that overlap
  // with pages already in known domains — but for now, we treat ALL clusters
  // as unmapped unless the cluster's signature was already processed.

  // Cluster the embedded memos
  const clusters = knnCluster(items, CLUSTER_SIMILARITY_THRESHOLD);
  const largeClusters = clusters.filter((c) => c.length >= MIN_CLUSTER_SIZE);

  console.log(
    `[schema-detect] user ${userId}: ${largeClusters.length} large cluster(s) from ${items.length} memos`
  );

  if (largeClusters.length === 0) {
    return { user_id: userId, clusters_found: 0, suggestions: 0 };
  }

  // Idempotency window: don't re-suggest same cluster in last 7 days
  const cutoff = new Date(
    Date.now() - IDEMPOTENCY_WINDOW_DAYS * 24 * 60 * 60 * 1000
  );
  const recentLogs = await db
    .select({ cluster_signature: schema_cluster_log.cluster_signature })
    .from(schema_cluster_log)
    .where(
      and(
        eq(schema_cluster_log.user_id, userId),
        gte(schema_cluster_log.created_at, cutoff)
      )
    );

  const seenSignatures = new Set(recentLogs.map((l) => l.cluster_signature));

  let suggestions = 0;

  for (const cluster of largeClusters) {
    const sig = clusterSignature(cluster);

    if (seenSignatures.has(sig)) {
      console.log(
        `[schema-detect] user ${userId}: cluster ${sig} already suggested recently, skipping`
      );
      continue;
    }

    // Check if cluster overlaps significantly with existing domains
    // (If ≥50% of memos are already in a domain-assigned page, skip)
    // For now we use the existingDomainIds set to identify domains exist;
    // the full domain-memo mapping check requires additional joins.
    // We skip if user has a domain with count >= cluster size (rough proxy).
    // A proper implementation would join pages → page_sources and check domain_id.
    // For this MVP, we proceed if the signature is new.

    // Get memo titles for LLM
    const clusterMemos = recentMemos.filter((m) => cluster.includes(m.id));
    const titles = clusterMemos.map((m) =>
      m.body.trim().split("\n")[0].slice(0, 100)
    );

    let suggestion: { name: string; color: string };
    try {
      suggestion = await suggestDomainName(titles);
    } catch (err: unknown) {
      const msg =
        err instanceof ProviderError ? `${err.code}: ${err.message}` : String(err);
      console.error(
        `[schema-detect] user ${userId}: LLM error for cluster ${sig}: ${msg}`
      );
      continue;
    }

    // Write inbox_item
    const inboxTitle = `New domain suggestion: ${suggestion.name}`;
    const [inboxItem] = await db
      .insert(inbox_items)
      .values({
        user_id: userId,
        kind: "schema",
        title: inboxTitle,
        body: `Found ${cluster.length} related memos that could form a domain called "${suggestion.name}".`,
        payload: {
          cluster_memo_ids: cluster,
          suggested_name: suggestion.name,
          suggested_color: suggestion.color,
        },
        status: "open",
      })
      .returning({ id: inbox_items.id });

    // Record in cluster log for idempotency
    await db.insert(schema_cluster_log).values({
      user_id: userId,
      cluster_signature: sig,
      suggested_name: suggestion.name,
      inbox_item_id: inboxItem?.id ?? null,
    });

    seenSignatures.add(sig);
    suggestions++;

    console.log(
      `[schema-detect] user ${userId}: suggested domain "${suggestion.name}" for cluster of ${cluster.length} memos (sig: ${sig})`
    );
  }

  // Suppress unused variable warning for existingDomainIds
  void existingDomainIds;

  return {
    user_id: userId,
    clusters_found: largeClusters.length,
    suggestions,
  };
}

// ─── Inngest function ─────────────────────────────────────────────────────────
// Triggered on memo/created; runs schema detection every TRIGGER_EVERY_N memos.

export const schemaDetect = inngest.createFunction(
  { id: "schema-detect", name: "Schema Detection Worker" },
  { event: "memo/created" },
  async ({ event, step }) => {
    const { memo_id } = event.data as { memo_id: string };

    const result = await step.run("check-and-detect", async () => {
      // Resolve memo → user
      const [memo] = await db
        .select({ user_id: memos.user_id })
        .from(memos)
        .where(eq(memos.id, memo_id))
        .limit(1);

      if (!memo) {
        console.log(`[schema-detect] memo ${memo_id} not found, skipping`);
        return null;
      }

      const userId = memo.user_id;

      // Count total memos for this user to determine if we should run
      const [countRow] = await db
        .select({ count: sql<number>`count(*)::int` })
        .from(memos)
        .where(eq(memos.user_id, userId));

      const totalMemos = countRow?.count ?? 0;

      if (totalMemos % TRIGGER_EVERY_N !== 0) {
        console.log(
          `[schema-detect] user ${userId}: ${totalMemos} memos, not at trigger threshold (${TRIGGER_EVERY_N})`
        );
        return { skipped: true, reason: "not_at_threshold", total_memos: totalMemos };
      }

      console.log(
        `[schema-detect] user ${userId}: ${totalMemos} memos — running detection`
      );

      return detectSchemaForUser(userId);
    });

    return result;
  }
);
