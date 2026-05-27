import { db } from "@/lib/db/client";
import { api_logs } from "@/lib/db/schema";

interface LogApiErrorOptions {
  method: string;
  path: string;
  status: number;
  durationMs: number;
  userId?: string | null;
  error?: string;
}

// Fire-and-forget: write 4xx/5xx request logs to api_logs table
export async function logApiError(opts: LogApiErrorOptions): Promise<void> {
  try {
    await db.insert(api_logs).values({
      method: opts.method,
      path: opts.path,
      status: opts.status,
      duration_ms: opts.durationMs,
      user_id: opts.userId ?? null,
      error: opts.error ?? null,
    });
  } catch {
    // Non-fatal: logging must never break the response
  }
}
