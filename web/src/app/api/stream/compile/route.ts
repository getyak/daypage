import { NextRequest } from "next/server";
import { auth } from "@/auth";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and, gte } from "drizzle-orm";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const POLL_INTERVAL_MS = 2000;
const HEARTBEAT_INTERVAL_MS = 15000;

function sseEvent(data: Record<string, unknown>): string {
  return `data: ${JSON.stringify(data)}\n\n`;
}

// GET /api/stream/compile — SSE stream for compile progress scoped to current user
export async function GET(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.email) {
    return new Response("Unauthorized", { status: 401 });
  }

  const userRows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, session.user.email))
    .limit(1);

  if (!userRows.length) {
    return new Response("Unauthorized", { status: 401 });
  }
  const userId = userRows[0].id;

  // Track last-seen status per memo_id so we only emit on change
  const lastSeen = new Map<string, string>();
  // Only track memos from the last 24h to avoid processing the whole history
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000);

  let closed = false;
  req.signal.addEventListener("abort", () => {
    closed = true;
  });

  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();

      const send = (data: Record<string, unknown>) => {
        if (closed) return;
        try {
          controller.enqueue(encoder.encode(sseEvent(data)));
        } catch {
          closed = true;
        }
      };

      // Poll loop
      let lastHeartbeat = Date.now();

      while (!closed) {
        const now = Date.now();

        // Heartbeat
        if (now - lastHeartbeat >= HEARTBEAT_INTERVAL_MS) {
          send({ type: "ping" });
          lastHeartbeat = now;
        }

        // Poll memos for status changes
        try {
          const rows = await db
            .select({
              id: memos.id,
              compile_status: memos.compile_status,
              compile_error: memos.compile_error,
              updated_at: memos.updated_at,
            })
            .from(memos)
            .where(
              and(
                eq(memos.user_id, userId),
                gte(memos.created_at, since)
              )
            );

          for (const row of rows) {
            const prev = lastSeen.get(row.id);
            const curr = row.compile_status;
            if (prev !== curr) {
              lastSeen.set(row.id, curr);

              // Map status → step label + progress
              const stepInfo = statusToStep(curr);
              send({
                type: "progress",
                memo_id: row.id,
                status: curr,
                step: stepInfo.step,
                progress: stepInfo.progress,
                error: row.compile_error ?? undefined,
              });
            }
          }
        } catch (err) {
          // DB error — emit error event and continue
          send({ type: "error", message: String(err) });
        }

        // Wait POLL_INTERVAL_MS, but check abort signal frequently
        await sleepInterruptible(POLL_INTERVAL_MS, () => closed);
      }

      try {
        controller.close();
      } catch {
        // already closed
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
}

function statusToStep(
  status: string
): { step: string | undefined; progress: number | undefined } {
  switch (status) {
    case "pending":
      return { step: "Queued", progress: 0 };
    case "running":
      return { step: "Processing...", progress: 25 };
    case "done":
      return { step: "Done", progress: 100 };
    case "failed":
      return { step: "Failed", progress: undefined };
    default:
      return { step: undefined, progress: undefined };
  }
}

function sleepInterruptible(ms: number, isClosed: () => boolean): Promise<void> {
  return new Promise((resolve) => {
    const step = 100;
    let elapsed = 0;
    const tick = () => {
      if (isClosed() || elapsed >= ms) {
        resolve();
        return;
      }
      elapsed += step;
      setTimeout(tick, step);
    };
    setTimeout(tick, step);
  });
}
