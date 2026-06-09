import { describe, it, expect, vi } from "vitest";

import {
  sendSuggestions,
  truncateButtonText,
  type OutboundSuggestion,
} from "../telegram";

// US-010 tests. The adapter's contract is: POST a well-formed `sendMessage`
// body to the Telegram Bot API with one inline-keyboard button per suggestion
// (`callback_data='pick:<id>'`), and never throw — return `{ ok:false, error }`
// on any failure. We mock `fetch` to assert the request body structure and the
// failure handling.

const BOT_TOKEN = "test-bot-token";

const SUGGESTIONS: OutboundSuggestion[] = [
  { id: "s-1", title: "Draft the wiki concept page", rationale: "3 memos cite it but no page exists" },
  { id: "s-2", title: "Backfill last week's gaps", rationale: null },
];

// A fetch mock that resolves to a Telegram-style 2xx success response. Typed
// to accept fetch's args so `mock.calls[0]` is `[url, init]`, not `[]`.
function okFetch(messageId = 42) {
  return vi.fn(async (_url: string, _init?: RequestInit) =>
    new Response(JSON.stringify({ ok: true, result: { message_id: messageId } }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    })
  );
}

describe("sendSuggestions", () => {
  it("POSTs a well-formed sendMessage request to the bot API", async () => {
    const fetchImpl = okFetch();

    const result = await sendSuggestions({
      chatId: "12345",
      suggestions: SUGGESTIONS,
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result).toEqual({ ok: true, messageId: 42 });
    expect(fetchImpl).toHaveBeenCalledOnce();

    const [url, init] = fetchImpl.mock.calls[0]!;
    expect(url).toBe(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`);
    expect(init!.method).toBe("POST");
    expect((init!.headers as Record<string, string>)["Content-Type"]).toBe(
      "application/json"
    );

    const body = JSON.parse(init!.body as string);
    expect(body.chat_id).toBe("12345");
    // Body text carries both titles and the present rationale.
    expect(body.text).toContain("Draft the wiki concept page");
    expect(body.text).toContain("3 memos cite it but no page exists");
    expect(body.text).toContain("Backfill last week's gaps");

    // One inline-keyboard row per suggestion, each a single pick button.
    const keyboard = body.reply_markup.inline_keyboard;
    expect(keyboard).toHaveLength(2);
    expect(keyboard[0]).toHaveLength(1);
    expect(keyboard[0][0].callback_data).toBe("pick:s-1");
    expect(keyboard[1][0].callback_data).toBe("pick:s-2");
    expect(keyboard[0][0].text).toContain("Draft the wiki concept page");
  });

  it("passes a numeric chatId straight through", async () => {
    const fetchImpl = okFetch();
    await sendSuggestions({
      chatId: 987654,
      suggestions: SUGGESTIONS,
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const [, init] = fetchImpl.mock.calls[0]!;
    const body = JSON.parse(init!.body as string);
    expect(body.chat_id).toBe(987654);
  });

  it("truncates long button labels within the Telegram limit", async () => {
    const fetchImpl = okFetch();
    const longTitle = "x".repeat(200);
    await sendSuggestions({
      chatId: "1",
      suggestions: [{ id: "s-long", title: longTitle }],
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    const [, init] = fetchImpl.mock.calls[0]!;
    const body = JSON.parse(init!.body as string);
    const label: string = body.reply_markup.inline_keyboard[0][0].text;
    expect([...label].length).toBeLessThanOrEqual(60);
    expect(label.endsWith("…")).toBe(true);
    // callback_data is unaffected by label truncation.
    expect(body.reply_markup.inline_keyboard[0][0].callback_data).toBe(
      "pick:s-long"
    );
  });

  it("returns {ok:false} without throwing on a network error", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    });

    const result = await sendSuggestions({
      chatId: "1",
      suggestions: SUGGESTIONS,
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toContain("ECONNREFUSED");
  });

  it("returns {ok:false} on a non-OK HTTP response", async () => {
    const fetchImpl = vi.fn(async () =>
      new Response("Bad Request: chat not found", { status: 400 })
    );

    const result = await sendSuggestions({
      chatId: "1",
      suggestions: SUGGESTIONS,
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toContain("400");
      expect(result.error).toContain("chat not found");
    }
  });

  it("returns {ok:false} when Telegram replies ok:false on a 2xx", async () => {
    const fetchImpl = vi.fn(async () =>
      new Response(JSON.stringify({ ok: false, description: "blocked" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    );

    const result = await sendSuggestions({
      chatId: "1",
      suggestions: SUGGESTIONS,
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(result.ok).toBe(false);
  });

  it("returns {ok:false} when no bot token is configured", async () => {
    const fetchImpl = okFetch();
    const prev = process.env.TELEGRAM_BOT_TOKEN;
    delete process.env.TELEGRAM_BOT_TOKEN;
    try {
      const result = await sendSuggestions({
        chatId: "1",
        suggestions: SUGGESTIONS,
        fetchImpl: fetchImpl as unknown as typeof fetch,
      });
      expect(result.ok).toBe(false);
      expect(fetchImpl).not.toHaveBeenCalled();
    } finally {
      if (prev !== undefined) process.env.TELEGRAM_BOT_TOKEN = prev;
    }
  });

  it("returns {ok:false} on an empty suggestion list", async () => {
    const fetchImpl = okFetch();
    const result = await sendSuggestions({
      chatId: "1",
      suggestions: [],
      botToken: BOT_TOKEN,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    expect(result.ok).toBe(false);
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});

describe("truncateButtonText", () => {
  it("leaves short text unchanged", () => {
    expect(truncateButtonText("hello")).toBe("hello");
  });

  it("trims long text to the limit with an ellipsis", () => {
    const out = truncateButtonText("a".repeat(100), 10);
    expect([...out].length).toBe(10);
    expect(out.endsWith("…")).toBe(true);
  });
});
