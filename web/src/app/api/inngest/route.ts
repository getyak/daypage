import { serve } from "inngest/next";
import { inngest } from "@/lib/inngest/client";
import { compileMemo } from "@/lib/inngest/functions/compile-memo";
import { dailyPage } from "@/lib/inngest/functions/daily-page";
import { schemaDetect } from "@/lib/inngest/functions/schema-detect";
import { orphanDetect } from "@/lib/inngest/functions/orphan-detect";

export const { GET, POST, PUT } = serve({
  client: inngest,
  functions: [compileMemo, dailyPage, schemaDetect, orphanDetect],
});
