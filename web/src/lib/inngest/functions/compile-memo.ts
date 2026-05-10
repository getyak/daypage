import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { memos, embed_cache } from "@/lib/db/schema";
import { eq, and, gte } from "drizzle-orm";
import { dashscope } from "@/lib/ai/dashscope";
import { chunkText, averageEmbeddings, hashText } from "@/lib/ai/embed-utils";
import { ProviderError } from "@/lib/ai/provider";

const EMBED_CACHE_TTL_DAYS = 7;

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

    await step.run("compile", async () => {
      console.log(`[compile-memo] compile: memo ${memo_id}`);
    });

    await step.run("apply", async () => {
      console.log(`[compile-memo] apply: memo ${memo_id}`);
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
