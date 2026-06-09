// US-010: Telegram outbound adapter — push task suggestions to the user's
// Telegram chat as a message with one inline-keyboard button per suggestion.
// Tapping a button sends Telegram a callback query whose `callback_data` is
// `pick:<suggestion_id>`, which the dispatch handler later resolves to a
// work order.
//
// The bot token is reused from the same bot that powers the ingest webhook
// (`/api/ingest/telegram/webhook`); the webhook only verifies an inbound secret,
// so the *outbound* direction needs the bot token itself — `TELEGRAM_BOT_TOKEN`.
//
// Network/HTTP failures never throw: `sendSuggestions` always resolves to a
// discriminated result so the caller (the Gateway loop) decides whether to retry
// rather than having an exception unwind the schedule.

// ── Telegram limits ─────────────────────────────────────────────────────────
// Inline button text has a practical cap well under the 64-byte callback_data
// limit; overly long labels render poorly, so we trim to a safe length and add
// an ellipsis. Keep this conservative.
const MAX_BUTTON_TEXT = 60;

// One suggestion to render. Only the fields the message needs are required; this
// intentionally stays decoupled from the Drizzle row type so callers can pass a
// lighter projection of `task_suggestions`.
export interface OutboundSuggestion {
  id: string;
  title: string;
  // Short reason shown in the message body. Optional.
  rationale?: string | null;
}

export interface SendSuggestionsParams {
  chatId: string | number;
  suggestions: OutboundSuggestion[];
  // Override the bot token; defaults to `process.env.TELEGRAM_BOT_TOKEN`.
  // Primarily for tests.
  botToken?: string;
  // Injectable fetch for tests; defaults to the global `fetch`.
  fetchImpl?: typeof fetch;
}

export type SendSuggestionsResult =
  | { ok: true; messageId: number | null }
  | { ok: false; error: string };

// Truncate a button label to Telegram's safe length, appending an ellipsis when
// trimmed. Operates on Unicode code points (via the spread iterator) so we never
// slice through a surrogate pair / emoji.
export function truncateButtonText(text: string, max = MAX_BUTTON_TEXT): string {
  const chars = [...text];
  if (chars.length <= max) return text;
  // Reserve one slot for the ellipsis.
  return chars.slice(0, max - 1).join("") + "…";
}

// Build the human-readable message body: one numbered line per suggestion with
// its title and (when present) a one-line rationale summary.
function renderBody(suggestions: OutboundSuggestion[]): string {
  const header = "🧭 Task suggestions";
  const lines = suggestions.map((s, i) => {
    const n = i + 1;
    const rationale = s.rationale?.trim();
    const summary = rationale ? `\n   ${rationale}` : "";
    return `${n}. ${s.title}${summary}`;
  });
  return [header, "", ...lines].join("\n");
}

// Build the inline keyboard: one row per suggestion, button text truncated, and
// `callback_data` carrying the pick action the dispatch flow expects.
function renderKeyboard(suggestions: OutboundSuggestion[]) {
  return suggestions.map((s, i) => [
    {
      text: truncateButtonText(`${i + 1}. ${s.title}`),
      callback_data: `pick:${s.id}`,
    },
  ]);
}

/**
 * Send task suggestions to a Telegram chat as a message with selectable inline
 * buttons.
 *
 * Resolves to `{ ok: true, messageId }` on success or `{ ok: false, error }` on
 * any failure (missing token, network error, non-OK Telegram response). Never
 * throws — the caller owns the retry decision.
 */
export async function sendSuggestions(
  params: SendSuggestionsParams
): Promise<SendSuggestionsResult> {
  const { chatId, suggestions } = params;
  const botToken = params.botToken ?? process.env.TELEGRAM_BOT_TOKEN;
  const fetchImpl = params.fetchImpl ?? fetch;

  if (!botToken) {
    return { ok: false, error: "TELEGRAM_BOT_TOKEN not configured" };
  }
  if (suggestions.length === 0) {
    return { ok: false, error: "no suggestions to send" };
  }

  const url = `https://api.telegram.org/bot${botToken}/sendMessage`;
  const requestBody = {
    chat_id: chatId,
    text: renderBody(suggestions),
    reply_markup: {
      inline_keyboard: renderKeyboard(suggestions),
    },
  };

  let res: Response;
  try {
    res = await fetchImpl(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(requestBody),
    });
  } catch (err) {
    // Network-level failure (DNS, connection refused, timeout abort, …).
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, error: `network error: ${message}` };
  }

  if (!res.ok) {
    let detail = "";
    try {
      detail = await res.text();
    } catch {
      // Body unreadable — fall back to the status line alone.
    }
    return {
      ok: false,
      error: `telegram responded ${res.status}${detail ? `: ${detail}` : ""}`,
    };
  }

  // Telegram replies `{ ok: true, result: { message_id, … } }`. Surface the id
  // when present; a malformed-but-2xx body still counts as a soft success.
  let messageId: number | null = null;
  try {
    const data = (await res.json()) as {
      ok?: boolean;
      result?: { message_id?: number };
    };
    if (data && data.ok === false) {
      return { ok: false, error: "telegram returned ok:false" };
    }
    messageId = data?.result?.message_id ?? null;
  } catch {
    // 2xx with an unparseable body — treat as success with unknown message id.
  }

  return { ok: true, messageId };
}
