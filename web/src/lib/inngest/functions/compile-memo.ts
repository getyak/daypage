import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { memos, embed_cache, pages, page_sources } from "@/lib/db/schema";
import { eq, and, gte } from "drizzle-orm";
import { dashscope } from "@/lib/ai/dashscope";
import { chunkText, averageEmbeddings, hashText } from "@/lib/ai/embed-utils";
import { ProviderError } from "@/lib/ai/provider";
import fs from "fs";
import path from "path";

const EMBED_CACHE_TTL_DAYS = 7;

// Load prompt template once at module level
const COMPILE_LIGHT_PROMPT = fs.readFileSync(
  path.join(process.cwd(), "src/lib/ai/prompts/compile-light.md"),
  "utf-8"
);

type LightCompileResult = {
  summary: string;
  keywords: string[];
  suggested_domain: string | null;
};

function buildLightPrompt(memoBody: string): string {
  return COMPILE_LIGHT_PROMPT.replace("{{MEMO_BODY}}", memoBody);
}

// Strict JSON parser for LLM output — strips markdown code fences if present
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

// Derive a slug from the body (first 60 chars, lowercased, dasherized)
function slugFromBody(body: string, id: string): string {
  const base = body
    .slice(0, 60)
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
  // Append memo id suffix to ensure uniqueness
  return `source/${base || "memo"}-${id.slice(0, 8)}`;
}

export const compileMemo = inngest.createFunction(
  { id: "compile-memo", name: "Compile Memo" },
  { event: "memo/created" },
  async ({ event, step }) => {
    const { memo_id } = event.data as { memo_id: string };

    // Mark as running
    await step.run("normalize", async () => {
      console.log(`[compile-memo] normalize: memo ${memo_id}`);
      await db
        .update(memos)
        .set({ compile_status: "running", compile_error: null })
        .where(eq(memos.id, memo_id));
    });

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
          Date.now() - EMBED_CACHE_TTL_DAYS * 24 * 60 * 60 * 1000
        );

        // Check embed cache
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

        let embedding: number[];

        if (cached) {
          console.log(`[compile-memo] embed: cache hit for ${memo_id}`);
          embedding = JSON.parse(cached.embedding) as number[];
        } else {
          const chunks = chunkText(memo.body);
          const embeddings: number[][] = [];
          for (const chunk of chunks) {
            const result = await dashscope.embed(chunk);
            embeddings.push(result.embedding);
          }
          embedding = averageEmbeddings(embeddings);

          // Store in cache (upsert by hash)
          await db
            .insert(embed_cache)
            .values({ body_hash: bodyHash, embedding: JSON.stringify(embedding) })
            .onConflictDoUpdate({
              target: embed_cache.body_hash,
              set: { embedding: JSON.stringify(embedding), created_at: new Date() },
            });
        }

        await db
          .update(memos)
          .set({ embedding: JSON.stringify(embedding) })
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
        throw err; // surface to Inngest for retry
      }
    });

    await step.run("recall", async () => {
      console.log(`[compile-memo] recall: memo ${memo_id}`);
    });

    // ── compile ──────────────────────────────────────────────────────────────
    // Stored in the step result so "apply" can consume it without a second LLM call.
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

      if (!memo) {
        throw new Error(`Memo not found: ${memo_id}`);
      }

      if (memo.ingest_mode !== "light") {
        console.log(`[compile-memo] compile: ingest_mode=${memo.ingest_mode}, skipping LIGHT step`);
        return null;
      }

      if (!memo.body.trim()) {
        console.log(`[compile-memo] compile: empty body, skipping`);
        return null;
      }

      const promptContent = buildLightPrompt(memo.body);
      const systemPrompt =
        "You are a personal knowledge assistant. Always respond with valid JSON only. No prose, no markdown outside the JSON object.";

      // First attempt
      let raw: string;
      try {
        const res = await dashscope.chat(
          [
            { role: "system", content: systemPrompt },
            { role: "user", content: promptContent },
          ],
          { jsonMode: true, temperature: 0.3, maxTokens: 512 }
        );
        raw = res.content;
      } catch (err: unknown) {
        const message =
          err instanceof ProviderError ? `${err.code}: ${err.message}` : String(err);
        console.error(`[compile-memo] compile LLM error: ${message}`);
        await db
          .update(memos)
          .set({ compile_status: "failed", compile_error: message })
          .where(eq(memos.id, memo_id));
        throw err;
      }

      // Parse — retry once with stricter prompt if first attempt fails
      let result: LightCompileResult;
      try {
        result = parseLightResult(raw);
      } catch {
        console.warn(`[compile-memo] compile: invalid JSON on first attempt, retrying`);
        const stricterPrompt = `${promptContent}\n\nIMPORTANT: Return ONLY the JSON object. No explanation. No markdown. No code fences.`;
        let raw2: string;
        try {
          const res2 = await dashscope.chat(
            [
              { role: "system", content: systemPrompt },
              { role: "user", content: stricterPrompt },
            ],
            { jsonMode: true, temperature: 0.1, maxTokens: 512 }
          );
          raw2 = res2.content;
        } catch (err: unknown) {
          const message =
            err instanceof ProviderError ? `${err.code}: ${err.message}` : String(err);
          console.error(`[compile-memo] compile retry LLM error: ${message}`);
          await db
            .update(memos)
            .set({ compile_status: "failed", compile_error: message })
            .where(eq(memos.id, memo_id));
          throw err;
        }

        try {
          result = parseLightResult(raw2);
        } catch (parseErr: unknown) {
          const message = `invalid_json: ${String(parseErr)}`;
          console.error(`[compile-memo] compile: second parse failed — ${message}`);
          await db
            .update(memos)
            .set({ compile_status: "failed", compile_error: message })
            .where(eq(memos.id, memo_id));
          throw new Error(message);
        }
      }

      return { result, user_id: memo.user_id, body: memo.body };
    });

    // ── apply ────────────────────────────────────────────────────────────────
    await step.run("apply", async () => {
      console.log(`[compile-memo] apply: memo ${memo_id}`);

      if (!compileResult) {
        console.log(`[compile-memo] apply: nothing to apply`);
        return;
      }

      const { result, user_id, body } = compileResult;

      const slug = slugFromBody(body, memo_id);
      // Title: first 80 chars of body, or fall back to summary
      const title =
        body.trim().slice(0, 80) || result.summary.slice(0, 80) || "Untitled";

      // Upsert the source page (conflict on user_id+slug → update body/metadata)
      const [page] = await db
        .insert(pages)
        .values({
          user_id,
          slug,
          type: "source",
          title,
          status: "draft",
          body_md: result.summary,
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

      // Link page ↔ memo via page_sources (ignore conflict if already linked)
      await db
        .insert(page_sources)
        .values({ page_id: page.id, memo_id, weight: 1 })
        .onConflictDoNothing();
    });

    await step.run("notify", async () => {
      console.log(`[compile-memo] notify: memo ${memo_id}`);
      await db
        .update(memos)
        .set({ compile_status: "done" })
        .where(eq(memos.id, memo_id));
    });

    return { memo_id, status: "done" };
  }
);
