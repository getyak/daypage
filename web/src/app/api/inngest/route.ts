import { serve } from "inngest/next";
import { inngest } from "@/lib/inngest/client";
import { compileMemo } from "@/lib/inngest/functions/compile-memo";

export const { GET, POST, PUT } = serve({
  client: inngest,
  functions: [compileMemo],
});
