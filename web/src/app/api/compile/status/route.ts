import { NextResponse } from "next/server";
import { isCompileServiceConnected } from "@/lib/inngest/client";

export const dynamic = "force-dynamic";

// GET /api/compile/status — reports whether the compile pipeline (Inngest) is
// actually reachable. When false, the UI must explain that compilation will not
// run rather than show memos stuck at "queued" forever.
export async function GET() {
  return NextResponse.json({ connected: await isCompileServiceConnected() });
}
