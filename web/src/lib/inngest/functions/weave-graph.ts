import { inngest } from "../client";
import { createServiceClient } from "@/lib/supabase/service";
import {
  pageIdsMeetingReferenceThreshold,
  promotePagesToLive,
} from "@/lib/pages/promotion";

// US-003: periodic weave-graph pipeline — synthesize entity pages from page_sources.
// US-004: any page synthesized here, or referenced by >= 2 page_sources, is
//         promoted from 'draft' to 'live' so it joins the formed knowledge network.
export const weaveGraph = inngest.createFunction(
  { id: "weave-graph", name: "Weave Graph" },
  { cron: "0 */6 * * *" },
  async ({ step }) => {
    const supabase = createServiceClient();

    // 1. Gather candidate entities referenced by page_sources
    const entities = await step.run("gather-entities", async () => {
      const { data, error } = await supabase
        .from("page_sources")
        .select("target_page_id");
      if (error) throw error;
      return data ?? [];
    });

    // 2. Count references per target page
    const counts = new Map<string, number>();
    for (const row of entities) {
      const id = (row as { target_page_id: string }).target_page_id;
      counts.set(id, (counts.get(id) ?? 0) + 1);
    }

    // 3. Synthesize each entity page (placeholder — real LLM synth later)
    const synthesized: string[] = [];
    for (const [pageId] of counts) {
      await step.run(`synth-${pageId}`, async () => {
        const { error } = await supabase
          .from("pages")
          .update({ updated_at: new Date().toISOString() })
          .eq("id", pageId);
        if (error) throw error;
      });
      synthesized.push(pageId);
    }

    // 4. Promotion (US-004): synthesized pages become 'live', as do any pages
    //    that meet the >= 2 reference threshold. Both sets are promoted together.
    const promoted = await step.run("promote-pages", async () => {
      const byReference = pageIdsMeetingReferenceThreshold(
        entities as Array<{ target_page_id: string | null }>,
      );
      const toPromote = new Set<string>([...synthesized, ...byReference]);
      return promotePagesToLive(supabase, Array.from(toPromote));
    });

    return { synthesized: synthesized.length, promoted };
  }
);
