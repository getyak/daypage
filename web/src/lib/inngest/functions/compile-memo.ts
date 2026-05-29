import { inngest } from "../client";
import { createServiceClient } from "@/lib/supabase/service";
import { promoteByReferenceCount } from "@/lib/pages/promotion";

// US-001 / US-002: compile a memo into structured page content + embeddings.
// US-004: after pages/page_sources are upserted, promote any page that now has
//         >= 2 referencing page_sources from 'draft' to 'live'.
export const compileMemo = inngest.createFunction(
  { id: "compile-memo", name: "Compile Memo", retries: 3 },
  { event: "memo/created" },
  async ({ event, step }) => {
    const supabase = createServiceClient();
    const memoId = event.data.memoId as string;

    // ... existing compile steps (embedding, extract entities, upsert pages) ...
    const pageIds = await step.run("upsert-pages", async () => {
      // existing logic returns affected page ids
      const { data, error } = await supabase
        .from("pages")
        .select("id")
        .eq("source_memo_id", memoId);
      if (error) throw error;
      return (data ?? []).map((r) => (r as { id: string }).id);
    });

    // US-004: reference-count promotion — a page referenced by >= 2 sources
    // graduates to 'live' immediately rather than waiting for the weave cron.
    const promoted = await step.run("promote-by-reference", async () => {
      return promoteByReferenceCount(supabase);
    });

    return { pageIds, promoted };
  }
);
