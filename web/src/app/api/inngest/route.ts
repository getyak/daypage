import { serve } from "inngest/next";
import { inngest } from "@/lib/inngest/client";
import { compileMemo } from "@/lib/inngest/functions/compile-memo";
import { dailyPage } from "@/lib/inngest/functions/daily-page";
import { schemaDetect } from "@/lib/inngest/functions/schema-detect";
import { orphanDetect } from "@/lib/inngest/functions/orphan-detect";
import { gapDetect } from "@/lib/inngest/functions/gap-detect";
import { weeklyReport } from "@/lib/inngest/functions/weekly-report";
import { fetchRss } from "@/lib/inngest/functions/fetch-rss";
import { weaveGraph } from "@/lib/inngest/functions/weave-graph";
import { suggesterRun } from "@/lib/inngest/functions/suggester-run";
import { schedulerTick } from "@/lib/inngest/functions/scheduler-tick";
import { executorDispatch } from "@/lib/inngest/functions/executor-dispatch";

export const { GET, POST, PUT } = serve({
  client: inngest,
  functions: [
    compileMemo,
    dailyPage,
    schemaDetect,
    orphanDetect,
    gapDetect,
    weeklyReport,
    fetchRss,
    weaveGraph,
    suggesterRun,
    schedulerTick,
    executorDispatch,
  ],
});
