import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: Request) {
  const supabase = await createClient();
  const { searchParams } = new URL(request.url);
  // Default to the formed knowledge network (live pages) — drafts are opt-in.
  const status = searchParams.get("status") ?? "live";

  let query = supabase
    .from("pages")
    .select("*")
    .order("updated_at", { ascending: false });

  if (status !== "all") {
    query = query.eq("status", status);
  }

  const { data, error } = await query;
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ pages: data ?? [] });
}
