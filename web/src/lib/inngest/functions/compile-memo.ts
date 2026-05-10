import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { memos } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

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
        .set({ compile_status: "running" })
        .where(eq(memos.id, memo_id));
    });

    await step.run("embed", async () => {
      console.log(`[compile-memo] embed: memo ${memo_id}`);
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
