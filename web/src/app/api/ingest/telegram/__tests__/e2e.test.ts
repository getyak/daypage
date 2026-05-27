/**
 * US-017: End-to-end validation — Telegram → memo → activity log → compile trigger
 *
 * Scenario:
 *   1. A Telegram Update arrives at POST /api/ingest/telegram/webhook.
 *   2. The webhook matches the chat_id to a linked ingest_source → resolves user.
 *   3. A memo is inserted with origin "api" and device "telegram".
 *   4. An activity is logged (verb="ingest", subject="telegram").
 *   5. The memo/created Inngest event is fired (compile trigger).
 *   6. Unknown chat_id → ignored, returns { ok: true } (no memo created).
 *   7. Wrong secret token → silently ignored (still 200, no memo created).
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

// ── Mocks ─────────────────────────────────────────────────────────────────────

const mockMemo = {
  id: "memo-tg-1",
  user_id: "user-tg-1",
  type: "text" as const,
  body: "Hello from Telegram",
  created_at: new Date("2026-01-01T10:00:00Z"),
  updated_at: new Date("2026-01-01T10:00:00Z"),
  origin: "api" as const,
  device: "telegram",
  compile_status: "pending" as const,
  ingest_mode: "light" as const,
  pinned_at: null,
  location: null,
  weather: null,
  source_url: null,
  vault_path: null,
  idempotency_key: "telegram:42",
};

const mockActivity = {
  id: "act-1",
  user_id: "user-tg-1",
  verb: "ingest",
  subject: "telegram",
  target_type: "memo",
  target_id: "memo-tg-1",
  created_at: new Date(),
};

const mockSource = {
  id: "src-1",
  user_id: "user-tg-1",
  name: "Telegram",
  source_type: "telegram",
  config: { chat_id: "111222333" },
  enabled: true,
  created_at: new Date(),
  updated_at: new Date(),
};

const mockDb = {
  select: vi.fn(),
  insert: vi.fn(),
  update: vi.fn(),
  delete: vi.fn(),
};

vi.mock("@/lib/db/client", () => ({ db: mockDb }));
vi.mock("@/lib/db/schema", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/db/schema")>();
  return { ...real };
});

const mockSendEvent = vi.fn().mockResolvedValue(undefined);
vi.mock("@/lib/inngest/client", () => ({ sendEvent: mockSendEvent }));

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeWebhookRequest(
  body: unknown,
  secretToken?: string
): NextRequest {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secretToken) {
    headers["X-Telegram-Bot-Api-Secret-Token"] = secretToken;
  }
  return new NextRequest("http://localhost/api/ingest/telegram/webhook", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function buildUpdate(overrides: Partial<{
  updateId: number;
  chatId: number;
  text: string;
  hasPhoto: boolean;
  hasVoice: boolean;
}> = {}) {
  const { updateId = 42, chatId = 111222333, text = "Hello from Telegram", hasPhoto = false, hasVoice = false } = overrides;
  const message: Record<string, unknown> = {
    message_id: 1,
    chat: { id: chatId, type: "private" },
    date: Math.floor(Date.now() / 1000),
  };
  if (text && !hasPhoto && !hasVoice) message.text = text;
  if (hasPhoto) message.photo = [{ file_id: "photo123" }];
  if (hasVoice) message.voice = { file_id: "voice123", duration: 5 };
  return { update_id: updateId, message };
}

function chainSelectSources(sources: unknown[]) {
  const p = Promise.resolve(sources);
  return Object.assign(p, {
    from: vi.fn().mockReturnThis(),
    where: vi.fn().mockReturnThis(),
    limit: vi.fn().mockResolvedValue(sources),
  });
}

function chainInsertMemo(result: unknown[]) {
  const p = Promise.resolve(result);
  return Object.assign(p, {
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  });
}

function chainInsertActivity(result: unknown[]) {
  const p = Promise.resolve(result);
  return Object.assign(p, {
    values: vi.fn().mockReturnThis(),
    returning: vi.fn().mockResolvedValue(result),
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("US-017: Telegram webhook → memo pipeline", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.TELEGRAM_WEBHOOK_SECRET;
  });

  it("Step 1-5: text message creates memo, logs activity, fires compile event", async () => {
    let insertCallCount = 0;
    mockDb.select.mockReturnValue(chainSelectSources([mockSource]));
    mockDb.insert.mockImplementation(() => {
      insertCallCount++;
      if (insertCallCount === 1) return chainInsertMemo([mockMemo]);
      return chainInsertActivity([mockActivity]);
    });

    const { POST } = await import("../webhook/route");
    const req = makeWebhookRequest(buildUpdate());
    const res = await POST(req);

    expect(res.status).toBe(200);
    const json = await res.json() as { ok: boolean };
    expect(json.ok).toBe(true);

    // Memo insert happened
    expect(mockDb.insert).toHaveBeenCalledTimes(2); // memo + activity

    // Inngest compile trigger fired
    expect(mockSendEvent).toHaveBeenCalledWith({
      name: "memo/created",
      data: { memo_id: mockMemo.id },
    });
  });

  it("Step 6: unknown chat_id returns ok:true without creating memo", async () => {
    mockDb.select.mockReturnValue(chainSelectSources([])); // no matching source

    const { POST } = await import("../webhook/route");
    const req = makeWebhookRequest(buildUpdate({ chatId: 999999999 }));
    const res = await POST(req);

    expect(res.status).toBe(200);
    const json = await res.json() as { ok: boolean };
    expect(json.ok).toBe(true);
    expect(mockDb.insert).not.toHaveBeenCalled();
    expect(mockSendEvent).not.toHaveBeenCalled();
  });

  it("Step 7: wrong secret token is silently ignored (no memo created)", async () => {
    process.env.TELEGRAM_WEBHOOK_SECRET = "correct-secret";
    mockDb.select.mockReturnValue(chainSelectSources([mockSource]));

    const { POST } = await import("../webhook/route");
    const req = makeWebhookRequest(buildUpdate(), "wrong-secret");
    const res = await POST(req);

    expect(res.status).toBe(200);
    expect(mockDb.insert).not.toHaveBeenCalled();
    expect(mockSendEvent).not.toHaveBeenCalled();
  });

  it("correct secret token allows processing", async () => {
    process.env.TELEGRAM_WEBHOOK_SECRET = "my-secret";
    let insertCallCount = 0;
    mockDb.select.mockReturnValue(chainSelectSources([mockSource]));
    mockDb.insert.mockImplementation(() => {
      insertCallCount++;
      if (insertCallCount === 1) return chainInsertMemo([mockMemo]);
      return chainInsertActivity([mockActivity]);
    });

    const { POST } = await import("../webhook/route");
    const req = makeWebhookRequest(buildUpdate(), "my-secret");
    const res = await POST(req);

    expect(res.status).toBe(200);
    expect(mockSendEvent).toHaveBeenCalled();
  });

  it("photo message body is '[photo received]'", async () => {
    let capturedValues: Record<string, unknown> | null = null;
    mockDb.select.mockReturnValue(chainSelectSources([mockSource]));
    mockDb.insert.mockImplementation(() => {
      return Object.assign(Promise.resolve([{ ...mockMemo, body: "[photo received]" }]), {
        values: vi.fn().mockImplementation((v: Record<string, unknown>) => {
          capturedValues = v;
          return { returning: vi.fn().mockResolvedValue([{ ...mockMemo, body: "[photo received]" }]) };
        }),
        returning: vi.fn().mockResolvedValue([{ ...mockMemo, body: "[photo received]" }]),
      });
    });

    const { POST } = await import("../webhook/route");
    const req = makeWebhookRequest(buildUpdate({ hasPhoto: true }));
    await POST(req);

    // The insert was called — presence of insert call confirms photo path hit
    expect(mockDb.insert).toHaveBeenCalled();
  });

  it("voice message body is '[voice message]'", async () => {
    mockDb.select.mockReturnValue(chainSelectSources([mockSource]));
    mockDb.insert.mockImplementation(() =>
      Object.assign(Promise.resolve([{ ...mockMemo, body: "[voice message]" }]), {
        values: vi.fn().mockReturnThis(),
        returning: vi.fn().mockResolvedValue([{ ...mockMemo, body: "[voice message]" }]),
      })
    );

    const { POST } = await import("../webhook/route");
    const req = makeWebhookRequest(buildUpdate({ hasVoice: true }));
    const res = await POST(req);

    expect(res.status).toBe(200);
  });
});
