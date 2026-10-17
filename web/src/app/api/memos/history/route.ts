import { NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { supabaseMemoStore, type QueryBuilderLike } from "@/lib/memos/store";
import { handleHistoryRequest } from "@/lib/memos/history-route";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// GET /api/memos/history — account-scoped, read-only memo history.
//
// Identity comes from the cookie-bound Supabase SSR client's verified
// `auth.getUser().id` (works without an email); reads run through RLS plus
// explicit user_id predicates. This dedicated endpoint keeps the legacy
// GET /api/memos timestamp-cursor contract untouched for existing callers.
export async function GET(request: NextRequest) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  return handleHistoryRequest(request, {
    userId: user?.id ?? null,
    store: supabaseMemoStore({
      from: (table) => supabase.from(table) as unknown as QueryBuilderLike,
    }),
  });
}
