import { inngest, sendEvent } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import {
  memos,
  embed_cache,
  pages,
  page_sources,
  page_links,
  change_log,
  inbox_items,
} from "@/lib/db/schema";
import { eq, and, gte, sql } from "drizzle-orm";
import { llm, ProviderError } from "@/lib/ai";
import { chunkText, averageEmbeddings, hashText } from "@/lib/ai/embed-utils";
import { getAssistantPersona, personaPreamble } from "@/lib/ai/persona";
import { promoteBySourceCount } from "@/lib/pages/promote";
import { dispatchPageWebhooks, type PageWebhookEvent } from "@/lib/webhooks/dispatch";
import {
  commitMemoToTree,
  liveCommitMemoTreeDeps,
  COMMIT_HEAT_INCREMENT,
} from "@/lib/trees/commit-memo";
import { crossedEvolveThreshold } from "@/lib/gateway/evolver";
import fs from "fs";
import path from "path";

const EMBED_CACHE_TTL_DAYS = 7;
const FULL_RECALL_TOP_K = 8;

// Load prompt templates once at module level
const COMPILE_LIGHT_PROMPT = fs.readFileSync(
  path.join(process.cwd(), "src/lib/ai/prompts/compile-light.md"),
  "utf-8",
);

const COMPILE_FULL_PROMPT = fs.readFileSync(
  path.join(process.cwd(), "src/lib/ai/prompts/compile-full.md"),
  "utf-8",
);

const CONFLICT_CHECK_PROMPT = fs.readFileSync(
  path.join(process.cwd(), "src/lib/ai/prompts/conflict-check.md"),
  "utf-8",
);

// ─── LIGHT mode types ─────────────────────────────────────────────────────────

type LightCompileResult = {
  summary: string;
  keywords: string[];
  suggested_domain: string | null;
};

function buildLightPrompt(memoBody: string): string {
  return COMPILE_LIGHT_PROMPT.replace("{{MEMO_BODY}}", memoBody);
}

function parseLightResult(raw: string): LightCompileResult {
  const stripped = raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;

  if (
    typeof parsed.summary !== "string" ||
    !Array.isArray(parsed.keywords) ||
    !parsed.keywords.every((k) => typeof k === "string") ||
    (parsed.suggested_domain !== null &&
      typeof parsed.suggested_domain !== "string")
  ) {
    throw new Error("Invalid shape from LLM");
  }

  return {
    summary: parsed.summary,
    keywords: parsed.keywords as string[],
    suggested_domain: (parsed.suggested_domain as string | null) ?? null,
  };
}

// ─── FULL mode types ──────────────────────────────────────────────────────────

type RecalledPage = {
  id: string;
  slug: string;
  title: string;
  type: string;
  body_md: string | null;
};

type FullOperation =
  | {
      op: "update_page";
      page_id: string;
      title?: string;
      body_md: string;
      rationale?: string;
    }
  | {
      op: "create_page";
      slug: string;
      type: string;
      title: string;
      body_md: string;
      rationale?: string;
    }
  | {
      op: "create_link";
      from_page_id: string;
      to_page_id: string;
      rationale?: string;
    }
  | {
      op: "extract_entity";
      slug: string;
      type: string;
      title: string;
      body_md: string;
      rationale?: string;
    };

type FullCompileResult = {
  operations: FullOperation[];
};

function buildFullPrompt(memoBody: string, recalled: RecalledPage[]): string {
  const pagesSection =
    recalled.length === 0
      ? "(none — no relevant pages found)"
      : recalled
          .map(
            (p, i) =>
              `[${i + 1}] id=${p.id} slug=${p.slug} type=${p.type}\nTitle: ${p.title}\n---\n${p.body_md ?? "(empty)"}`,
          )
          .join("\n\n");

  return COMPILE_FULL_PROMPT.replace("{{MEMO_BODY}}", memoBody).replace(
    "{{RETRIEVED_PAGES}}",
    pagesSection,
  );
}

function parseFullResult(raw: string): FullCompileResult {
  const stripped = raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;

  if (!Array.isArray(parsed.operations)) {
    throw new Error("Missing operations array in FULL compile result");
  }

  return { operations: parsed.operations as FullOperation[] };
}

// ─── Conflict check types ─────────────────────────────────────────────────────

type ConflictItem = {
  page_id: string;
  old_text: string;
  new_text: string;
  summary: string;
};

type ConflictCheckResult = {
  conflicts: ConflictItem[];
};

function buildConflictPrompt(
  memoBody: string,
  top3Pages: RecalledPage[],
): string {
  const pagesSection =
    top3Pages.length === 0
      ? "(none)"
      : top3Pages
          .map(
            (p) =>
              `id=${p.id} slug=${p.slug}\nTitle: ${p.title}\n---\n${p.body_md ?? "(empty)"}`,
          )
          .join("\n\n");

  return CONFLICT_CHECK_PROMPT.replace("{{MEMO_BODY}}", memoBody).replace(
    "{{TOP_PAGES}}",
    pagesSection,
  );
}

function parseConflictResult(raw: string): ConflictCheckResult {
  const stripped = raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  const parsed = JSON.parse(stripped) as Record<string, unknown>;

  if (!Array.isArray(parsed.conflicts)) {
    throw new Error("Missing conflicts array in conflict-check result");
  }

  return { conflicts: parsed.conflicts as ConflictItem[] };
}

// ─── Page embedding helper ─────────────────────────────────────────────────────

// Compute an embedding for a page's body_md, reusing embed_cache (body_hash + TTL)
// to avoid re-embedding identical content. Returns null on empty body or provider
// failure (embedding is best-effort — it must never block compilation).
async function embedPageBody(bodyMd: string): Promise<number[] | null> {
  const text = bodyMd.trim();
  if (!text) return null;

  try {
    const bodyHash = hashText(text);
    const cacheCutoff = new Date(
      Date.now() - EMBED_CACHE_TTL_DAYS * 24 * 60 * 60 * 1000,
    );

    const [cached] = await db
      .select({ embedding: embed_cache.embedding })
      .from(embed_cache)
      .where(
        and(
          eq(embed_cache.body_hash, bodyHash),
          gte(embed_cache.created_at, cacheCutoff),
        ),
      )
      .limit(1);

    if (cached) {
      return JSON.parse(cached.embedding) as number[];
    }

    const chunks = chunkText(text);
    const embeddings: number[][] = [];
    for (const chunk of chunks) {
      const result = await llm.embed(chunk);
      embeddings.push(result.embedding);
    }
    const embedding = averageEmbeddings(embeddings);

    await db
      .insert(embed_cache)
      .values({
        body_hash: bodyHash,
        embedding: JSON.stringify(embedding),
      })
      .onConflictDoUpdate({
        target: embed_cache.body_hash,
        set: {
          embedding: JSON.stringify(embedding),
          created_at: new Date(),
        },
      });

    return embedding;
  } catch (err: unknown) {
    const message =
      err instanceof ProviderError
        ? `${err.code}: ${err.message}`
        : String(err);
    console.warn(
      `[compile-memo] embedPageBody: error (non-fatal) — ${message}`,
    );
    return null;
  }
}

// ─── Slug helpers ─────────────────────────────────────────────────────────────

function slugFromBody(body: string, id: string): string {
  const base = body
    .slice(0, 60)
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
  return `source/${base || "memo"}-${id.slice(0, 8)}`;
}

function normalizeSlug(raw: string): string {
  // strip 'new:' prefix if present
  return raw.startsWith("new:") ? raw.slice(4) : raw;
}

// ─── Main Inngest function ────────────────────────────────────────────────────

export const compileMemo = inngest.createFunction(
  { id: "compile-memo", name: "Compile Memo" },
  { event: "memo/created" },
  async ({ event, step }) => {
    const { memo_id } = event.data as { memo_id: string };

    // ── normalize ─────────────────────────────────────────────────────────────
    await step.run("normalize", async () => {
      console.log(`[compile-memo] normalize: memo ${memo_id}`);
      await db
        .update(memos)
        .set({ compile_status: "running", compile_error: null })
        .where(eq(memos.id, memo_id));
    });

    // ── embed ─────────────────────────────────────────────────────────────────
    await step.run("embed", async () => {
      console.log(`[compile-memo] embed: memo ${memo_id}`);

      const [memo] = await db
        .select({ body: memos.body })
        .from(memos)
        .where(eq(memos.id, memo_id))
        .limit(1);

      if (!memo || !memo.body.trim()) {
        console.log(`[compile-memo] embed: skipping — empty body`);
        return;
      }

      try {
        const bodyHash = hashText(memo.body);
        const cacheCutoff = new Date(
          Date.now() - EMBED_CACHE_TTL_DAYS * 24 * 60 * 60 * 1000,
        );

        const [cached] = await db
          .select({ embedding: embed_cache.embedding })
          .from(embed_cache)
          .where(
            and(
              eq(embed_cache.body_hash, bodyHash),
              gte(embed_cache.created_at, cacheCutoff),
            ),
          )
          .limit(1);

        let embedding: number[];

        if (cached) {
          console.log(`[compile-memo] embed: cache hit for ${memo_id}`);
          embedding = (JSON.parse(cached.embedding) as number[]);
        } else {
          const chunks = chunkText(memo.body);
          const embeddings: number[][] = [];
          for (const chunk of chunks) {
            const result = await llm.embed(chunk);
            embeddings.push(result.embedding);
          }
          embedding = averageEmbeddings(embeddings);

          await db
            .insert(embed_cache)
            .values({
              body_hash: bodyHash,
              embedding: JSON.stringify(embedding),
            })
            .onConflictDoUpdate({
              target: embed_cache.body_hash,
              set: {
                embedding: JSON.stringify(embedding),
                created_at: new Date(),
              },
            });
        }

        await db
          .update(memos)
          .set({ embedding })
          .where(eq(memos.id, memo_id));
      } catch (err: unknown) {
        const message =
          err instanceof ProviderError
            ? `${err.code}: ${err.message}`
            : String(err);
        console.error(`[compile-memo] embed error: ${message}`);
        await db
          .update(memos)
          .set({ compile_status: "failed", compile_error: message })
          .where(eq(memos.id, memo_id));
        throw err;
      }
    });

    // ── recall ────────────────────────────────────────────────────────────────
    // Returns top-K pages by cosine similarity to memo.embedding (FULL mode only).
    // Uses native pgvector ANN (ORDER BY embedding <=> $memo::vector LIMIT K) via
    // the HNSW index (0006_pgvector_hnsw.sql) — no JS-side full-table cosine.
    // Stored in step result so compile step can use them without re-querying.
    const recalledPages = await step.run("recall", async () => {
      console.log(`[compile-memo] recall: memo ${memo_id}`);

      const [memo] = await db
        .select({
          embedding: memos.embedding,
          user_id: memos.user_id,
          ingest_mode: memos.ingest_mode,
        })
        .from(memos)
        .where(eq(memos.id, memo_id))
        .limit(1);

      if (!memo || memo.ingest_mode !== "full") {
        console.log(`[compile-memo] recall: skipping (not FULL mode)`);
        return [] as RecalledPage[];
      }

      if (!memo.embedding || memo.embedding.length === 0) {
        console.log(`[compile-memo] recall: no embedding yet, skipping`);
        return [] as RecalledPage[];
      }

      const memoLiteral = `[${memo.embedding.join(",")}]`;

      // Native pgvector ANN over this user's non-archived embedded pages.
      const scored = await db.execute<{
        id: string;
        slug: string;
        title: string;
        type: string;
        body_md: string | null;
      }>(sql`
        SELECT "id", "slug", "title", "type", "body_md"
        FROM "pages"
        WHERE "user_id" = ${memo.user_id}
          AND "status" <> 'archived'
          AND "embedding" IS NOT NULL
        ORDER BY "embedding" <=> ${memoLiteral}::vector
        LIMIT ${FULL_RECALL_TOP_K}
      `);

      console.log(
        `[compile-memo] recall: found ${scored.length} candidate pages`,
      );

      return scored.map(({ id, slug, title, type, body_md }) => ({
        id,
        slug,
        title,
        type,
        body_md,
      })) as RecalledPage[];
    });

    // ── conflict-check ────────────────────────────────────────────────────────
    // For FULL mode only: check for factual contradictions between the new memo
    // and the top-3 recalled pages. Detected conflicts are written to inbox_items.
    await step.run("conflict-check", async () => {
      if (recalledPages.length === 0) {
        console.log(
          `[compile-memo] conflict-check: skipping (no recalled pages)`,
        );
        return;
      }

      const [memo] = await db
        .select({
          body: memos.body,
          user_id: memos.user_id,
          ingest_mode: memos.ingest_mode,
        })
        .from(memos)
        .where(eq(memos.id, memo_id))
        .limit(1);

      if (!memo || memo.ingest_mode !== "full" || !memo.body.trim()) {
        console.log(
          `[compile-memo] conflict-check: skipping (not FULL mode or empty body)`,
        );
        return;
      }

      const top3 = recalledPages.slice(0, 3);
      const promptContent = buildConflictPrompt(memo.body, top3);

      let conflictResult: ConflictCheckResult;
      try {
        const res = await llm.chat(
          [
            {
              role: "system",
              content:
                "You are a factual consistency auditor. Respond with valid JSON only.",
            },
            { role: "user", content: promptContent },
          ],
          { jsonMode: true, temperature: 0.1, maxTokens: 512 },
        );
        conflictResult = parseConflictResult(res.content);
      } catch (err: unknown) {
        // Non-fatal: log and continue — conflict detection failure does not block compilation
        console.warn(
          `[compile-memo] conflict-check: error (non-fatal) — ${String(err)}`,
        );
        return;
      }

      if (conflictResult.conflicts.length === 0) {
        console.log(`[compile-memo] conflict-check: no conflicts found`);
        return;
      }

      console.log(
        `[compile-memo] conflict-check: ${conflictResult.conflicts.length} conflict(s) detected`,
      );

      for (const conflict of conflictResult.conflicts) {
        // Validate that the page_id is one of the recalled pages to avoid hallucinations
        const matchedPage = top3.find((p) => p.id === conflict.page_id);
        if (!matchedPage) {
          console.warn(
            `[compile-memo] conflict-check: unknown page_id ${conflict.page_id}, skipping`,
          );
          continue;
        }

        const title = `Two takes on: ${conflict.summary.slice(0, 80)}`;

        await db.insert(inbox_items).values({
          user_id: memo.user_id,
          kind: "contradiction",
          title,
          body: conflict.summary,
          payload: {
            old_text: conflict.old_text,
            new_text: conflict.new_text,
            page_id: conflict.page_id,
            page_title: matchedPage.title,
            page_slug: matchedPage.slug,
            memo_id,
          },
          status: "open",
        });

        console.log(
          `[compile-memo] conflict-check: inbox item created for page ${conflict.page_id}`,
        );
      }
    });

    // ── compile ───────────────────────────────────────────────────────────────
    const compileResult = await step.run("compile", async () => {
      console.log(`[compile-memo] compile: memo ${memo_id}`);

      const [memo] = await db
        .select({
          body: memos.body,
          user_id: memos.user_id,
          ingest_mode: memos.ingest_mode,
        })
        .from(memos)
        .where(eq(memos.id, memo_id))
        .limit(1);

      if (!memo) throw new Error(`Memo not found: ${memo_id}`);

      if (!memo.body.trim()) {
        console.log(`[compile-memo] compile: empty body, skipping`);
        return null;
      }

      // US-032: inject the user's knowledge-assistant persona so the compiled
      // diary/wiki carries the same tone/perspective as /chat. The JSON-only
      // contract is preserved after the persona preamble.
      const persona = await getAssistantPersona(memo.user_id);
      const systemPrompt =
        personaPreamble(persona) +
        "You are a personal knowledge assistant. Always respond with valid JSON only. No prose, no markdown outside the JSON object.";

      // ── LIGHT mode ──────────────────────────────────────────────────────────
      if (memo.ingest_mode === "light") {
        const promptContent = buildLightPrompt(memo.body);

        let raw: string;
        try {
          const res = await llm.chat(
            [
              { role: "system", content: systemPrompt },
              { role: "user", content: promptContent },
            ],
            { jsonMode: true, temperature: 0.3, maxTokens: 512 },
          );
          raw = res.content;
        } catch (err: unknown) {
          const message =
            err instanceof ProviderError
              ? `${err.code}: ${err.message}`
              : String(err);
          console.error(`[compile-memo] compile LLM error: ${message}`);
          await db
            .update(memos)
            .set({ compile_status: "failed", compile_error: message })
            .where(eq(memos.id, memo_id));
          throw err;
        }

        let lightResult: LightCompileResult;
        try {
          lightResult = parseLightResult(raw);
        } catch {
          console.warn(
            `[compile-memo] compile: invalid JSON on first attempt, retrying`,
          );
          const stricterPrompt = `${promptContent}\n\nIMPORTANT: Return ONLY the JSON object. No explanation. No markdown. No code fences.`;
          let raw2: string;
          try {
            const res2 = await llm.chat(
              [
                { role: "system", content: systemPrompt },
                { role: "user", content: stricterPrompt },
              ],
              { jsonMode: true, temperature: 0.1, maxTokens: 512 },
            );
            raw2 = res2.content;
          } catch (err: unknown) {
            const message =
              err instanceof ProviderError
                ? `${err.code}: ${err.message}`
                : String(err);
            await db
              .update(memos)
              .set({ compile_status: "failed", compile_error: message })
              .where(eq(memos.id, memo_id));
            throw err;
          }

          try {
            lightResult = parseLightResult(raw2);
          } catch (parseErr: unknown) {
            const message = `invalid_json: ${String(parseErr)}`;
            await db
              .update(memos)
              .set({ compile_status: "failed", compile_error: message })
              .where(eq(memos.id, memo_id));
            throw new Error(message);
          }
        }

        return {
          mode: "light" as const,
          result: lightResult,
          user_id: memo.user_id,
          body: memo.body,
        };
      }

      // ── FULL mode ───────────────────────────────────────────────────────────
      const promptContent = buildFullPrompt(memo.body, recalledPages);

      let raw: string;
      try {
        const res = await llm.chat(
          [
            { role: "system", content: systemPrompt },
            { role: "user", content: promptContent },
          ],
          { jsonMode: true, temperature: 0.3, maxTokens: 2048 },
        );
        raw = res.content;
      } catch (err: unknown) {
        const message =
          err instanceof ProviderError
            ? `${err.code}: ${err.message}`
            : String(err);
        console.error(`[compile-memo] compile FULL LLM error: ${message}`);
        await db
          .update(memos)
          .set({ compile_status: "failed", compile_error: message })
          .where(eq(memos.id, memo_id));
        throw err;
      }

      let fullResult: FullCompileResult;
      try {
        fullResult = parseFullResult(raw);
      } catch {
        // Retry once with stricter prompt
        const stricterPrompt = `${promptContent}\n\nIMPORTANT: Return ONLY the JSON object. No explanation. No markdown. No code fences.`;
        let raw2: string;
        try {
          const res2 = await llm.chat(
            [
              { role: "system", content: systemPrompt },
              { role: "user", content: stricterPrompt },
            ],
            { jsonMode: true, temperature: 0.1, maxTokens: 2048 },
          );
          raw2 = res2.content;
        } catch (err: unknown) {
          const message =
            err instanceof ProviderError
              ? `${err.code}: ${err.message}`
              : String(err);
          await db
            .update(memos)
            .set({ compile_status: "failed", compile_error: message })
            .where(eq(memos.id, memo_id));
          throw err;
        }

        try {
          fullResult = parseFullResult(raw2);
        } catch (parseErr: unknown) {
          const message = `invalid_json: ${String(parseErr)}`;
          await db
            .update(memos)
            .set({ compile_status: "failed", compile_error: message })
            .where(eq(memos.id, memo_id));
          throw new Error(message);
        }
      }

      // Validate: all cited page_ids must exist in recalled set
      const recalledIds = new Set(recalledPages.map((p) => p.id));
      for (const op of fullResult.operations) {
        if (op.op === "update_page" && !recalledIds.has(op.page_id)) {
          const message = `invalid_page_id: ${op.page_id} not in recalled set`;
          await db
            .update(memos)
            .set({ compile_status: "failed", compile_error: message })
            .where(eq(memos.id, memo_id));
          throw new Error(message);
        }
        if (op.op === "create_link") {
          const from = normalizeSlug(op.from_page_id);
          const to = normalizeSlug(op.to_page_id);
          const fromValid =
            recalledIds.has(from) ||
            op.from_page_id.startsWith("new:") ||
            fullResult.operations.some(
              (o) =>
                (o.op === "create_page" || o.op === "extract_entity") &&
                o.slug === from,
            );
          const toValid =
            recalledIds.has(to) ||
            op.to_page_id.startsWith("new:") ||
            fullResult.operations.some(
              (o) =>
                (o.op === "create_page" || o.op === "extract_entity") &&
                o.slug === to,
            );
          if (!fromValid || !toValid) {
            console.warn(
              `[compile-memo] create_link references unknown page(s): ${from} → ${to}, skipping link`,
            );
          }
        }
      }

      return {
        mode: "full" as const,
        result: fullResult,
        recalled: recalledPages,
        user_id: memo.user_id,
        body: memo.body,
      };
    });

    // ── apply ─────────────────────────────────────────────────────────────────
    await step.run("apply", async () => {
      console.log(`[compile-memo] apply: memo ${memo_id}`);

      if (!compileResult) {
        console.log(`[compile-memo] apply: nothing to apply`);
        return;
      }

      // ── LIGHT apply ─────────────────────────────────────────────────────────
      if (compileResult.mode === "light") {
        const { result, user_id, body } = compileResult;
        const slug = slugFromBody(body, memo_id);
        const title =
          body.trim().slice(0, 80) || result.summary.slice(0, 80) || "Untitled";

        const embedding = await embedPageBody(result.summary);

        const [page] = await db
          .insert(pages)
          .values({
            user_id,
            slug,
            type: "source",
            title,
            status: "draft",
            body_md: result.summary,
            embedding: embedding ?? undefined,
            metadata: {
              keywords: result.keywords,
              suggested_domain: result.suggested_domain,
              source_memo_id: memo_id,
            },
            last_compiled_at: new Date(),
          })
          .onConflictDoUpdate({
            target: [pages.user_id, pages.slug],
            set: {
              title,
              body_md: result.summary,
              ...(embedding ? { embedding } : {}),
              metadata: {
                keywords: result.keywords,
                suggested_domain: result.suggested_domain,
                source_memo_id: memo_id,
              },
              last_compiled_at: new Date(),
              updated_at: new Date(),
            },
          })
          .returning({ id: pages.id });

        if (!page) throw new Error("Failed to upsert page");

        await db
          .insert(page_sources)
          .values({ page_id: page.id, memo_id, weight: 1 })
          .onConflictDoNothing();

        // US-004: promote draft → live once referenced by ≥2 sources.
        await promoteBySourceCount(user_id, [page.id]);
        return;
      }

      // ── FULL apply ──────────────────────────────────────────────────────────
      const { result, recalled, user_id } = compileResult;

      if (result.operations.length === 0) {
        console.log(`[compile-memo] apply FULL: no operations to apply`);
        return;
      }

      // Map slug → page_id for newly created pages within this batch
      const newPageSlugToId = new Map<string, string>();

      // US-004: pages whose page_sources changed this run — candidates for promotion.
      const sourcedPageIds = new Set<string>();

      // US-013: collect lifecycle events to push to webhook targets after commit.
      const webhookEvents: PageWebhookEvent[] = [];

      // Helper: resolve a page_id reference (may be a recalled uuid or a new: slug)
      const resolvePageId = (ref: string): string | undefined => {
        if (ref.startsWith("new:")) {
          return newPageSlugToId.get(ref.slice(4));
        }
        return ref; // assumed uuid
      };

      // Execute each operation in sequence (within a single step for atomicity via Drizzle)
      for (const op of result.operations) {
        if (op.op === "update_page") {
          // Fetch before-state for change_log
          const [before] = await db
            .select({
              title: pages.title,
              body_md: pages.body_md,
              status: pages.status,
            })
            .from(pages)
            .where(eq(pages.id, op.page_id))
            .limit(1);

          if (!before) {
            console.warn(
              `[compile-memo] update_page: page ${op.page_id} not found, skipping`,
            );
            continue;
          }

          const embedding = await embedPageBody(op.body_md);

          const updateSet: Record<string, unknown> = {
            body_md: op.body_md,
            last_compiled_at: new Date(),
            updated_at: new Date(),
            version: sql`${pages.version} + 1`,
          };
          if (op.title) updateSet.title = op.title;
          if (embedding) updateSet.embedding = embedding;

          await db.update(pages).set(updateSet).where(eq(pages.id, op.page_id));

          await db.insert(change_log).values({
            user_id,
            action_kind: "update_page",
            target_type: "page",
            target_id: op.page_id,
            before: before as Record<string, unknown>,
            after: { title: op.title ?? before.title, body_md: op.body_md },
            reason: op.rationale ?? null,
            performed_by: "agent",
            agent_action_id: memo_id,
          });

          webhookEvents.push({
            action_kind: "update_page",
            target_type: "page",
            target_id: op.page_id,
            after: { title: op.title ?? before.title },
            reason: op.rationale ?? null,
            performed_by: "agent",
          });

          // Link to memo via page_sources
          await db
            .insert(page_sources)
            .values({ page_id: op.page_id, memo_id, weight: 1 })
            .onConflictDoNothing();
          sourcedPageIds.add(op.page_id);
        } else if (op.op === "create_page" || op.op === "extract_entity") {
          const pageType =
            op.op === "extract_entity"
              ? ("entity" as const)
              : (op.type as "concept" | "entity" | "synthesis");

          const embedding = await embedPageBody(op.body_md);

          const [newPage] = await db
            .insert(pages)
            .values({
              user_id,
              slug: op.slug,
              type: pageType,
              title: op.title,
              status: "draft",
              body_md: op.body_md,
              embedding: embedding ?? undefined,
              last_compiled_at: new Date(),
            })
            .onConflictDoUpdate({
              target: [pages.user_id, pages.slug],
              set: {
                title: op.title,
                body_md: op.body_md,
                ...(embedding ? { embedding } : {}),
                last_compiled_at: new Date(),
                updated_at: new Date(),
              },
            })
            .returning({ id: pages.id });

          if (!newPage) continue;

          newPageSlugToId.set(op.slug, newPage.id);

          await db.insert(change_log).values({
            user_id,
            action_kind: op.op,
            target_type: "page",
            target_id: newPage.id,
            before: null,
            after: { slug: op.slug, title: op.title, type: pageType },
            reason: op.rationale ?? null,
            performed_by: "agent",
            agent_action_id: memo_id,
          });

          webhookEvents.push({
            action_kind: op.op,
            target_type: "page",
            target_id: newPage.id,
            after: { slug: op.slug, title: op.title, type: pageType },
            reason: op.rationale ?? null,
            performed_by: "agent",
          });

          await db
            .insert(page_sources)
            .values({ page_id: newPage.id, memo_id, weight: 1 })
            .onConflictDoNothing();
          sourcedPageIds.add(newPage.id);
        } else if (op.op === "create_link") {
          const fromId = resolvePageId(op.from_page_id);
          const toId = resolvePageId(op.to_page_id);

          if (!fromId || !toId) {
            console.warn(
              `[compile-memo] create_link: cannot resolve IDs ${op.from_page_id} → ${op.to_page_id}, skipping`,
            );
            continue;
          }

          await db.insert(page_links).values({
            user_id,
            from_page_id: fromId,
            to_page_id: toId,
            via_memo_id: memo_id,
            weight: 1,
            rationale: op.rationale ?? null,
          });

          await db.insert(change_log).values({
            user_id,
            action_kind: "create_link",
            target_type: "page_link",
            target_id: `${fromId}→${toId}`,
            before: null,
            after: { from_page_id: fromId, to_page_id: toId },
            reason: op.rationale ?? null,
            performed_by: "agent",
            agent_action_id: memo_id,
          });

          // Update backlink_count on target page
          await db
            .update(pages)
            .set({
              backlink_count: sql`${pages.backlink_count} + 1`,
              updated_at: new Date(),
            })
            .where(eq(pages.id, toId));
        }
      }

      // Update source_count on all recalled pages that were updated
      const updatedPageIds = result.operations
        .filter(
          (o): o is Extract<FullOperation, { op: "update_page" }> =>
            o.op === "update_page",
        )
        .map((o) => o.page_id);

      for (const pid of updatedPageIds) {
        await db
          .update(pages)
          .set({
            source_count: sql`${pages.source_count} + 1`,
          })
          .where(eq(pages.id, pid));
      }

      // US-004: promote any draft page now referenced by ≥2 sources → live.
      // (promoteBySourceCount fires its own `promote_page` webhooks.)
      await promoteBySourceCount(user_id, Array.from(sourcedPageIds));

      // US-013: push create/update lifecycle events to webhook targets.
      await dispatchPageWebhooks(user_id, webhookEvents);
    });

    // ── commit-to-tree (US-018) ─────────────────────────────────────────────────
    // Best-effort: commit this compiled memo onto its most relevant task-tree
    // node (heat bump + evidence). Runs in its own step so it does not block or
    // roll back the already-applied pages above. Any failure is logged as a
    // warning and swallowed — never throw.
    await step.run("commit-to-tree", async () => {
      try {
        const [memo] = await db
          .select({ embedding: memos.embedding, user_id: memos.user_id })
          .from(memos)
          .where(eq(memos.id, memo_id))
          .limit(1);

        if (!memo) {
          console.warn(
            `[compile-memo] commit-to-tree: memo ${memo_id} not found, skipping`,
          );
          return;
        }

        const result = await commitMemoToTree(liveCommitMemoTreeDeps, {
          userId: memo.user_id,
          memoId: memo_id,
          embedding: memo.embedding ?? null,
        });

        if (result.committed) {
          console.log(
            `[compile-memo] commit-to-tree: memo ${memo_id} committed to node ${result.node_id} (heat → ${result.heat_to})`,
          );

          // US-020: event-driven evolution. If THIS commit pushed the node's
          // heat across the evolve threshold, request the tree to evolve. Firing
          // only on the crossing (not every commit) keeps a hot tree from
          // re-evolving on every subsequent memo. sendEvent no-ops in dev
          // without Inngest, so this is safe to call unconditionally.
          const heatBefore = result.heat_to - COMMIT_HEAT_INCREMENT;
          if (crossedEvolveThreshold(heatBefore, result.heat_to)) {
            await sendEvent({
              name: "gateway/evolve.requested",
              data: { treeId: result.tree_id },
            });
            console.log(
              `[compile-memo] commit-to-tree: tree ${result.tree_id} crossed evolve threshold (heat → ${result.heat_to}), requested evolve`,
            );
          }
        } else {
          console.log(
            `[compile-memo] commit-to-tree: memo ${memo_id} not committed (${result.reason})`,
          );
        }
      } catch (err: unknown) {
        // Non-fatal: tree commit failure must not roll back the compiled page.
        console.warn(
          `[compile-memo] commit-to-tree: error (non-fatal) — ${String(err)}`,
        );
      }
    });

    // ── notify ────────────────────────────────────────────────────────────────
    await step.run("notify", async () => {
      console.log(`[compile-memo] notify: memo ${memo_id}`);
      await db
        .update(memos)
        .set({ compile_status: "done" })
        .where(eq(memos.id, memo_id));
    });

    return { memo_id, status: "done" };
  },
);
