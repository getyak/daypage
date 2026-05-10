// ─── DashScope LLM provider (OpenAI-compatible endpoint) ──────────────────────
// Server-only — DASHSCOPE_API_KEY is never exposed to the client.

import "server-only";
import {
  LLMProvider,
  ChatMessage,
  ChatResponse,
  EmbedResponse,
  TranscribeResponse,
  ProviderError,
} from "./provider";
import { logPrompt } from "./prompt-log";

const BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1";

const DEFAULT_CHAT_MODEL = "qwen-plus";
const DEFAULT_EMBED_MODEL = "text-embedding-v3";
const DEFAULT_TRANSCRIBE_MODEL = "paraformer-v2";

function getApiKey(): string {
  const key = process.env.DASHSCOPE_API_KEY;
  if (!key) throw new ProviderError("auth", "DASHSCOPE_API_KEY is not set");
  return key;
}

function mapHttpError(status: number, body: string): ProviderError {
  if (status === 429)
    return new ProviderError("rate_limit", `DashScope rate limit: ${body}`);
  if (status === 401 || status === 403)
    return new ProviderError("auth", `DashScope auth error (${status}): ${body}`);
  if (status >= 500)
    return new ProviderError("server", `DashScope server error (${status}): ${body}`);
  return new ProviderError("server", `DashScope unexpected status ${status}: ${body}`);
}

async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs = 30_000
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch (err: unknown) {
    if (err instanceof Error && err.name === "AbortError") {
      throw new ProviderError("timeout", `Request timed out after ${timeoutMs}ms`);
    }
    throw new ProviderError("server", "Network error", err);
  } finally {
    clearTimeout(timer);
  }
}

export class DashScopeProvider implements LLMProvider {
  async chat(
    messages: ChatMessage[],
    opts: {
      model?: string;
      temperature?: number;
      maxTokens?: number;
      jsonMode?: boolean;
    } = {}
  ): Promise<ChatResponse> {
    const model = opts.model ?? DEFAULT_CHAT_MODEL;
    const body: Record<string, unknown> = {
      model,
      messages,
      temperature: opts.temperature ?? 0.7,
    };
    if (opts.maxTokens) body.max_tokens = opts.maxTokens;
    if (opts.jsonMode) body.response_format = { type: "json_object" };

    const res = await fetchWithTimeout(
      `${BASE_URL}/chat/completions`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${getApiKey()}`,
        },
        body: JSON.stringify(body),
      }
    );

    const text = await res.text();
    if (!res.ok) throw mapHttpError(res.status, text);

    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      throw new ProviderError("invalid_response", `Could not parse JSON: ${text}`);
    }

    const j = json as {
      choices?: { message?: { content?: string } }[];
      usage?: { prompt_tokens?: number; completion_tokens?: number };
      model?: string;
    };

    const content = j.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
      throw new ProviderError("invalid_response", `Missing content in response: ${text}`);
    }

    const tokens_in = j.usage?.prompt_tokens ?? 0;
    const tokens_out = j.usage?.completion_tokens ?? 0;
    const responseModel = j.model ?? model;

    await logPrompt({ kind: "chat", model: responseModel, tokens_in, tokens_out }).catch(
      () => undefined
    );

    return { content, tokens_in, tokens_out, model: responseModel };
  }

  async chatStream(
    messages: ChatMessage[],
    onChunk: (chunk: string) => void,
    opts: { model?: string; temperature?: number; maxTokens?: number } = {}
  ): Promise<{ tokens_in: number; tokens_out: number; model: string }> {
    const model = opts.model ?? DEFAULT_CHAT_MODEL;
    const body: Record<string, unknown> = {
      model,
      messages,
      temperature: opts.temperature ?? 0.7,
      stream: true,
      stream_options: { include_usage: true },
    };
    if (opts.maxTokens) body.max_tokens = opts.maxTokens;

    const res = await fetchWithTimeout(
      `${BASE_URL}/chat/completions`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${getApiKey()}`,
        },
        body: JSON.stringify(body),
      },
      60_000
    );

    if (!res.ok) {
      const text = await res.text();
      throw mapHttpError(res.status, text);
    }

    if (!res.body) {
      throw new ProviderError("server", "No response body for streaming request");
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let tokens_in = 0;
    let tokens_out = 0;
    let responseModel = model;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed === "data: [DONE]") continue;
        if (!trimmed.startsWith("data: ")) continue;

        let parsed: unknown;
        try {
          parsed = JSON.parse(trimmed.slice(6));
        } catch {
          continue;
        }

        const p = parsed as {
          choices?: { delta?: { content?: string } }[];
          usage?: { prompt_tokens?: number; completion_tokens?: number };
          model?: string;
        };

        if (p.model) responseModel = p.model;

        const delta = p.choices?.[0]?.delta?.content;
        if (delta) onChunk(delta);

        if (p.usage) {
          tokens_in = p.usage.prompt_tokens ?? tokens_in;
          tokens_out = p.usage.completion_tokens ?? tokens_out;
        }
      }
    }

    await logPrompt({
      kind: "chat",
      model: responseModel,
      tokens_in,
      tokens_out,
    }).catch(() => undefined);

    return { tokens_in, tokens_out, model: responseModel };
  }

  async embed(
    text: string,
    opts: { model?: string } = {}
  ): Promise<EmbedResponse> {
    const model = opts.model ?? DEFAULT_EMBED_MODEL;

    const res = await fetchWithTimeout(
      `${BASE_URL}/embeddings`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${getApiKey()}`,
        },
        body: JSON.stringify({ model, input: text }),
      }
    );

    const raw = await res.text();
    if (!res.ok) throw mapHttpError(res.status, raw);

    let json: unknown;
    try {
      json = JSON.parse(raw);
    } catch {
      throw new ProviderError("invalid_response", `Could not parse JSON: ${raw}`);
    }

    const j = json as {
      data?: { embedding?: number[] }[];
      usage?: { prompt_tokens?: number };
      model?: string;
    };

    const embedding = j.data?.[0]?.embedding;
    if (!Array.isArray(embedding)) {
      throw new ProviderError("invalid_response", `Missing embedding in response: ${raw}`);
    }

    const tokens = j.usage?.prompt_tokens ?? 0;
    const responseModel = j.model ?? model;

    await logPrompt({ kind: "embed", model: responseModel, tokens_in: tokens, tokens_out: 0 }).catch(
      () => undefined
    );

    return { embedding, tokens, model: responseModel };
  }

  async transcribe(
    audioBuffer: ArrayBuffer,
    opts: { mimeType?: string; language?: string } = {}
  ): Promise<TranscribeResponse> {
    const model = DEFAULT_TRANSCRIBE_MODEL;
    const mimeType = opts.mimeType ?? "audio/m4a";

    const form = new FormData();
    form.append(
      "file",
      new Blob([audioBuffer], { type: mimeType }),
      `audio.${mimeType.split("/")[1] ?? "m4a"}`
    );
    form.append("model", model);
    if (opts.language) form.append("language", opts.language);

    const res = await fetchWithTimeout(
      `${BASE_URL}/audio/transcriptions`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${getApiKey()}`,
        },
        body: form,
      },
      60_000
    );

    const raw = await res.text();
    if (!res.ok) throw mapHttpError(res.status, raw);

    let json: unknown;
    try {
      json = JSON.parse(raw);
    } catch {
      throw new ProviderError("invalid_response", `Could not parse JSON: ${raw}`);
    }

    const j = json as {
      text?: string;
      language?: string;
      duration?: number;
    };

    if (typeof j.text !== "string") {
      throw new ProviderError("invalid_response", `Missing text in response: ${raw}`);
    }

    await logPrompt({ kind: "transcribe", model, tokens_in: 0, tokens_out: 0 }).catch(
      () => undefined
    );

    return {
      transcript: j.text,
      language: j.language,
      duration_sec: j.duration,
    };
  }
}

export const dashscope: LLMProvider = new DashScopeProvider();
