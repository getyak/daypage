// ─── AI Provider abstraction ───────────────────────────────────────────────────
// Server-only — never import from client components.

export type ChatMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

export type ChatResponse = {
  content: string;
  tokens_in: number;
  tokens_out: number;
  model: string;
};

export type EmbedResponse = {
  embedding: number[];
  tokens: number;
  model: string;
};

export type TranscribeResponse = {
  transcript: string;
  language?: string;
  duration_sec?: number;
};

export type ProviderErrorCode =
  | "rate_limit"
  | "timeout"
  | "auth"
  | "server"
  | "invalid_response";

export class ProviderError extends Error {
  constructor(
    public readonly code: ProviderErrorCode,
    message: string,
    public readonly cause?: unknown
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

export interface LLMProvider {
  /**
   * Call the chat completion endpoint.
   * @param messages Conversation history
   * @param opts.model Override the default chat model
   * @param opts.temperature Sampling temperature (default 0.7)
   * @param opts.maxTokens Max output tokens
   * @param opts.jsonMode Force JSON output
   */
  chat(
    messages: ChatMessage[],
    opts?: {
      model?: string;
      temperature?: number;
      maxTokens?: number;
      jsonMode?: boolean;
    }
  ): Promise<ChatResponse>;

  /**
   * Embed a single string into a dense vector.
   * @param text The text to embed
   * @param opts.model Override the default embedding model
   */
  embed(
    text: string,
    opts?: { model?: string }
  ): Promise<EmbedResponse>;

  /**
   * Transcribe audio to text.
   * @param audioBuffer Raw audio bytes
   * @param opts.mimeType MIME type of the audio (default audio/m4a)
   * @param opts.language BCP-47 language hint
   */
  transcribe(
    audioBuffer: ArrayBuffer,
    opts?: { mimeType?: string; language?: string }
  ): Promise<TranscribeResponse>;
}
