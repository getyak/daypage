import { NextResponse } from "next/server";
import { db } from "@/lib/db/client";
import { sql } from "drizzle-orm";

export async function GET() {
  let dbStatus: "connected" | "error" = "error";

  try {
    await db.execute(sql`SELECT 1`);
    dbStatus = "connected";
  } catch {
    // db unreachable
  }

  const status = dbStatus === "connected" ? "ok" : "degraded";

  return NextResponse.json(
    { status, timestamp: new Date().toISOString(), db: dbStatus },
    { status: dbStatus === "connected" ? 200 : 503 }
  );
}
