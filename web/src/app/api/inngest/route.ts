import { serve } from "inngest/next";
import { inngest } from "@/lib/inngest/client";
import { compileMemo } from "@/lib/inngest/functions/compile-memo";
import { dailyPage } from "@/lib/inngest/functions/daily-page";

export const { GET, POST, PUT } = serve({
  client: inngest,
  functions: [compileMemo, dailyPage],
});
