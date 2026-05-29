import { Inngest } from "inngest";

export const inngest = new Inngest({ id: "daypage" });

type InngestEvent = Parameters<typeof inngest.send>[0];

/**
 * Whether sendEvent() will actually dispatch to Inngest, or silently no-op.
 * In development without INNGEST_EVENT_KEY the compile pipeline never runs, so
 * the UI must surface that instead of showing a memo stuck at "queued" forever.
 * Returns false in exactly the cases sendEvent() short-circuits.
 */
export function isCompileServiceConnected(): boolean {
  const isDev =
    process.env.NODE_ENV === "development" ||
    process.env.E2E_DEV_LOGIN === "1";
  const hasEventKey = Boolean(process.env.INNGEST_EVENT_KEY);

  return !(isDev && !hasEventKey);
}

/**
 * Wraps inngest.send() with a dev-mode fallback.
 * When INNGEST_EVENT_KEY is absent in development, sending would throw a 401
 * from the Inngest API. This helper no-ops in that case so the memo is still
 * persisted and the UI returns to its default state — the compile step simply
 * never runs, which is acceptable for local dev without Inngest running.
 */
export async function sendEvent(event: InngestEvent): Promise<void> {
  if (!isCompileServiceConnected()) {
    return;
  }

  await inngest.send(event);
}
